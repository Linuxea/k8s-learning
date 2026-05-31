# 05 - 自定义调度器：Kubernetes 调度框架

## 默认调度器的局限性

前面四节我们学习的调度机制（nodeSelector、亲和性、污点、拓扑分布）都是通过**声明式配置**来影响默认调度器 `kube-scheduler` 的行为。但在某些场景下，默认调度器可能无法满足需求：

| 场景 | 默认调度器的局限 |
|------|-----------------|
| **批处理任务** | 需要考虑任务队列、优先级、Gang 调度（一组任务要么全部调度，要么全部不调度） |
| **大数据 / AI 训练** | 需要考虑 GPU 拓扑、RDMA 网络亲和性 |
| **多租户公平调度** | 需要保证不同租户之间的公平性，类似 YARN 的队列机制 |
| **成本优化** | 需要优先调度到 Spot 实例，只在必要时使用按量付费实例 |

这些场景需要**自定义调度器**。

## Kubernetes 调度框架（Scheduling Framework）

Kubernetes 从 1.19 开始，调度框架（Scheduling Framework）成为稳定特性。它把调度过程拆分为**可扩展的插件**：

```
                    Kubernetes 调度周期
    ┌──────────────────────────────────────────────────┐
    │                                                  │
    │  ┌─────┐  ┌────────┐  ┌───────┐  ┌──────┐       │
    │  │Queue│→ │Filter  │→ │Score  │→ │Bind  │       │
    │  │Sort │  │(过滤)   │  │(打分)  │  │(绑定) │       │
    │  └─────┘  └────────┘  └───────┘  └──────┘       │
    │     ↑          ↑           ↑          ↑          │
    │  QueueSort  Filter      Score      BindPlugin    │
    │  Plugin     Plugins     Plugins                   │
    │                                                  │
    └──────────────────────────────────────────────────┘
```

### 调度周期详解

| 阶段 | 扩展点 | 说明 |
|------|--------|------|
| **排序** | `QueueSort` | 对等待调度的 Pod 队列排序（如按优先级） |
| **预过滤** | `PreFilter` | 在过滤前做预处理（如缓存计算） |
| **过滤** | `Filter` | 排除不满足条件的节点（硬性要求） |
| **预打分** | `PreScore` | 在打分前做预处理 |
| **打分** | `Score` | 对通过过滤的节点打分排序 |
| **绑定** | `Bind` | 将 Pod 绑定到选中的节点 |
| **绑定后** | `PostBind` | 绑定完成后的清理工作 |

> **关键理解**：你可以编写自定义插件，插入到上述任何一个扩展点中。这就是自定义调度器的基础。

## 如何使用自定义调度器

### schedulerName 字段

每个 Pod 都有一个 `schedulerName` 字段，默认值是 `default-scheduler`：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-pod
spec:
  schedulerName: default-scheduler  # 默认值，通常省略
  containers:
    - name: nginx
      image: nginx:1.27
```

如果你部署了一个名为 `my-custom-scheduler` 的自定义调度器，只需要：

```yaml
spec:
  schedulerName: my-custom-scheduler
```

> **注意**：如果指定的调度器不存在，Pod 会一直处于 `Pending` 状态。调度器也是一个普通的系统 Pod，需要以 Deployment 形式部署在集群中。

### 多调度器共存

Kubernetes 支持**多个调度器同时运行**：

```
集群中同时运行：
┌────────────────────────────┐
│  kube-scheduler            │  ← 默认调度器，处理 schedulerName=default-scheduler 的 Pod
│  (default-scheduler)       │
├────────────────────────────┤
│  volcano-scheduler         │  ← Volcano 调度器，处理 schedulerName=volcano 的 Pod
│  (volcano)                 │
├────────────────────────────┤
│  yunikorn-scheduler        │  ← Yunikorn 调度器，处理 schedulerName=yunikorn 的 Pod
│  (yunikorn)                │
└────────────────────────────┘
```

每个调度器只处理指定了对应 `schedulerName` 的 Pod，互不干扰。

## 实战演练

### 第一步：观察默认调度器的行为

```bash
# 查看默认调度器的 Pod
kubectl get pods -n kube-system -l component=kube-scheduler
```

```bash
# 查看默认调度器的日志
kubectl logs -n kube-system -l component=kube-scheduler --tail=20
```

### 第二步：创建显式使用默认调度器的 Pod

```bash
kubectl apply -f default-scheduler-pod.yaml
```

```bash
# 验证 Pod 被正常调度
kubectl get pod nginx-default-scheduler -o wide
```

```bash
# 查看 Pod 的 schedulerName
kubectl get pod nginx-default-scheduler -o jsonpath='{.spec.schedulerName}'
# 输出: default-scheduler
```

### 第三步：模拟自定义调度器不存在的场景

```bash
# 创建一个指定了不存在调度器的 Pod
kubectl run ghost-pod --image=nginx:1.27 --overrides='{"spec":{"schedulerName":"non-existent-scheduler"}}'
```

```bash
# 观察 Pod 状态
kubectl get pod ghost-pod
# 状态应该是 Pending
```

```bash
# 查看事件
kubectl describe pod ghost-pod | grep -A5 Events
# 会看到: Warning FailedScheduling ... no matching scheduler
```

因为没有名为 `non-existent-scheduler` 的调度器在运行，Pod 永远不会被调度。

### 第四步：清理

```bash
kubectl delete pod nginx-default-scheduler ghost-pod
```

## 真实世界的自定义调度器

### Volcano（批量调度）

Volcano 是 CNCF 孵化项目，专为 AI/ML 和大数据批处理场景设计：

| 特性 | 说明 |
|------|------|
| **Gang 调度** | 一组任务要么全部启动，要么全部不启动（防止部分任务占用资源死锁） |
| **队列管理** | 支持多租户队列，按队列分配资源 |
| **优先级抢占** | 高优先级任务可以抢占低优先级任务的资源 |
| **Fair Sharing** | 保证租户之间的资源公平分配 |

### Yunikorn（YARN-like 调度）

Yunikorn 提供类似 Apache YARN 的调度能力：

| 特性 | 说明 |
|------|------|
| **层次化队列** | 支持嵌套队列结构 |
| **弹性配额** | 队列可以借用其他队列的空闲资源 |
| **应用感知** | 按应用而非单个 Pod 做调度决策 |
| **多租户** | 内置租户隔离和公平调度 |

### KubeSphere / K8s 原生扩展

通过调度框架的扩展点，可以实现：

- **拓扑感知调度**：考虑 NUMA 拓扑、GPU 拓扑
- **负载感知调度**：优先调度到实际负载低的节点
- **成本感知调度**：优先使用 Spot/Preemptible 实例

## 自定义调度器的实现方式

| 方式 | 复杂度 | 说明 |
|------|--------|------|
| **调度框架插件** | 中 | 编写 Go 插件，编译到 kube-scheduler 中 |
| **独立调度器** | 高 | 从头实现完整的调度器（需要监听 Pod、Node、Bind 等操作） |
| **Scheduler Extender** | 中 | 通过 Webhook 扩展默认调度器（旧方式，不推荐新项目使用） |

> **推荐**：新项目优先使用调度框架插件方式。如果需要完全不同的调度策略，可以考虑独立调度器。

## 本章总结

回顾整个第五章，我们学习了 Kubernetes 调度的完整体系：

```
┌─────────────────────────────────────────────────────┐
│              Kubernetes 调度机制全景图                │
├─────────────────────────────────────────────────────┤
│                                                     │
│  ① nodeSelector        → 精确匹配节点标签            │
│  ② Node Affinity       → 表达式匹配（硬性+软性）     │
│  ③ Taints/Tolerations  → 节点排斥未授权的 Pod        │
│  ④ Topology Spread     → 控制副本均匀分布            │
│  ⑤ Custom Scheduler    → 完全自定义调度逻辑          │
│                                                     │
│  从简单到复杂，从声明式到编程式                       │
│                                                     │
└─────────────────────────────────────────────────────┘
```

| 需求 | 推荐方案 |
|------|---------|
| Pod 需要运行在特定类型的节点上 | nodeSelector 或 Node Affinity |
| 某些节点只允许特定 Pod 使用 | Taints & Tolerations |
| 副本需要在拓扑域间均匀分布 | Topology Spread Constraints |
| 以上都不满足，需要自定义调度逻辑 | 自定义调度器 |

## 思考题

1. 如果集群中有两个调度器同时运行，它们会互相干扰吗？为什么？
2. `schedulerName` 是在 Pod 创建时还是运行时生效的？能否在 Pod 运行后修改？
3. Volcano 的 Gang 调度解决了什么问题？如果不使用 Gang 调度，在 AI 训练场景中会出现什么问题？
4. 为什么 Kubernetes 选择插件式的调度框架，而不是让所有人都使用默认调度器？

---

**[← 返回章节目录](../)**
