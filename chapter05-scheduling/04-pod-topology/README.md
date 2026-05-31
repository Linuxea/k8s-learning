# 04 - Pod 拓扑分布约束（Topology Spread Constraints）：让副本均匀分布

## 为什么需要拓扑分布？

前面几节我们学习了如何控制 Pod 调度到**哪些**节点上（nodeSelector、亲和性、污点）。但有一个问题还没解决：**如何让副本均匀分布？**

考虑这个场景：

```
你有一个 Deployment，有 6 个副本，集群有 3 个节点。
你希望每个节点运行 2 个 Pod，而不是某个节点上运行 6 个。

默认调度器会怎么做？
→ 它会考虑资源均衡，但不保证均匀分布。
→ 可能出现节点 A 上 3 个，节点 B 上 2 个，节点 C 上 1 个。
```

**拓扑分布约束（Topology Spread Constraints）** 就是解决这个问题的：它确保 Pod 副本在拓扑域之间均匀分布。

## 与其他调度机制的区别

| 机制 | 解决的问题 | 类比 |
|------|-----------|------|
| nodeSelector | Pod 去**哪个**节点 | 指定目的地 |
| Node Affinity | Pod 去**哪类**节点 | 设定偏好方向 |
| Taints & Tolerations | 节点**允许谁**进来 | 设置门禁 |
| **Topology Spread** | 每个地方放**多少** Pod | 控制分布密度 |

## 核心字段解析

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: web
```

| 字段 | 含义 | 说明 |
|------|------|------|
| `maxSkew` | 最大倾斜度 | 各拓扑域之间允许的 Pod 数量最大差值。`1` 表示最均匀分布 |
| `topologyKey` | 拓扑域的节点标签键 | `kubernetes.io/hostname` = 每个节点一个域；`topology.kubernetes.io/zone` = 每个可用区一个域 |
| `whenUnsatisfiable` | 无法满足时的策略 | `DoNotSchedule`（不调度，严格）或 `ScheduleAnyway`（调度，宽松） |
| `labelSelector` | 选择要统计的 Pod | 调度器计算各域中匹配此 selector 的 Pod 数量 |

### whenUnsatisfiable 详解

| 值 | 行为 | 使用场景 |
|----|------|---------|
| `DoNotSchedule` | 如果放入 Pod 会导致 `maxSkew` 超出，则不调度（Pending） | **生产环境**，确保高可用均匀分布 |
| `ScheduleAnyway` | 尽量均匀，但如果无法满足，仍然调度到偏多的域 | **优先保证可用性**，宁可分布不均也不要 Pending |

### maxSkew 图解

假设 3 个节点，`maxSkew=1`，已有 4 个 Pod：

```
节点 A: ●●      (2 个 Pod)
节点 B: ●●      (2 个 Pod)
节点 C: ●       (1 个 Pod)

当前最大倾斜度 = max(2,2,1) - min(2,2,1) = 2 - 1 = 1 ✅ 满足

新 Pod 应该调度到哪里？
→ 必须调度到节点 C（放入 C 后：2-2-2，倾斜度 0）
→ 如果放到 A 或 B：3-2-1，倾斜度 2，超过 maxSkew=1 ❌
```

## 实战演练

### 第一步：给节点添加拓扑标签

```bash
# 给 worker 标记不同的可用区（模拟多可用区集群）
kubectl label nodes k8s-learning-worker zone=zone-a
kubectl label nodes k8s-learning-worker2 zone=zone-b
# control-plane 也标记（虽然通常不调度工作负载到这里）
kubectl label nodes k8s-learning-control-plane zone=zone-a
```

验证：

```bash
kubectl get nodes -L zone
```

### 第二步：创建带有拓扑分布约束的 Deployment

```bash
kubectl apply -f topology-spread-demo.yaml
```

### 第三步：观察 Pod 分布

```bash
kubectl get pods -l app=web -o wide --sort-by=.spec.nodeName
```

预期输出（6 个副本分布在 2 个节点上，每个节点 3 个）：

```
NAME                                   READY   STATUS    NODE
topology-spread-demo-xxxxxxxxxx-xxxxx  1/1     Running   k8s-learning-worker
topology-spread-demo-xxxxxxxxxx-xxxxx  1/1     Running   k8s-learning-worker
topology-spread-demo-xxxxxxxxxx-xxxxx  1/1     Running   k8s-learning-worker
topology-spread-demo-xxxxxxxxxx-xxxxx  1/1     Running   k8s-learning-worker2
topology-spread-demo-xxxxxxxxxx-xxxxx  1/1     Running   k8s-learning-worker2
topology-spread-demo-xxxxxxxxxx-xxxxx  1/1     Running   k8s-learning-worker2
```

> **注意**：control-plane 有 `node-role.kubernetes.io/control-plane:NoSchedule` 污点，所以 Pod 不会调度到那里。实际上只有 2 个可用节点。

### 第四步：对比——没有拓扑分布约束的情况

```bash
# 创建一个没有拓扑分布约束的 Deployment 作为对比
kubectl create deployment no-spread --image=nginx:1.27 --replicas=6

# 观察分布
kubectl get pods -l app=no-spread -o wide --sort-by=.spec.nodeName
```

你会发现分布可能不那么均匀，取决于调度器当时的打分结果。

### 第五步：测试 DoNotSchedule 的严格性

1. 缩容到 3 个副本：

```bash
kubectl scale deployment topology-spread-demo --replicas=3
```

2. 给 worker 节点添加一个污点，让它不可用：

```bash
kubectl taint nodes k8s-learning-worker test-block=true:NoSchedule
```

3. 扩容到 4 个副本：

```bash
kubectl scale deployment topology-spread-demo --replicas=4
```

4. 观察新 Pod 的状态：

```bash
kubectl get pods -l app=web -o wide
```

新 Pod 会处于 `Pending` 状态，因为：
- worker 有污点，不能调度
- worker2 已经有 3 个 Pod，再放一个会导致 `maxSkew` 超出（3→4 vs 0，倾斜度 4 > 1）

5. 改用 `ScheduleAnyway` 重新测试：

编辑 Deployment，将 `whenUnsatisfiable` 改为 `ScheduleAnyway`，然后观察新 Pod 会被调度。

### 第六步：清理

```bash
kubectl delete deployment topology-spread-demo no-spread
kubectl taint nodes k8s-learning-worker test-block- --ignore-not-found
kubectl label nodes k8s-learning-worker zone-
kubectl label nodes k8s-learning-worker2 zone-
kubectl label nodes k8s-learning-control-plane zone-
```

## 实际应用场景

### 多可用区高可用

```yaml
# 跨可用区均匀分布：6 个副本 × 3 个可用区 = 每区 2 个
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone  # 按可用区分域
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: my-app
```

### 跨节点反亲和

```yaml
# 每个节点最多一个 Pod（类似 podAntiAffinity 但更灵活）
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname  # 按节点分域
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: my-app
```

### 拓扑分布 vs PodAntiAffinity

| 对比维度 | podAntiAffinity | topologySpreadConstraints |
|---------|----------------|--------------------------|
| 控制粒度 | "不要放在一起" | "均匀分布，控制偏差" |
| 分布精度 | 粗略（避免同节点） | 精确（指定 maxSkew） |
| 性能 | 大量 Pod 时性能差 | 性能更优 |
| 推荐度 | 简单场景可用 | **Kubernetes 官方推荐** |

> **官方推荐**：对于需要均匀分布的场景，优先使用 `topologySpreadConstraints` 而不是 `podAntiAffinity`。

## 思考题

1. 如果 `maxSkew=0`，会发生什么？Kubernetes 允许设置为 0 吗？
2. 当使用 `topologyKey: topology.kubernetes.io/zone` 但节点没有这个标签时，调度器会怎么处理？
3. `topologySpreadConstraints` 和 `podAntiAffinity` 可以同时使用吗？如果可以，有什么效果？
4. 在一个 3 节点集群中，设置 `maxSkew=1`、`whenUnsatisfiable=DoNotSchedule`，5 个副本。如果其中一个节点突然不可用，第 5 个副本能调度吗？

---

**[下一节：自定义调度器 →](../05-custom-scheduler/README.md)**
