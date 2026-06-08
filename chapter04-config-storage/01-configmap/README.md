# 01 - ConfigMap：把配置从镜像中剥离出来

## 为什么需要 ConfigMap

想象一个场景：你构建了一个容器镜像，里面硬编码了数据库地址 `db-test.internal`。
现在要上线到生产环境，数据库地址是 `db-prod.internal`。怎么办？

传统做法是为每个环境构建不同的镜像。但这违反了 **12-Factor App** 的第三条原则：

> **III. Config：在环境中存储配置。** 代码和配置严格分离。同一个镜像可以在开发、测试、生产环境运行，只需要改变配置。

ConfigMap 就是 Kubernetes 提供的配置分离机制。它把配置数据从容器镜像中抽出来，变成一个独立的 API 对象。这样：

1. **同一个镜像可以跑在不同环境** — 只需替换 ConfigMap
2. **配置变更不需要重新构建镜像** — 更新 ConfigMap 即可（有些场景需要重启 Pod 才能生效）
3. **配置可以被多个 Pod 共享** — 不用在每个 Pod 定义里重复写

> ConfigMap 不适合存放敏感数据（密码、密钥、证书）。这些数据应该用 Secret，下一节会讲。

## ConfigMap 的三种消费方式

| 方式 | 适用场景 | 更新后是否自动生效 |
|------|---------|-------------------|
| **环境变量** | 简单的键值对，应用启动时读取一次 | 需要重启 Pod |
| **命令行参数** | 传递给容器的启动命令 | 需要重启 Pod |
| **Volume 挂载** | 配置文件，应用需要读取文件内容 | 自动更新（kubelet 周期同步，有延迟） |

> 注意：Volume 挂载方式的"自动更新"有延迟（kubelet 的同步周期默认是 60 秒），而且你的应用必须有文件变更监听机制才能真正热更新。

## 动手实践

确保你的 kind 集群正在运行：

```bash
kubectl cluster-info
kubectl get nodes
# 应该看到 1 个 control-plane 和 2 个 worker 节点
```

### Step 1: 创建 ConfigMap

```bash
kubectl apply -f app-configmap.yaml

# 查看 ConfigMap
kubectl get configmap
# NAME               DATA   AGE
# app-config         4      5s

# 查看详细内容
kubectl describe configmap app-config
```

`DATA` 列显示的是 ConfigMap 中有多少个键。我们定义了 3 个简单键值对和 2 个多行配置，共 5 个键。

也可以用命令行快速创建 ConfigMap：

```bash
# 从字面量创建
kubectl create configmap quick-config --from-literal=KEY1=VALUE1 --from-literal=KEY2=VALUE2

# 从文件创建（键名就是文件名）
kubectl create configmap file-config --from-file=app.properties

# 从目录创建（目录下每个文件变成一个键）
kubectl create configmap dir-config --from-file=config-dir/
```

### Step 2: 以环境变量方式消费

```bash
kubectl apply -f pod-configmap-env.yaml

# 等待 Pod 完成
kubectl wait --for=condition=Ready pod/configmap-env-demo --timeout=30s

# 查看环境变量
kubectl exec configmap-env-demo -- env | grep -E 'LOG_LEVEL|APP_ENV|MAX_CONN'
# LOG_LEVEL=info
# APP_ENVIRONMENT=production
# MAX_CONNECTIONS=100
```

注意 `APP_ENVIRONMENT=production`：我们在 yaml 中把 ConfigMap 的 `APP_ENV` 键映射成了容器的 `APP_ENVIRONMENT` 环境变量。这说明了 `valueFrom.configMapKeyRef` 的灵活性——你可以自由控制容器内的变量名。

你也可以用 `envFrom` 一次性把 ConfigMap 的所有键导入为环境变量（yaml 文件中有注释示例）。

```bash
# 清理
kubectl delete -f pod-configmap-env.yaml
```

### Step 3: 以 Volume 挂载方式消费

```bash
kubectl apply -f pod-configmap-volume.yaml

# 等待 Pod 就绪
kubectl wait --for=condition=Ready pod/configmap-volume-demo --timeout=30s

# 验证 nginx 配置已被替换
kubectl exec configmap-volume-demo -- cat /etc/nginx/conf.d/default.conf
# 你会看到我们在 ConfigMap 中定义的 nginx 配置

# 测试自定义的 /health 路径
kubectl exec configmap-volume-demo -- curl -s http://localhost/health
# OK
```

这里用了 `subPath`，只把 ConfigMap 中的 `nginx.conf` 键挂载为 `/etc/nginx/conf.d/default.conf` 文件，而不影响同目录下的其他文件。

> 如果不用 `subPath`，整个目录会被 ConfigMap 的内容替换，原有的文件会消失。这是新手常踩的坑。

```bash
# 清理
kubectl delete -f pod-configmap-volume.yaml
```

### Step 4: 更新 ConfigMap 并观察行为

让我们观察 ConfigMap 更新后，Volume 挂载方式的行为：

```bash
# 先创建 Volume 方式的 Pod
kubectl apply -f pod-configmap-volume.yaml
kubectl wait --for=condition=Ready pod/configmap-volume-demo --timeout=30s

# 记录当前配置
kubectl exec configmap-volume-demo -- cat /etc/nginx/conf.d/default.conf

# 修改 ConfigMap（把 health 路径的返回值从 OK 改成 HEALTHY）
kubectl patch configmap app-config --type merge -p \
  '{"data":{"nginx.conf":"server {\n    listen 80;\n    server_name localhost;\n\n    location / {\n        root   /usr/share/nginx/html;\n        index  index.html index.htm;\n    }\n\n    location /health {\n        return 200 '\''HEALTHY'\'';\n        add_header Content-Type text/plain;\n    }\n}\n"}}'

# 等待一会儿（kubelet 同步周期）
sleep 30

# 查看文件是否已更新
kubectl exec configmap-volume-demo -- cat /etc/nginx/conf.d/default.conf | grep HEALTHY

# 测试——注意：nginx 不会自动重新加载配置
# 需要手动触发 nginx reload 才能让新配置生效
kubectl exec configmap-volume-demo -- nginx -s reload
kubectl exec configmap-volume-demo -- curl -s http://localhost/health
# 现在应该返回 HEALTHY
```

> 这个实验说明了一个重要区别：Volume 挂载的文件内容会自动更新，但应用是否感知到更新取决于应用自身。环境变量方式则完全不会自动更新，Pod 内的环境变量在创建时就固定了。

```bash
# 清理
kubectl delete -f pod-configmap-volume.yaml
```

## 不可变 ConfigMap

Kubernetes 1.21 引入了 `immutable` 字段。一旦设置为 `true`，ConfigMap 的内容就不能再被修改：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: immutable-config
data:
  LOG_LEVEL: "info"
immutable: true   # 设置后不可修改，只能删除重建
```

为什么需要不可变 ConfigMap？

1. **性能优化** — kubelet 不需要定期轮询检查 ConfigMap 是否变更，减少 apiserver 负载
2. **安全性** — 防止配置被意外或恶意修改
3. **可靠性** — 确保应用运行期间配置不会变化

如果需要修改不可变 ConfigMap，只能删除后重新创建。这意味着消费它的 Pod 也需要重建。

## ConfigMap 使用建议

| 建议 | 原因 |
|------|------|
| 配置文件用 Volume 挂载 | 支持热更新，适合多行复杂配置 |
| 简单键值对用环境变量 | 简单直接，12-Factor App 推荐方式 |
| 不要存大文件 | ConfigMap 总大小限制 1MiB（etcd 限制） |
| 生产环境用 `immutable: true` | 减少 apiserver 压力，提高集群稳定性 |
| 配置变更流程自动化 | ConfigMap 更新 → 滚动重启 Pod（配合 Deployment） |

## 常见困惑

### 1. Volume 挂载时文件到底有没有热更新？

**文件内容会变，但应用不一定感知。** kubelet 更新 ConfigMap 卷用的是**符号链接原子替换**机制：

```
# 第一次挂载
/etc/config/
  ..data → ..2026_06_08_13_25_00    ← 真实文件目录
  nginx.conf → ..data/nginx.conf

# ConfigMap 更新后
/etc/config/
  ..data → ..2026_06_08_13_28_30    ← 原子切换到新目录
  nginx.conf → ..data/nginx.conf    ← 符号链接不变，但它指向的文件变了
```

关键细节：
- kubelet 创建新的时间戳目录，写入新文件，然后原子更新 `..data` 符号链接
- `cat /etc/config/nginx.conf` 会读到新内容（因为符号链接跟到了新目录）
- 但如果应用已经 `open()` 了文件，它的文件描述符还指向**旧的 inode**，读的还是旧内容
- 即使应用 `close()` 再重新 `open()`，也不一定触发（取决于应用的设计）

这就是为什么 nginx 在 `cat` 确认文件变了之后，`nginx -s reload` 仍然返回旧值——可能 nginx 缓存了旧文件，或者 reload 处理 include 文件时有特殊行为。

### 2. `subPath` 挂载的热更新问题

`subPath` 挂载的单个文件**永远不会被更新**。这是 Kubernetes 的已知限制（[Issue #50345](https://github.com/kubernetes/kubernetes/issues/50345)）。

```
# subPath 挂载：文件直接 bind mount 进去
subPath: nginx.conf
mountPath: /etc/nginx/conf.d/default.conf
→ 更新 ConfigMap 后，文件内容不变 ← 永不更新

# 目录挂载：通过符号链接原子替换
mountPath: /etc/nginx/conf.d
→ 更新 ConfigMap 后，文件内容会变 ← 有热更新
```

### 3. 生产环境的正确做法

不要依赖 kubelet 的符号链接同步来做热更新。标准做法：
1. ConfigMap 更新 → 2. Deployment 滚动重启 Pod → 3. 新 Pod 读新配置

配合 Deployment 的 `spec.strategy.rollingUpdate` 可以做到零停机。

## 思考题

1. 如果 ConfigMap 中某个键被删除了，正在使用该键作为环境变量的 Pod 会怎样？（试试看）
2. 环境变量方式 vs Volume 挂载方式，在 ConfigMap 更新时行为有什么不同？哪个更适合需要频繁更新的配置？
3. 为什么 ConfigMap 有 1MiB 的大小限制？如果一个应用需要 5MB 的配置文件，该怎么处理？
4. 如果一个 Pod 引用了一个不存在的 ConfigMap，Pod 会启动成功吗？`optional: true` 参数有什么作用？

---

下一个 → [02 - Secret](../02-secret/)
