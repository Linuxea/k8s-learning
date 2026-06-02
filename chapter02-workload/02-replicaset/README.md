# 02 - ReplicaSet

## ReplicaSet 是什么

ReplicaSet 的核心职责只有一件事：**确保任何时候都有指定数量的 Pod 副本在运行**。

它的工作方式很直接：

1. 通过 `selector`（标签选择器）找到属于自己的 Pod
2. 比对当前数量和期望数量（`replicas`）
3. 少了就创建，多了就删除

就这样，简单粗暴。这种"调谐循环"（reconciliation loop）是 K8s 控制器的核心设计模式。

## 和 Deployment 的关系

在上一节我们讲了 Deployment → ReplicaSet → Pod 的三层关系。现在你可能有疑问：

**既然 Deployment 已经管理了 ReplicaSet，为什么还要单独学 ReplicaSet？**

几个原因：

1. **理解原理** — Deployment 的副本管理、自愈能力，底层都是 ReplicaSet 在干活。理解 ReplicaSet 就是理解 Deployment 的工作原理。
2. **排查问题** — 当 Deployment 出问题时，你可能需要直接查看底层的 ReplicaSet 状态。
3. **特殊情况** — 少数场景下（如自定义控制器、旧系统迁移）可能直接用 ReplicaSet。

> 但在日常工作中，**99% 的情况你应该使用 Deployment 而不是 ReplicaSet**。Deployment = ReplicaSet + 滚动更新 + 回滚。

### ReplicaSet 不能做什么

| 功能 | ReplicaSet | Deployment |
|------|-----------|------------|
| 维护副本数量 | ✅ | ✅ |
| Pod 自愈（节点故障后重建） | ✅ | ✅ |
| 滚动更新 | ❌ | ✅ |
| 回滚到历史版本 | ❌ | ✅ |
| 暂停/恢复更新 | ❌ | ✅ |

当你修改 ReplicaSet 的 Pod 模板（比如换镜像），它**不会**自动滚动更新。已有的 Pod 仍然用旧模板运行。你需要手动删除旧 Pod，让 ReplicaSet 用新模板重建。

这就是为什么 Deployment 更好 — 它自动帮你管理这个过程。

## 标签选择器：matchLabels vs matchExpressions

ReplicaSet 的 `selector` 有两种写法：

### matchLabels — 精确匹配

```yaml
selector:
  matchLabels:
    app: nginx        # label "app" 的值必须等于 "nginx"
    tier: frontend    # label "tier" 的值必须等于 "frontend"
```

等价于 SQL 里的 `WHERE app = 'nginx' AND tier = 'frontend'`。多个条件是 **AND** 关系。

### matchExpressions — 高级匹配

```yaml
selector:
  matchExpressions:
    - key: app
      operator: In           # operator 支持四种：In, NotIn, Exists, DoesNotExist
      values:
        - nginx
        - apache
    - key: env
      operator: NotIn
      values:
        - test
    - key: tier
      operator: Exists       # 只要 label 里存在 "tier" 这个 key 就行，不管值是什么
```

| 操作符 | 含义 | 示例 |
|--------|------|------|
| `In` | label 的值在给定列表中 | `app In [nginx, apache]` → app=nginx 或 app=apache |
| `NotIn` | label 的值不在给定列表中 | `env NotIn [test]` → env 不是 test |
| `Exists` | label 存在这个 key（不管值） | `tier Exists` → 有 tier 标签 |
| `DoesNotExist` | label 不存在这个 key | `canary DoesNotExist` → 没有 canary 标签 |

> `matchLabels` 和 `matchExpressions` 可以同时使用，它们之间是 **AND** 关系。

## 关键字段详解

| 字段 | 含义 |
|------|------|
| `spec.replicas` | 期望的 Pod 副本数量 |
| `spec.selector` | 标签选择器，决定哪些 Pod 归我管 |
| `spec.template` | Pod 模板，创建新 Pod 时用 |
| `spec.minReadySeconds` | Pod 就绪后至少等多久才被认为是"可用" |

> **重要**：`selector` 不能随便改。一旦 ReplicaSet 创建了，`selector` 就不可变更（immutable）。这是为了防止控制器突然"认领"或"遗弃"一批 Pod，导致混乱。

## Step by Step 操作

### Step 1: 创建 ReplicaSet

```bash
kubectl apply -f nginx-replicaset.yaml

# 查看 ReplicaSet
kubectl get rs
# NAME              DESIRED   CURRENT   READY   AGE
# nginx-replicaset  3         3         3       10s

# 查看创建出来的 Pod
kubectl get pods --show-labels
# NAME                    READY   STATUS    RESTARTS   AGE   LABELS
# nginx-replicaset-xxxx   1/1     Running   0          15s   app=nginx,chapter=02,...
# nginx-replicaset-yyyy   1/1     Running   0          15s   app=nginx,chapter=02,...
# nginx-replicaset-zzzz   1/1     Running   0          15s   app=nginx,chapter=02,...
```

> `kubectl get rs` 是 `kubectl get replicasets` 的缩写。

### Step 2: 观察自愈能力

```bash
# 删除一个 Pod
kubectl delete pod <任意一个 pod 名>

# 立刻查看 Pod 列表
kubectl get pods
# 你会看到被删的 Pod 在终止，同时一个新的 Pod 已经被创建出来
# ReplicaSet 检测到副本数不够，立刻用 template 创建新的
```

这就是"自愈" — ReplicaSet 的控制器在不停地循环检查：期望 3 个，现在只有 2 个？那就再创建 1 个。

### Step 3: 尝试"手动"创建匹配标签的 Pod

```bash
# 手动创建一个带同样标签的 Pod
kubectl run rogue-pod --image=nginx:1.27 --labels=app=nginx

# 查看 Pod 数量
kubectl get pods -l app=nginx
# 你会发现有 4 个 Pod！

# 但很快 ReplicaSet 发现多了一个，会把它删掉（如果你设置的 replicas=3）
# 等几秒再看
kubectl get pods -l app=nginx
# 应该回到了 3 个
```

> 这说明 ReplicaSet 不只是"创建"Pod，它还会"删除"多余的匹配 Pod。所以别在 ReplicaSet 管理的标签范围内手动创建 Pod。

### Step 4: 修改镜像版本（对比 Deployment）

```bash
# 直接修改 ReplicaSet 的镜像
kubectl set image replicaset/nginx-replicaset nginx=nginx:1.28

# 查看 Pod... 镜像并没有变！
kubectl get pods -o jsonpath='{.items[0].spec.containers[0].image}'
# 还是 nginx:1.27

# 为什么？因为 ReplicaSet 不会滚动更新已有的 Pod
# 只有新创建的 Pod 才会用新模板

# 手动删除所有 Pod，让 ReplicaSet 用新模板重建
kubectl delete pods -l app=nginx,chapter=02-rs

# 等几秒，新 Pod 就会用 nginx:1.28 了
kubectl get pods -o jsonpath='{.items[0].spec.containers[0].image}'
# nginx:1.28
```

**这就是 ReplicaSet 和 Deployment 的关键区别**。Deployment 会自动做这个"删旧建新"的过程（滚动更新），而 ReplicaSet 不会。

### Step 5: 体验 matchExpressions

```bash
kubectl apply -f match-expressions-demo.yaml

# 查看创建的 Pod
kubectl get pods --show-labels
# 观察 selector 是如何匹配的

# 清理
kubectl delete -f match-expressions-demo.yaml
```

### Step 6: 清理

```bash
kubectl delete -f nginx-replicaset.yaml
```

## 扩缩容

和 Deployment 一样，ReplicaSet 也支持扩缩容：

```bash
# 命令行方式
kubectl scale rs nginx-replicaset --replicas=5

# 或者修改 yaml 文件后重新 apply
```

> 但在生产中，扩缩容应该通过 HPA（Horizontal Pod Autoscaler）自动完成，而不是手动操作。

## 常见困惑

### 1. `kubectl edit` 改了什么，文件改了什么？

`kubectl edit` 直接修改集群 etcd 中的活对象，**不修改磁盘上的 YAML 文件**。两者会不一致：

```
磁盘文件: replicas: 3  ← 你以为的
集群实际: replicas: 5  ← kubectl edit 改的
```

下次 `kubectl apply -f file.yaml` 会把副本数拉回 3。要么改文件再 apply（声明式），要么 edit 后立刻 `kubectl get <res> -o yaml > file.yaml` 导出。

### 2. 改名后 apply 会更新旧资源还是新建？

不会更新——**会新建**。kubectl apply 按 `apiVersion + kind + metadata.name` 匹配资源。name 变了就是新资源，旧资源继续跑。这时集群里有两份 RS + 它们的 Pod，形成配置文件外的"幽灵资源"。

避免方法：改名就要负责清理上一版，`kubectl delete -f old.yaml && kubectl apply -f new.yaml`。

### 3. ReplicaSet 的 selector 不可变

创建后改 selector 会被 K8s API Server 拒绝。如果 selector 能变，原来匹配的 Pod 突然"不归我管了"——RS 以为副本为 0，立刻创建新 Pod，导致 Pod 所有权混乱和资源泄漏。

### 4. ReplicaSet 改镜像为什么不会滚动更新？

ReplicaSet 只保证副本数，不管 Pod 内容。改 Pod 模板后，**已有的 Pod 不受影响**，只有未来新建的 Pod 才用新模板。这和 Deployment 的自动滚动更新形成鲜明对比——Deployment 会创建新 RS 来逐步替换旧 Pod。

### 5. 节点宕机后 ReplicaSet 多久重建 Pod？

不是秒级。流程：
- kubelet 停止汇报心跳 → 约 40s 后节点标记 NotReady
- `pod-eviction-timeout` 等待 → 默认 5 分钟
- 总计约 **5-6 分钟**后 RS 才开始在其他节点重建 Pod

预留缓冲时间是为了防止短暂网络抖动误判。

## 思考题

1. 如果你把 ReplicaSet 的 `selector` 设得太宽泛（比如只匹配 `app=nginx`），可能会"认领"到不属于它的 Pod。这会造成什么问题？怎么避免？
2. 为什么 K8s 设计者不让 ReplicaSet 的 `selector` 可变？（提示：想想如果 selector 变了，原来匹配的 Pod 会怎样？）
3. 如果一个节点宕机了，上面的 Pod 全部失联。ReplicaSet 是怎么知道要重建这些 Pod 的？它等多久才会开始重建？
4. 在什么场景下，你会选择直接使用 ReplicaSet 而不是 Deployment？

---

下一个 → [03 - StatefulSet](../03-statefulset/)
