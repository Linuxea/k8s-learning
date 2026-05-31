# 05 - 资源限制（Resource Limits）

## 为什么资源管理很重要

K8s 集群中的资源（CPU、内存）是有限的。如果一个 Pod 没有设置资源限制：

1. **一个 Pod 可能吃光整个节点的资源** — 一个内存泄漏的应用可以把节点上所有其他 Pod 都拖垮
2. **调度器无法做出正确决策** — K8s 调度器根据 Pod 的 `requests` 来选择节点，没设 `requests` = 调度器"盲猜"
3. **节点不稳定** — 内存耗尽触发 Linux OOM Killer，可能杀掉任意进程（包括 kubelet）

```
┌──────────────────────────────────────────┐
│               节点 (8 CPU, 16Gi 内存)      │
│                                          │
│  Pod A (没设限制)     正常 Pod B          │
│  ████████████████    ██                   │
│  吃了 90% 内存       只剩 10%             │
│                                          │
│  → Pod B 被 OOM Kill                     │
│  → 节点变得不稳定                         │
└──────────────────────────────────────────┘
```

## requests vs limits

每个容器可以设置两种资源值：

| 字段 | 含义 | 影响 |
|------|------|------|
| `requests` | 容器**最少需要**的资源 | 调度器用来决定把 Pod 放到哪个节点；节点上的资源分配不能超过容量 |
| `limits` | 容器**最多能用**的资源 | 运行时的硬上限。CPU 超了被限速，内存超了被杀 |

```yaml
resources:
  requests:
    cpu: "500m"      # 调度保证：至少有 0.5 CPU 可用
    memory: "128Mi"  # 调度保证：至少有 128Mi 内存可用
  limits:
    cpu: "1000m"     # 运行上限：最多用 1 CPU
    memory: "256Mi"  # 运行上限：最多用 256Mi 内存
```

> **类比**：`requests` 是你向公司申请的工位大小（保证你有这么多空间），`limits` 是你实际能使用的最大空间。如果别人都没来，你可以暂时多用一点（CPU 可压缩），但内存不行。

### 一个常见的误解

"设了 requests 就能保证我的容器一直有这么多资源可用" — **不一定**。

- **CPU**：是**可压缩资源**（compressible）。如果节点上 CPU 紧张，所有容器会被限速，但不会被杀
- **内存**：是**不可压缩资源**（incompressible）。如果节点内存不足，K8s 必须杀掉一些 Pod 来释放内存

## CPU 单位

| 单位 | 等价 | 说明 |
|------|------|------|
| `1` | 1 个 CPU 核心 | 可以是 1 个超线程 |
| `1000m` | 1 个 CPU 核心 | millicores 表示法 |
| `500m` | 0.5 个 CPU | 即 500 millicores |
| `100m` | 0.1 个 CPU | 最小建议粒度 |
| `0.5` | 500m | 小数表示法，等价于 500m |

> CPU 是可压缩资源。容器可以超过 `requests` 使用 CPU（如果节点有空闲），但不能超过 `limits`。超过 `limits` 会被限速（throttled），不会被杀。

```
容器 CPU 使用: ━━━━━━━━━━━━━━━━ 请求 500m
                              ┆ limits 1000m
                              ┆
实际使用 800m ━━━━━━━━━━━━━━━━━━━━  ← 在 requests 和 limits 之间，OK
实际使用 1200m ━━━━━━━━━━━━━━━━━━━━━━━━  ← 超过 limits，被限速到 1000m
```

## 内存单位

| 单位 | 含义 |
|------|------|
| `Mi` | Mebibytes (2^20 bytes = 1,048,576 bytes) |
| `Gi` | Gibibytes (2^30 bytes) |
| `M` | Megabytes (10^6 bytes) — 注意和 Mi 的区别 |
| `G` | Gigabytes (10^9 bytes) |

> **永远用 `Mi/Gi`**，不用 `M/G`。`Mi` 是二进制单位（1024 进制），`M` 是十进制单位（1000 进制）。K8s 文档和社区都推荐 `Mi/Gi`。

### 内存超限会怎样？

内存是**不可压缩**的。容器使用的内存超过 `limits` → **OOMKilled**（被 Linux OOM Killer 杀死）。

```
容器启动 → 正常运行 → 内存逐渐增长 → 超过 limits → OOMKilled!
                                                          │
                                                      容器退出，Exit Code: 137
```

> Exit Code 137 = 128 (信号基础值) + 9 (SIGKILL 信号编号)。看到 137 就是 OOM。

## QoS 类别（服务质量等级）

K8s 根据每个 Pod 中**所有容器**的 `requests` 和 `limits` 设置，自动将其分为三个 QoS 类别：

### Guaranteed（有保证）

**条件**（必须同时满足）：
- Pod 内**每个容器**都设置了 CPU 和内存的 requests 和 limits
- 每个容器的 `requests.cpu == limits.cpu`
- 每个容器的 `requests.memory == limits.memory`

**特点**：节点资源不足时，**最后被驱逐**。最高优先级。

```yaml
resources:
  requests:
    cpu: "500m"      # = limits.cpu
    memory: "128Mi"  # = limits.memory
  limits:
    cpu: "500m"
    memory: "128Mi"
```

### Burstable（可突发）

**条件**：Pod 不满足 Guaranteed 条件，但至少一个容器设置了 requests 或 limits。

**特点**：节点资源不足时，**第二个被驱逐**。可以临时使用超出 requests 的资源。

```yaml
resources:
  requests:
    cpu: "200m"      # < limits
    memory: "64Mi"   # < limits
  limits:
    cpu: "500m"
    memory: "256Mi"
```

### BestEffort（尽力而为）

**条件**：Pod 内**所有容器都没有**设置任何 requests 和 limits。

**特点**：节点资源不足时，**最先被驱逐**。可以使用节点上任何可用资源，但毫无保障。

```yaml
# 没有设置 resources 字段
```

### QoS 判定流程

```
所有容器都设了 requests == limits (CPU + 内存)？
    │
    ├── 是 → Guaranteed
    │
    └── 否 → 至少一个容器设了 requests 或 limits？
                │
                ├── 是 → Burstable
                │
                └── 否 → BestEffort
```

### 驱逐优先级

当节点资源不足，kubelet 需要驱逐 Pod 时：

```
最先驱逐: BestEffort Pods (无资源保障)
    │
    ▼
其次驱逐: Burstable Pods (按实际使用量占 requests 的比例排序，超用越多越先驱逐)
    │
    ▼
最后驱逐: Guaranteed Pods (基本不会被驱逐)
```

## Step by Step：创建三种 QoS 的 Pod

### Step 1: 创建三个 Pod

```bash
kubectl apply -f guaranteed-pod.yaml
kubectl apply -f burstable-pod.yaml
kubectl apply -f besteffort-pod.yaml
```

### Step 2: 查看所有 Pod

```bash
kubectl get pods
# NAME              READY   STATUS    RESTARTS   AGE
# guaranteed-pod    1/1     Running   0          10s
# burstable-pod     1/1     Running   0          10s
# besteffort-pod    1/1     Running   0          10s
```

### Step 3: 查看每个 Pod 的 QoS 类别

```bash
# Guaranteed Pod
kubectl describe pod guaranteed-pod | grep "QoS Class"
# QoS Class:       Guaranteed

# Burstable Pod
kubectl describe pod burstable-pod | grep "QoS Class"
# QoS Class:       Burstable

# BestEffort Pod
kubectl describe pod besteffort-pod | grep "QoS Class"
# QoS Class:       BestEffort
```

### Step 4: 用 -o yaml 查看更详细信息

```bash
# 查看 Guaranteed Pod 的资源分配
kubectl get pod guaranteed-pod -o jsonpath='{.status.qosClass}'
# Guaranteed

# 对比三个 Pod 的资源配置
kubectl get pods -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass
# NAME              QOS
# guaranteed-pod    Guaranteed
# burstable-pod     Burstable
# besteffort-pod    BestEffort
```

### Step 5: 清理

```bash
kubectl delete -f guaranteed-pod.yaml
kubectl delete -f burstable-pod.yaml
kubectl delete -f besteffort-pod.yaml
```

## Step by Step：观察 OOMKilled

### Step 1: 创建会 OOM 的 Pod

```bash
kubectl apply -f oom-demo.yaml
```

这个 Pod 的内存限制是 50Mi，但会尝试分配 100Mi 的内存。

### Step 2: 观察 OOM 过程

```bash
kubectl get pods -w
# oom-demo   0/1     ContainerCreating   0          0s
# oom-demo   1/1     Running             0          3s
# oom-demo   0/1     OOMKilled           0          5s
# oom-demo   1/1     Running             1          6s     ← 重启了
# oom-demo   0/1     OOMKilled           1          8s     ← 又 OOM
```

> 默认 `restartPolicy: Always`，所以容器 OOM 后会被重启，然后再次 OOM，形成循环。

### Step 3: 查看 OOM 详情

```bash
kubectl describe pod oom-demo | grep -A10 "Last State"
# Last State:     Terminated
#   Reason:       OOMKilled
#   Exit Code:    137

# 查看 Events
kubectl describe pod oom-demo | grep -A3 "Warning"
```

### Step 4: 清理

```bash
kubectl delete -f oom-demo.yaml
```

## 生产环境的资源设置建议

| 建议 | 原因 |
|------|------|
| **总是设置 requests 和 limits** | 防止资源饥饿，帮助调度器正确决策 |
| **关键服务设 Guaranteed** | 确保资源不会被其他 Pod 抢占 |
| **CPU limits 可以适当宽松** | CPU 是可压缩的，超限不会被杀 |
| **Memory limits 要精确** | 内存超限直接 OOMKilled |
| **用 HPA 前必须设 requests** | Horizontal Pod Autoscaler 根据 CPU/内存使用率（实际/requests）来扩缩容 |
| **在 Namespace 级别设 LimitRange** | 防止忘记设资源限制的 Pod 进入集群 |
| **用 ResourceQuota 限制命名空间总资源** | 防止一个团队/项目占用过多资源 |

> **LimitRange** 可以为 Namespace 设置默认的 requests 和 limits。如果 Pod 没有设置资源，K8s 会自动应用 LimitRange 中的默认值。这是防止"裸奔 Pod"的最后一道防线。

## 关键概念总结

| 概念 | 要点 |
|------|------|
| requests | 调度保证，决定 Pod 被分配到哪个节点 |
| limits | 运行上限，CPU 超了限速，内存超了 OOM |
| CPU | 可压缩资源，单位是 cores/millicores |
| Memory | 不可压缩资源，单位是 Mi/Gi |
| Guaranteed | requests == limits，最高优先级 |
| Burstable | 有 requests/limits 但不相等，中等优先级 |
| BestEffort | 没设资源限制，最低优先级，最先被驱逐 |
| OOMKilled | 内存超限被杀，Exit Code 137 |

## 思考题

1. 一个 Pod 只设了 `limits` 没设 `requests`，K8s 会怎么处理？（提示：查看 K8s 文档中关于 requests 的默认行为）
2. 如果一个节点的 CPU 总共 4 核，上面已经调度了 requests 总和为 3.5 核的 Pod，还能调度一个 requests 为 1 核的 Pod 吗？为什么？
3. 为什么说 CPU 是"可压缩资源"而内存不是？Linux 内核是如何实现 CPU throttling 的？
4. 在一个多租户 K8s 集群中，你会如何用 ResourceQuota 和 LimitRange 来防止"吵闹的邻居"问题？

---

[回到目录](../../)
