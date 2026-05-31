# 03 - 污点与容忍（Taints and Tolerations）：节点的"防护盾"

## 核心概念

如果说 nodeSelector 和亲和性是 **Pod 选择节点**（Pod 主动），那么污点和容忍就是 **节点排斥 Pod**（节点主动）。

```
┌──────────────────────────────────────────────────────┐
│                                                      │
│  nodeSelector / Affinity:  Pod 说 "我想去这个节点"     │
│  Taints & Tolerations:     节点说 "没有通行证别进来"  │
│                                                      │
│  两者同时生效：Pod 既要有"意愿"（affinity），          │
│              又要有"通行证"（toleration）              │
└──────────────────────────────────────────────────────┘
```

## 污点（Taints）

污点是标记在**节点**上的属性，格式为 `key=value:effect`。

| 组成部分 | 说明 | 示例 |
|----------|------|------|
| key | 污点的键名 | `gpu`、`dedicated`、`special-workload` |
| value | 污点的值（可选） | `true`、`high-priority` |
| effect | 污点的效果 | `NoSchedule`、`PreferNoSchedule`、`NoExecute` |

### 三种效果（Effect）

| Effect | 含义 | 行为 |
|--------|------|------|
| `NoSchedule` | **不调度** | 新 Pod 不能调度到该节点，已运行的 Pod 不受影响 |
| `PreferNoSchedule` | **尽量不调度** | 调度器会尽量避免调度新 Pod 到该节点，但实在没地方时也会调度 |
| `NoExecute` | **不调度 + 驱逐** | 新 Pod 不能调度，且**已经运行但不容忍该污点的 Pod 会被驱逐** |

> **重要区别**：`NoExecute` 是唯一会影响已运行 Pod 的效果。当给节点添加 `NoExecute` 污点时，没有对应容忍的 Pod 会被立即驱逐（除非设置了 `tolerationSeconds`）。

## 容忍（Tolerations）

容忍是定义在 **Pod** 上的属性，表示这个 Pod 可以"忍受"某些污点。

| 字段 | 说明 |
|------|------|
| `key` | 匹配的污点键名 |
| `operator` | `Equal`（精确匹配）或 `Exists`（只要键存在即可） |
| `value` | 污点的值（`Exists` 操作符不需要） |
| `effect` | 匹配的污点效果（留空表示匹配所有效果） |
| `tolerationSeconds` | 仅用于 `NoExecute`，表示容忍多少秒后驱逐 Pod |

## 匹配规则

```
污点: gpu=true:NoSchedule
                          匹配？
容忍: key=gpu, operator=Equal, value=true, effect=NoSchedule  → ✅ 完全匹配
容忍: key=gpu, operator=Equal, value=true, effect=空          → ✅ 匹配所有效果
容忍: key=gpu, operator=Exists, effect=NoSchedule             → ✅ 不关心 value
容忍: key=gpu, operator=Exists, effect=空                     → ✅ 双通配
容忍: key=gpu, operator=Equal, value=false, effect=NoSchedule → ❌ value 不匹配
```

> **特殊容忍**：空的 `key` + `operator=Exists` 会匹配**所有污点**，相当于"万能通行证"。

## kind 集群中的默认污点

kind 创建的集群中，control-plane 节点默认带有污点：

```bash
kubectl describe node k8s-learning-control-plane | grep Taints
```

输出：

```
Taints: node-role.kubernetes.io/control-plane:NoSchedule
```

这就是为什么普通 Pod 不会调度到 control-plane 节点上的原因。

## 实战演练

### 第一步：查看当前节点污点

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

### 第二步：给 worker 节点添加污点

模拟一个专用节点（比如 GPU 节点）：

```bash
kubectl taint nodes k8s-learning-worker special-workload=true:NoSchedule
```

验证：

```bash
kubectl describe node k8s-learning-worker | grep Taints
```

### 第三步：创建没有容忍的 Pod（应该调度到其他节点）

```bash
kubectl run no-toleration --image=nginx:1.27
```

```bash
kubectl get pod no-toleration -o wide
```

这个 Pod **不会**被调度到 `k8s-learning-worker`，因为没有匹配的容忍。它应该被调度到 `k8s-learning-worker2`。

### 第四步：创建带容忍的 Pod

```bash
kubectl apply -f tainted-node-pod.yaml
```

```bash
kubectl get pod nginx-with-toleration -o wide
```

这个 Pod 有 `special-workload=true:NoSchedule` 的容忍，**可以**被调度到 `k8s-learning-worker`。

### 第五步：演示 NoExecute 效果（驱逐）

1. 先给另一个节点也加 NoSchedule 污点：

```bash
kubectl taint nodes k8s-learning-worker2 test-taint=value:NoSchedule
```

2. 创建一个 Pod（注意它会 Pending，因为两个 worker 都有污点且 Pod 没有容忍）：

```bash
kubectl run pending-pod --image=nginx:1.27
kubectl get pod pending-pod
```

3. 清理并恢复：

```bash
kubectl delete pod pending-pod
kubectl taint nodes k8s-learning-worker2 test-taint-
```

### 第六步：演示专用节点场景

```bash
# 先给 worker 打标签和污点
kubectl label nodes k8s-learning-worker hardware=gpu
kubectl taint nodes k8s-learning-worker gpu=true:NoSchedule

# 应用演示文件
kubectl apply -f dedicated-node-demo.yaml

# 观察调度结果
kubectl get pods -o wide
```

预期结果：
- `gpu-workload`：有 toleration + nodeSelector，调度到 `k8s-learning-worker`
- `normal-workload`：没有 toleration，调度到 `k8s-learning-worker2`

### 第七步：清理

```bash
kubectl delete -f dedicated-node-demo.yaml
kubectl delete pod no-toleration nginx-with-toleration --ignore-not-found
kubectl taint nodes k8s-learning-worker special-workload- gpu-
kubectl label nodes k8s-learning-worker hardware-
```

## 污点与容忍的典型使用场景

| 场景 | 污点 | 说明 |
|------|------|------|
| **Master 节点专用** | `node-role.kubernetes.io/control-plane:NoSchedule` | 默认已有，防止工作负载调度到控制面 |
| **GPU 节点专用** | `nvidia.com/gpu=true:NoSchedule` | 只有 GPU 任务能使用 GPU 节点 |
| **专用节点** | `dedicated=tenant-a:NoSchedule` | 多租户场景下为特定租户保留节点 |
| **节点维护** | `key=value:NoExecute` | 节点需要维护时驱逐所有 Pod |
| **问题节点** | `node.kubernetes.io/not-ready:NoExecute` | 节点异常时自动添加，默认 300 秒后驱逐 |

> **提示**：Kubernetes 会自动给节点添加一些污点，比如 `node.kubernetes.io/not-ready`（节点 NotReady 时）和 `node.kubernetes.io/unreachable`（节点不可达时）。Pod 默认有对这些污点的容忍（`tolerationSeconds: 300`），所以节点异常后 300 秒才会驱逐 Pod。

## 亲和性 + 污点的协同工作

调度器在做调度决策时，**同时**考虑亲和性和污点：

```
Pod 能否调度到节点 N？

1. 检查 nodeSelector          → 不匹配？排除
2. 检查 nodeAffinity (required) → 不匹配？排除
3. 检查 Taints & Tolerations   → 有未容忍的 NoSchedule 污点？排除
4. 检查 nodeAffinity (preferred) → 用于打分排序
5. 综合打分，选择最优节点
```

## 思考题

1. 如果一个节点有 `NoSchedule` 污点，但 Pod 有一个空的容忍（空 key + Exists），Pod 能调度上去吗？
2. `NoExecute` 效果配合 `tolerationSeconds` 可以实现什么场景？试想一个具体例子。
3. 为什么 kind 的 control-plane 节点用污点而不是用 nodeSelector 来防止工作负载调度？
4. 如果一个 Pod 同时有 nodeSelector 指向节点 A，但节点 A 有未容忍的污点，会发生什么？

---

**[下一节：Pod 拓扑分布约束 →](../04-pod-topology/README.md)**
