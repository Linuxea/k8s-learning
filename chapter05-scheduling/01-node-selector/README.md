# 01 - nodeSelector：最简单的节点选择

## 调度器是如何工作的？

当你创建一个 Pod 时，Kubernetes 调度器（kube-scheduler）负责决定这个 Pod 应该运行在集群中的哪个节点上。这个过程分为三个阶段：

```
创建 Pod → 调度器介入 → 过滤节点 → 打分节点 → 选择最优节点 → 绑定 Pod 到节点
```

| 阶段 | 说明 |
|------|------|
| **过滤（Filter）** | 排除不满足条件的节点：资源不足、不满足 nodeSelector/affinity、有未容忍的污点等 |
| **打分（Score）** | 对通过过滤的节点按策略打分：资源均衡、亲和性偏好、反亲和性等 |
| **绑定（Bind）** | 选择得分最高的节点，将 Pod 绑定到该节点上运行 |

如果没有节点满足条件，Pod 会一直处于 `Pending` 状态。

## 为什么需要 nodeSelector？

在默认情况下，调度器会自动将 Pod 调度到资源充足的节点上。但在实际场景中，你可能有以下需求：

- 某些 Pod 需要运行在配有 SSD 磁盘的节点上
- 某些 Pod 需要运行在特定机房的节点上
- 某些 Pod 需要运行在配有 GPU 的节点上

**nodeSelector** 是最简单的节点选择方式：给节点打标签，然后在 Pod 中指定标签匹配条件。

## nodeSelector 工作原理

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│  给节点打标签  │ ──→ │  Pod 指定     │ ──→ │  调度器匹配标签   │
│  disk=ssd    │     │  nodeSelector │     │  选择正确节点     │
└─────────────┘     └──────────────┘     └─────────────────┘
```

nodeSelector 只支持**精确匹配**：Pod 的 nodeSelector 中的每个键值对都必须在目标节点的标签中完全对应。

## 实战演练

### 第一步：查看当前集群节点

```bash
kubectl get nodes
```

输出应该类似：

```
NAME                          STATUS   ROLES           AGE   VERSION
k8s-learning-control-plane    Ready    control-plane   10d   v1.31.0
k8s-learning-worker           Ready    <none>          10d   v1.31.0
k8s-learning-worker2          Ready    <none>          10d   v1.31.0
```

### 第二步：查看节点现有标签

```bash
kubectl get nodes --show-labels
```

你会看到每个节点都有很多默认标签，比如 `kubernetes.io/hostname`、`beta.kubernetes.io/arch` 等。

### 第三步：给 worker 节点打标签

模拟一个配有 SSD 磁盘的节点：

```bash
# 给 worker1 标记为 SSD 磁盘
kubectl label nodes k8s-learning-worker disk=ssd

# 给 worker2 标记为 HDD 磁盘
kubectl label nodes k8s-learning-worker2 disk=hdd
```

验证标签：

```bash
kubectl get nodes -L disk
```

输出：

```
NAME                          STATUS   ROLES           AGE   VERSION   DISK
k8s-learning-control-plane    Ready    control-plane   10d   v1.31.0
k8s-learning-worker           Ready    <none>          10d   v1.31.0   ssd
k8s-learning-worker2          Ready    <none>          10d   v1.31.0   hdd
```

### 第四步：创建使用 nodeSelector 的 Pod

```bash
kubectl apply -f node-labeled-pod.yaml
```

查看 Pod 被调度到哪个节点：

```bash
kubectl get pod nginx-on-ssd -o wide
```

你应该能看到 Pod 被调度到了 `k8s-learning-worker`（disk=ssd 的节点）。

### 第五步：验证——如果标签不匹配会怎样？

创建一个 nodeSelector 指向不存在标签的 Pod：

```bash
kubectl run test-pending --image=nginx:1.27 --overrides='{"spec":{"nodeSelector":{"disk":"nvme"}}}'
```

查看状态：

```bash
kubectl get pod test-pending -o wide
```

你会看到 Pod 一直处于 `Pending` 状态。查看原因：

```bash
kubectl describe pod test-pending | grep -A5 Events
```

输出会显示类似：

```
Warning  FailedScheduling  ...  0/3 nodes are available: 3 node(s) didn't match Pod's node affinity/selector.
```

### 第六步：清理

```bash
kubectl delete pod nginx-on-ssd test-pending
kubectl label nodes k8s-learning-worker disk-
kubectl label nodes k8s-learning-worker2 disk-
```

> **注意**：`disk-` 这种写法表示删除 `disk` 这个标签。

## nodeSelector 的局限性

| 局限 | 说明 |
|------|------|
| **只支持精确匹配** | 无法表达 "SSD 或 NVMe" 这种 "或" 逻辑 |
| **没有偏好机制** | 无法表达 "尽量用 SSD，没有也行" |
| **没有操作符** | 不支持 In、NotIn、Exists 等操作符 |
| **无法表达复杂条件** | 无法组合多个条件的 AND/OR 逻辑 |

正是因为这些局限，Kubernetes 引入了**节点亲和性（Node Affinity）**，这就是下一节的内容。

## 思考题

1. 如果一个 Pod 的 nodeSelector 指定了 `disk=ssd`，但集群中没有任何节点有这个标签，Pod 会怎样？
2. nodeSelector 和节点标签之间的关系是什么？是节点"拉取"Pod，还是 Pod "选择"节点？
3. 如果给一个已经运行的 Pod 所在节点删除了匹配的标签，Pod 会被驱逐吗？为什么？
4. 在什么场景下，简单的 nodeSelector 就足够了，不需要更复杂的亲和性？

## 常见困惑

1. **"节点标签删了，Pod 会不会被驱逐？"** — 不会。nodeSelector 只在调度阶段生效，Pod 一旦绑定到节点，标签变化不影响已运行的 Pod。调度器不会持续监控标签变化来驱逐 Pod。

2. **"control-plane 是不是标签机制？"** — 不是。control-plane 是节点角色（通过 `node-role.kubernetes.io/control-plane` 标签标识），和 nodeSelector 是两个概念。nodeSelector 用的是自定义标签。

3. **"`--show-labels` 输出太长看不清"** — 可以用 `kubectl get nodes -L disk` 只显示特定标签列，更简洁。

---

**[下一节：节点亲和性 →](../02-node-affinity/README.md)**
