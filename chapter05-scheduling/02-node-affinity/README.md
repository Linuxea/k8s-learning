# 02 - 节点亲和性（Node Affinity）：更强大的节点选择

## 为什么需要节点亲和性？

上一节我们学习了 nodeSelector，它简单直接，但有明显局限：

- 只能精确匹配标签值
- 无法表达 "SSD **或** NVMe" 这种 OR 逻辑
- 无法表达 "尽量调度到 SSD 节点，没有也行" 这种偏好
- 无法表达 "不要调度到 HDD 节点" 这种排除逻辑

**节点亲和性（Node Affinity）** 是 nodeSelector 的升级版，它支持：

| 特性 | nodeSelector | Node Affinity |
|------|-------------|---------------|
| 精确匹配 | ✅ | ✅ |
| 操作符（In, NotIn, Exists...） | ❌ | ✅ |
| 软性偏好（调度不了就算了） | ❌ | ✅ |
| 多条件组合 | ❌ | ✅ |
| 权重打分 | ❌ | ✅ |

## 两种亲和性类型

### 1. requiredDuringSchedulingIgnoredDuringExecution（硬性要求）

名字虽然长，但拆开来看就很清晰：

| 部分 | 含义 |
|------|------|
| `required` | **必须满足**，否则 Pod 永远不会被调度（Pending） |
| `DuringScheduling` | 在**调度时**生效 |
| `Ignored` | **忽略** |
| `DuringExecution` | 在 Pod **运行时** |

> **"IgnoredDuringExecution"** 是什么意思？意思是：Pod 已经在节点上运行之后，如果节点的标签发生了变化（比如原来有 `zone=zone-a`，后来被改成了 `zone=zone-b`），Kubernetes **不会**因为这个变化而驱逐或重新调度 Pod。亲和性只在调度阶段生效。

### 2. preferredDuringSchedulingIgnoredDuringExecution（软性偏好）

| 部分 | 含义 |
|------|------|
| `preferred` | **尽量满足**，但如果无法满足，Pod 仍然会被调度到其他节点 |
| `DuringScheduling` | 在**调度时**生效 |
| `IgnoredDuringExecution` | 运行时同样忽略 |

## 支持的操作符

| 操作符 | 含义 | 示例 |
|--------|------|------|
| `In` | 标签值在给定列表中 | `zone In [zone-a, zone-b]` |
| `NotIn` | 标签值不在给定列表中 | `env NotIn [test]` |
| `Exists` | 标签键存在（不关心值） | `gpu Exists` |
| `DoesNotExist` | 标签键不存在 | `special DoesNotExist` |
| `Gt` | 标签值大于给定整数 | `priority Gt 5` |
| `Lt` | 标签值小于给定整数 | `priority Lt 3` |

> **提示**：`Exists` 和 `DoesNotExist` 操作符不需要 `values` 字段。`Gt` 和 `Lt` 只适用于整数值标签。

## 实战演练

### 第一步：给节点打标签

```bash
# 给 worker1 标记为 zone-a 和 SSD
kubectl label nodes k8s-learning-worker zone=zone-a disk=ssd

# 给 worker2 标记为 zone-b 和 HDD
kubectl label nodes k8s-learning-worker2 zone=zone-b disk=hdd
```

验证：

```bash
kubectl get nodes -L zone -L disk
```

### 第二步：创建硬性亲和性的 Pod

```bash
kubectl apply -f required-affinity-pod.yaml
```

这个 Pod 的亲和性条件是：`zone In [zone-a, zone-b]`。两个 worker 都满足条件，调度器会选择资源更优的节点。

```bash
kubectl get pod nginx-required-affinity -o wide
```

### 第三步：创建软性偏好亲和性的 Pod

```bash
kubectl apply -f preferred-affinity-pod.yaml
```

这个 Pod 有两个偏好：
- 权重 80：优先调度到有 `disk=ssd` 的节点（即 worker）
- 权重 50：其次偏好 `zone=zone-a` 的节点

```bash
kubectl get pod nginx-preferred-affinity -o wide
```

应该会被调度到 `k8s-learning-worker`（满足两个偏好条件）。

### 第四步：观察——如果偏好无法满足

假设我们把所有节点都标记为 HDD：

```bash
kubectl label nodes k8s-learning-worker disk=hdd --overwrite
```

然后创建一个新的偏好亲和性 Pod：

```bash
kubectl run pref-test --image=nginx:1.27 --overrides='{
  "spec": {
    "affinity": {
      "nodeAffinity": {
        "preferredDuringSchedulingIgnoredDuringExecution": [{
          "weight": 80,
          "preference": {
            "matchExpressions": [{
              "key": "disk",
              "operator": "In",
              "values": ["ssd"]
            }]
          }
        }]
      }
    }
  }
}'
```

```bash
kubectl get pod pref-test -o wide
```

你会看到 Pod **仍然被调度了**，只是不在偏好节点上。这就是 "preferred" 的含义——尽力而为。

### 第五步：理解 IgnoredDuringExecution

1. 先查看当前 Pod 所在节点：

```bash
kubectl get pod nginx-required-affinity -o wide
```

2. 假设它在 `k8s-learning-worker` 上，修改该节点的标签：

```bash
kubectl label nodes k8s-learning-worker zone=zone-c --overwrite
```

3. 观察 Pod 状态：

```bash
kubectl get pod nginx-required-affinity -o wide
```

Pod **仍在运行**，不会被驱逐。虽然节点标签变了，不再满足 `zone In [zone-a, zone-b]` 的条件，但因为 "IgnoredDuringExecution"，已运行的 Pod 不受影响。

> **注意**：未来 Kubernetes 会引入 `requiredDuringSchedulingRequiredDuringExecution`，在节点标签变化时主动驱逐不满足条件的 Pod，但目前仍是 Alpha 阶段。

### 第六步：清理

```bash
kubectl delete pod nginx-required-affinity nginx-preferred-affinity pref-test --ignore-not-found
kubectl label nodes k8s-learning-worker zone- disk-
kubectl label nodes k8s-learning-worker2 zone- disk-
```

## nodeSelector vs Node Affinity 选择指南

```
需要选择节点吗？
    │
    ├── 不需要复杂逻辑（只需一个标签精确匹配）
    │   └── 使用 nodeSelector
    │
    └── 需要复杂逻辑
        ├── 必须调度到特定节点（否则宁可 Pending）
        │   └── 使用 required nodeAffinity
        │
        └── 希望调度到特定节点（但不强制）
            └── 使用 preferred nodeAffinity
```

## 思考题

1. 如果一个 Pod 同时设置了 `required` 和 `preferred` 亲和性，调度器会怎样处理？
2. `nodeSelector` 和 `requiredDuringSchedulingIgnoredDuringExecution` 可以同时使用吗？如果可以，它们之间是什么关系？
3. 为什么 Kubernetes 设计了 "IgnoredDuringExecution" 而不是默认就驱逐不满足条件的 Pod？这样设计有什么好处和坏处？
4. `Gt` 和 `Lt` 操作符在实际场景中可能有什么用途？

---

**[下一节：污点与容忍 →](../03-taints-tolerations/README.md)**
