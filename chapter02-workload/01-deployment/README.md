# 01 - Deployment

## 为什么需要 Deployment

在第一章里，你学会了创建 Pod。但手动管理 Pod 有几个致命问题：

1. **Pod 是脆弱的** — 节点故障、容器崩溃，Pod 就没了。K8s 虽然会根据 `restartPolicy` 重启容器，但如果整个节点挂了，Pod 就真的丢了。
2. **无法声明式地管理副本** — 你需要 3 个 nginx？手动创建 3 个 Pod？要扩到 5 个？再创建 2 个？
3. **没有滚动更新** — 想升级 nginx 1.27 → 1.28？你得一个一个删旧 Pod、建新 Pod，还得保证服务不中断。
4. **没有回滚能力** — 升级出问题了，怎么退回去？

Deployment 就是 K8s 给出的答案：**声明式地管理 Pod 副本，自带自愈、滚动更新和回滚**。

## 三层关系：Deployment → ReplicaSet → Pod

这是理解 Deployment 最重要的概念：

```
Deployment
  └── ReplicaSet (revision 1)
        ├── Pod (nginx-deployment-abc123-xxxx)
        ├── Pod (nginx-deployment-abc123-yyyy)
        └── Pod (nginx-deployment-abc123-zzzz)
```

为什么是三层而不是两层？

- **ReplicaSet** 的职责很单一：确保指定数量的 Pod 副本在运行。它通过 `selector` 匹配 Pod 的 `labels` 来管理 Pod。
- **Deployment** 在 ReplicaSet 之上加了两样东西：**滚动更新策略** 和 **版本历史管理**。
- 每次你更新 Deployment 的 Pod 模板（比如换镜像版本），Deployment 就会创建一个**新的 ReplicaSet**，然后按照滚动更新策略，逐步把旧 ReplicaSet 的 Pod 缩容、新 ReplicaSet 的 Pod 扩容。

```
# 更新镜像版本后的状态：
Deployment
  ├── ReplicaSet (revision 2) ← 新的，正在扩容
  │     ├── Pod (new-hash-xxxx)
  │     └── Pod (new-hash-yyyy)
  └── ReplicaSet (revision 1) ← 旧的，正在缩容
        └── Pod (old-hash-zzzz)  ← 等待被替换
```

> 这也是为什么你很少直接使用 ReplicaSet — Deployment 已经帮你管理了，还额外提供了滚动更新和回滚。

## 关键字段详解

| 字段 | 含义 | 默认值 |
|------|------|--------|
| `spec.replicas` | 期望的 Pod 副本数量 | 1 |
| `spec.selector` | 标签选择器，用来"选中"属于这个 Deployment 的 Pod | — |
| `spec.strategy.type` | 更新策略：`RollingUpdate`（滚动更新）或 `Recreate`（先删后建） | `RollingUpdate` |
| `spec.strategy.rollingUpdate.maxSurge` | 滚动更新时，可以超出 replicas 数量创建的 Pod 上限（数字或百分比） | 25% |
| `spec.strategy.rollingUpdate.maxUnavailable` | 滚动更新时，允许不可用的 Pod 数量上限（数字或百分比） | 25% |
| `spec.minReadySeconds` | Pod 就绪后至少等多久才被认为是"可用"的 | 0 |
| `spec.revisionHistoryLimit` | 保留多少个旧 ReplicaSet（用于回滚） | 10 |

### selector 必须匹配 template.labels

这是一个初学者经常踩的坑：

```yaml
spec:
  selector:
    matchLabels:
      app: nginx        # ← selector 里的标签
  template:
    metadata:
      labels:
        app: nginx      # ← 必须和 selector 匹配！
```

如果 `selector` 和 `template.labels` 不匹配，K8s 会直接拒绝创建。这是为了防止 Deployment "认领"了不该属于自己的 Pod。

## 滚动更新的工作原理

当你更新 Deployment 的 Pod 模板（比如 `kubectl set image`），K8s 不是一口气把所有 Pod 都换掉，而是：

```
初始状态（3 副本，nginx:1.27）：
  RS-v1: [Pod1] [Pod2] [Pod3]

开始滚动更新到 nginx:1.28（maxSurge=1, maxUnavailable=0）：

Step 1: 先扩一个新 Pod
  RS-v1: [Pod1] [Pod2] [Pod3]
  RS-v2: [Pod4]              ← 总共 4 个 Pod

Step 2: 新 Pod 就绪后，缩一个旧 Pod
  RS-v1: [Pod1] [Pod2]
  RS-v2: [Pod4] [Pod5]       ← 总共 4 个 Pod

Step 3: 继续替换...
  RS-v1: [Pod1]
  RS-v2: [Pod4] [Pod5] [Pod6] ← 总共 4 个 Pod

Step 4: 最后一个旧 Pod 被替换
  RS-v1: []
  RS-v2: [Pod4] [Pod5] [Pod6] ← 完成，3 个新 Pod
```

### maxSurge 和 maxUnavailable 的组合效果

| maxSurge | maxUnavailable | 行为 |
|----------|---------------|------|
| `25%` | `25%` | 默认策略。3 副本时：最多 4 个 Pod，最少 2 个可用 |
| `1` | `0` | **零停机**。始终先创建新 Pod，等就绪再删旧的。但需要多余资源 |
| `0` | `1` | **不额外占资源**。先删旧的再建新的，会有短暂不可用 |
| `50%` | `0` | 更激进的零停机。同时创建更多新 Pod，更新速度更快 |

> `maxUnavailable: 0` + `maxSurge: 1` 是生产环境常用的零停机配置。代价是滚动更新期间会多出最多 `maxSurge` 个 Pod 的资源消耗。

## Step by Step 操作

### Step 1: 确保 kind 集群运行中

```bash
# 如果还没创建集群（第一章创建过的话可以跳过）
kind create cluster --name k8s-learning --config=- <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF

# 验证
kubectl get nodes
# 应该看到 1 个 control-plane + 2 个 worker
```

### Step 2: 创建 Deployment

```bash
kubectl apply -f nginx-deployment.yaml

# 查看 Deployment
kubectl get deployments
# NAME               READY   UP-TO-DATE   AVAILABLE   AGE
# nginx-deployment   3/3     3            3           10s

# 查看 ReplicaSet（注意后面的 hash 后缀）
kubectl get replicasets
# NAME                          DESIRED   CURRENT   READY   AGE
# nginx-deployment-7fb96c846b   3         3         3       15s

# 查看 Pod（名字 = deployment名-replicaset hash-随机串）
kubectl get pods
# NAME                                READY   STATUS    RESTARTS   AGE
# nginx-deployment-7fb96c846b-abc12   1/1     Running   0          20s
# nginx-deployment-7fb96c846b-def34   1/1     Running   0          20s
# nginx-deployment-7fb96c846b-ghi56   1/1     Running   0          20s
```

> 注意三层关系：Deployment 名称 → ReplicaSet 名称（带 hash） → Pod 名称（带 hash + 随机串）。Pod 名称里的 hash 来自 template 的内容，换镜像就会变。

### Step 3: 扩容（Scale Up）

```bash
# 扩到 5 个副本
kubectl scale deployment nginx-deployment --replicas=5

kubectl get pods
# 你会看到新创建了 2 个 Pod

# 也可以通过修改 yaml 文件后重新 apply
# 把 replicas: 3 改成 replicas: 5，然后：
# kubectl apply -f nginx-deployment.yaml
```

### Step 4: 缩容回 3

```bash
kubectl scale deployment nginx-deployment --replicas=3

# 观察 Pod 被终止
kubectl get pods -w
# Ctrl+C 退出 watch
```

### Step 5: 更新镜像版本（触发滚动更新）

```bash
# 方法一：命令行直接改
kubectl set image deployment/nginx-deployment nginx=nginx:1.28

# 方法二：修改 yaml 文件后 apply
# 把 image: nginx:1.27 改成 image: nginx:1.28
# kubectl apply -f nginx-deployment.yaml

# 查看滚动更新状态
kubectl rollout status deployment/nginx-deployment
# Waiting for deployment "nginx-deployment" rollout to finish: 1 out of 3 new replicas have been updated...
# ...
# deployment "nginx-deployment" successfully rolled out
```

观察 ReplicaSet 变化：

```bash
kubectl get replicasets
# NAME                          DESIRED   CURRENT   READY   AGE
# nginx-deployment-7fb96c846b   0         0         0       5m    ← 旧的，已缩容到 0
# nginx-deployment-5b8c4f6d7k   3         3         3       30s   ← 新的
```

> 旧 ReplicaSet 的 Pod 数量缩到 0 但**不会被删除**，这正是回滚的"后路"。

### Step 6: 查看更新历史

```bash
kubectl rollout history deployment/nginx-deployment
# REVISION  CHANGE-CAUSE
# 1         <none>
# 2         <none>

# 查看某个版本的详情
kubectl rollout history deployment/nginx-deployment --revision=1
# 会显示那个版本的 Pod 模板内容
```

> `CHANGE-CAUSE` 列为空是因为我们没加 `--record`。注意：`--record` 已被弃用，推荐用 `kubectl annotate` 来记录变更原因。

### Step 7: 回滚

```bash
# 回滚到上一个版本
kubectl rollout undo deployment/nginx-deployment

# 查看状态
kubectl rollout status deployment/nginx-deployment

# 验证镜像版本已回退
kubectl get deployment nginx-deployment -o jsonpath='{.spec.template.spec.containers[0].image}'
# nginx:1.27

# 也可以回滚到指定版本
# kubectl rollout undo deployment/nginx-deployment --to-revision=1
```

回滚的本质是什么？—— 把旧的 ReplicaSet 重新扩容，新的缩容。所以回滚是秒级的，不需要重新拉取镜像（如果镜像已经在节点上）。

### Step 8: 暂停和恢复滚动更新

```bash
# 暂停 — 用于在更新过程中做多次修改，避免触发多次滚动更新
kubectl rollout pause deployment/nginx-deployment

# 做一些修改（不会触发更新）
kubectl set image deployment/nginx-deployment nginx=nginx:1.28
kubectl set resources deployment/nginx-deployment -c=nginx --limits=memory=256Mi

# 恢复 — 这时才会触发一次滚动更新
kubectl rollout resume deployment/nginx-deployment

# 查看最终状态
kubectl rollout status deployment/nginx-deployment
```

> 暂停/恢复的使用场景：当你需要同时修改镜像版本和资源限制时，不希望 K8s 做两次滚动更新。

### Step 9: 体验自定义滚动更新策略

```bash
# 使用零停机策略的示例
kubectl apply -f rolling-update-demo.yaml

# 查看事件，观察滚动更新过程
kubectl describe deployment nginx-rolling-demo | grep -A5 "RollingUpdateStrategy"
# RollingUpdateStrategy:  0 max unavailable, 1 max surge
```

### Step 10: 清理

```bash
kubectl delete -f nginx-deployment.yaml
kubectl delete -f rolling-update-demo.yaml
```

## Recreate 策略

和 `RollingUpdate` 相反，`Recreate` 会先把所有旧 Pod 删掉，再创建新的：

```yaml
spec:
  strategy:
    type: Recreate
```

适用场景：旧版本和新版本**不能同时运行**（比如数据库 schema 不兼容、单例应用）。

> 缺点很明显：更新期间服务完全不可用。所以一般只在必须时才用。

## 常见困惑

### 1. Deployment 的 kubectl 简写是什么？

Deployment 的别名是 `deploy`，**不是** `deploys`。`kubectl get deploy` 和 `kubectl get deployments` 等价。

### 2. Deployment → ReplicaSet → Pod 的名称规则

三者的名称通过 hash 关联：

```
nginx-deployment（Deployment 名）
  └── nginx-deployment-66fc78d4b8（RS名 = Deploy名 + Pod模板hash）
        ├── nginx-deployment-66fc78d4b8-cjrsf（Pod名 = RS名 + 随机串）
        └── ...
```

RS 名中的 hash 来自 **Pod 模板的完整内容（spec + labels）**。模板里任何字段变了（镜像、标签、环境变量……），hash 就变 → 新 RS 创建 → 滚动更新触发。

### 3. `rollout undo` 为什么不重新拉取镜像？

回滚只是把已缩容到 0 的旧 RS 重新扩回期望副本数。旧 RS 的 Pod 模板从未改变，镜像名没变。节点上已有镜像缓存时是秒级完成。

### 4. 修改 Pod 模板的 labels 会触发滚动更新吗？

会。labels 属于 Pod 模板的一部分 → 模板 hash 变 → 新 RS 创建 → 滚动更新触发。加一个标签也触发全量 Pod 重建，生产环境需留意。

### 5. 快速查看 Deployment 三级结构

```bash
kubectl get deploy,rs,pods     # 一行命令看到 Deploy、RS、Pod 三级关系
```

## kubectl rollout 命令速查

| 命令 | 作用 |
|------|------|
| `kubectl rollout status deployment/<name>` | 查看滚动更新状态 |
| `kubectl rollout history deployment/<name>` | 查看版本历史 |
| `kubectl rollout undo deployment/<name>` | 回滚到上一版本 |
| `kubectl rollout undo deployment/<name> --to-revision=N` | 回滚到指定版本 |
| `kubectl rollout pause deployment/<name>` | 暂停滚动更新 |
| `kubectl rollout resume deployment/<name>` | 恢复滚动更新 |
| `kubectl rollout restart deployment/<name>` | 重启所有 Pod（触发滚动更新） |
| `kubectl scale deployment/<name> --replicas=N` | 扩/缩容 |

## 思考题

1. 如果把 `maxUnavailable` 设为 `100%`，滚动更新时会发生什么？这种配置有没有实际用途？
2. Deployment 的 `revisionHistoryLimit` 设为 0 会有什么后果？设得太大呢？
3. `kubectl rollout undo` 是如何实现"秒级回滚"的？回滚时需要重新拉取镜像吗？
4. 如果你在 Deployment 的 Pod 模板里修改了 `labels`（而不是镜像），会触发滚动更新吗？为什么？

---

下一个 → [02 - ReplicaSet](../02-replicaset/)
