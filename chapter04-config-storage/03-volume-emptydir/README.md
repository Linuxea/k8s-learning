# 03 - Volume 与 emptyDir：容器间的数据共享

## 为什么需要 Volume

Kubernetes 中，容器的文件系统有一个致命特性：**它是临时的（ephemeral）**。

```
容器启动 → 写入文件 → 容器崩溃/重启 → 所有数据丢失！
```

这带来了三个问题：

1. **容器重启丢数据** — 一个 Pod 内的容器崩溃重启后，之前写入的文件全部消失
2. **容器之间不共享** — 同一个 Pod 内的两个容器，文件系统是隔离的，无法共享文件
3. **Pod 删除丢数据** — Pod 被删除后，容器内的所有数据随之消失

Volume 就是解决这些问题的机制。它定义了一种**存储抽象**，可以被 Pod 内的一个或多个容器挂载使用。

> Kubernetes Volume 和 Docker Volume 概念类似，但 K8s Volume 的生命周期与 Pod 绑定，而不是与容器绑定。这意味着 Volume 在 Pod 内所有容器间共享，且在容器重启后依然存在。

## Volume 的生命周期

```
Pod 创建
  ↓
Volume 被创建（在 Pod 被调度到的节点上）
  ↓
Pod 内的容器启动，挂载 Volume
  ↓
容器 A 写入文件 → 容器 B 可以读取
容器崩溃重启 → Volume 中的数据还在
  ↓
Pod 被删除
  ↓
Volume 被销毁，数据丢失（对于 emptyDir 而言）
```

## emptyDir：最简单的 Volume

`emptyDir`（空目录卷）是最基础的 Volume 类型：

- **创建时机**：Pod 被调度到节点时创建
- **初始状态**：空目录
- **生命周期**：和 Pod 一样长。Pod 内所有容器都可以读写
- **删除时机**：Pod 被从节点上移除时删除（无论什么原因）

| 特性 | 说明 |
|------|------|
| 持久性 | 与 Pod 同生共死 |
| 共享范围 | 同 Pod 内所有容器 |
| 存储介质 | 节点磁盘（默认）或内存（`medium: Memory`） |
| 适用场景 | 临时数据、容器间共享、缓存 |

### emptyDir.medium 的两种模式

```yaml
volumes:
  - name: cache
    emptyDir:
      medium: ""         # 默认：使用节点磁盘
      # medium: "Memory"  # 使用 tmpfs（RAM 磁盘）

      # sizeLimit: 128Mi  # 可选：限制卷大小（Kubernetes 1.22+）
```

| 模式 | 存储位置 | 速度 | 持续性 | 适用场景 |
|------|---------|------|--------|---------|
| `""`（磁盘） | 节点磁盘 | 一般 | Pod 删除前保留 | 临时文件、共享数据 |
| `"Memory"` | 内存（tmpfs） | 快 | Pod 删除前保留，节点重启丢失 | 高速缓存、临时计算 |

> 使用 `medium: "Memory"` 时要注意：tmpfs 占用的是节点的内存资源，会被计入容器的内存限制。如果超出限制，容器会被 OOMKilled。

## Sidecar 模式

emptyDir 最经典的使用场景是 **Sidecar 模式**：一个主容器负责业务逻辑，一个辅助容器（sidecar）负责辅助工作，两者通过共享卷交换数据。

常见场景：

| 主容器 | Sidecar | 共享内容 |
|--------|---------|---------|
| nginx（Web 服务） | 内容生成器 | HTML 文件 |
| 应用容器 | 日志收集器（Fluentd） | 日志文件 |
| 应用容器 | 配置文件下载器 | 配置文件 |
| 应用容器 | 文件上传处理器 | 上传的文件 |

## 动手实践

### Step 1: 创建 Sidecar Demo

```bash
kubectl apply -f sidecar-volume-demo.yaml

# 查看 Pod 状态
kubectl get pods sidecar-demo
# NAME            READY   STATUS     RESTARTS   AGE
# sidecar-demo    0/2     Init:0/1   0          3s

# initContainer 阶段：正在生成初始 HTML
# 等几秒...
kubectl get pods sidecar-demo
# NAME            READY   STATUS    RESTARTS   AGE
# sidecar-demo    2/2     Running   0          15s
```

`READY` 显示 `2/2`：Pod 中有 2 个容器（nginx + content-generator），都已就绪。

### Step 2: 验证数据共享

```bash
# 从 nginx 容器访问网页
kubectl exec sidecar-demo -c nginx -- curl -s http://localhost
# <h1>Hello from initContainer!</h1>
# <p>This page was generated during Pod initialization.</p>

# 等待 10 秒以上（sidecar 的写入间隔）
sleep 12

# 再次访问——内容已经被 sidecar 更新了
kubectl exec sidecar-demo -c nginx -- curl -s http://localhost
# <h1>Hello from Sidecar!</h1>
# <p>Generated at: Mon Jun 1 12:34:56 UTC 2026</p>
# <p>Served by nginx from shared emptyDir volume.</p>
```

这个过程是这样的：

```
1. initContainer 启动 → 写入初始 index.html → 退出
2. nginx 容器启动 → 从 /usr/share/nginx/html 读取 index.html → 提供服务
3. content-generator 容器启动 → 每 10 秒覆盖写入 /work-dir/index.html
4. nginx 再次被访问时 → 读到的是 sidecar 更新后的内容
```

关键：nginx 和 content-generator 挂载的是**同一个** emptyDir 卷，只是挂载路径不同。

### Step 3: 观察容器隔离与卷共享

```bash
# 查看 nginx 容器内的挂载情况
kubectl exec sidecar-demo -c nginx -- df -h /usr/share/nginx/html
# Filesystem ... Mounted on
# /dev/sda1    ...  /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~empty-dir/shared-html

# 查看 content-generator 容器内的挂载情况
kubectl exec sidecar-demo -c content-generator -- df -h /work-dir
# 同样的底层路径

# 尝试从 content-generator 写入新内容
kubectl exec sidecar-demo -c content-generator -- sh -c \
  'echo "<h1>Manual override!</h1>" > /work-dir/index.html'

# 从 nginx 容器读取——能看到
kubectl exec sidecar-demo -c nginx -- cat /usr/share/nginx/html/index.html
# <h1>Manual override!</h1>
```

### Step 4: 验证 Volume 的生命周期

```bash
# 模拟容器崩溃：杀掉 nginx 进程
kubectl exec sidecar-demo -c nginx -- kill 1

# 观察 Pod 状态
kubectl get pods sidecar-demo
# NAME            READY   STATUS    RESTARTS   AGE
# sidecar-demo    1/2     Running   1          3m
#                                            ↑ nginx 重启了一次

# nginx 重启后，emptyDir 中的数据还在
kubectl exec sidecar-demo -c nginx -- curl -s http://localhost
# 仍然能读取到 sidecar 写入的内容
```

> 这就是 emptyDir 的"中等级别"持久性：容器重启不丢数据，但 Pod 删除就会丢失。

```bash
# 删除 Pod，数据就没了
kubectl delete pod sidecar-demo
```

### Step 5: 测试 Memory 模式（可选）

如果你想体验 tmpfs 模式，可以修改 yaml 中的 `medium: "Memory"` 然后重新创建。tmpfs 的特点：

```bash
# 修改后重新创建
# 把 sidecar-volume-demo.yaml 中的 medium 改为 "Memory"
kubectl apply -f sidecar-volume-demo.yaml
kubectl wait --for=condition=Ready pod/sidecar-demo --timeout=30s

# 查看挂载类型
kubectl exec sidecar-demo -c nginx -- mount | grep html
# 你会看到 tmpfs 类型的挂载

# tmpfs 的数据存储在内存中，读写极快
# 但会占用容器内存配额
```

## Volume 类型全景

emptyDir 只是众多 Volume 类型之一。这里列出常见的类型让你有个全貌：

| 类型 | 持久性 | 适用场景 |
|------|--------|---------|
| `emptyDir` | Pod 级别 | 临时数据、容器间共享 |
| `hostPath` | 节点级别 | 访问节点文件系统（调试用） |
| `configMap` | ConfigMap 生命周期 | 配置文件注入 |
| `secret` | Secret 生命周期 | 敏感信息注入 |
| `persistentVolumeClaim` | 独立于 Pod | 持久化存储（下一节讲） |
| `nfs` | 外部存储 | 多节点共享文件 |

## 思考题

1. 如果 Pod 中的一个容器写入 emptyDir 的数据量超过了节点的磁盘空间，会发生什么？有什么办法可以限制？
2. emptyDir 的 `medium: "Memory"` 模式和直接在容器内存中分配缓冲区（如应用内存缓存）有什么区别？各自适用于什么场景？
3. 如果 Pod 被重新调度到另一个节点（比如节点故障），emptyDir 中的数据会怎样？这说明了 emptyDir 的什么局限性？
4. 在 Sidecar 模式中，如果 sidecar 容器崩溃了，主容器还能正常工作吗？反过来呢？

---

下一个 → [04 - PV 与 PVC](../04-pv-pvc/)
