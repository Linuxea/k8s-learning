# 04 - DaemonSet

## DaemonSet 是什么

DaemonSet 的设计目标很明确：**确保每个节点（或特定节点）上都运行一个 Pod 副本**。

它的行为是：

- 集群新增一个节点 → DaemonSet 自动在上面创建一个 Pod
- 节点从集群中移除 → DaemonSet 的 Pod 也随之被回收
- 不需要指定 `replicas` — 副本数 = 匹配的节点数

```
3 节点集群中的 DaemonSet：

Node: control-plane   →  Pod: log-collector-xxxx
Node: worker-1        →  Pod: log-collector-yyyy
Node: worker-2        →  Pod: log-collector-zzzz
```

## 典型使用场景

DaemonSet 适用于**节点级别的基础设施任务**：

| 场景 | 具体工具 | 为什么用 DaemonSet |
|------|---------|-------------------|
| **日志采集** | Fluentd, Filebeat, Fluent Bit | 每个节点都要采集本节点上的容器日志 |
| **监控代理** | Node Exporter, cAdvisor, Datadog Agent | 每个节点都要暴露本节点的 CPU/内存/磁盘指标 |
| **网络插件** | Calico, Flannel, Cilium | 每个节点都要配置网络规则和路由 |
| **存储守护进程** | glusterd, ceph-osd | 每个节点都要挂载/管理分布式存储 |
| **安全代理** | Falco, Tetragon | 每个节点都要监控内核事件 |

> 这些任务的共同点：它们关注的是**节点**，而不是应用。你需要的是"每个节点一个"，而不是"N 个副本"。

## 和 Deployment/StatefulSet 的对比

| 特性 | Deployment | StatefulSet | DaemonSet |
|------|-----------|-------------|-----------|
| Pod 数量 | 由 `replicas` 决定 | 由 `replicas` 决定 | 由节点数决定 |
| 调度方式 | 随机分配到节点 | 随机分配到节点 | 每个节点恰好一个 |
| Pod 命名 | 随机 hash | 有序编号（0,1,2...） | 随机 hash |
| 适用场景 | 无状态应用 | 有状态应用 | 节点级守护进程 |

## 节点选择：nodeSelector 和 tolerations

默认情况下，DaemonSet 会在**所有节点**上创建 Pod。但你可以通过以下方式控制：

### nodeSelector — 简单的标签匹配

```yaml
spec:
  template:
    spec:
      nodeSelector:
        node-role: worker    # 只在带这个标签的节点上运行
```

你需要先给节点打标签：

```bash
kubectl label nodes <node-name> node-role=worker
```

### tolerations — 容忍度

有些节点有**污点（Taints）**，比如 control-plane 节点默认有 `node-role.kubernetes.io/control-plane:NoSchedule`，普通 Pod 不会被调度上去。

DaemonSet 的 Pod 如果需要在 control-plane 上运行，就需要加 toleration：

```yaml
spec:
  template:
    spec:
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          effect: NoSchedule
          # 不指定 operator 等价于 operator: Equal + value 为空
          # 意思是：能容忍这个 key 的 NoSchedule 效果
```

> Kubernetes 的 Taint 和 Toleration 机制：Taint 是"排斥"，Toleration 是"容忍"。节点有 Taint，Pod 有对应的 Toleration 才能被调度上去。

### nodeAffinity — 更灵活的节点选择（推荐）

```yaml
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node-role
                    operator: In
                    values:
                      - worker
```

`nodeAffinity` 比 `nodeSelector` 更强大，支持 `In`、`NotIn`、`Exists` 等操作符，还支持"软"亲和性（preferred）。

## 更新策略

| 策略 | 行为 |
|------|------|
| `RollingUpdate`（默认） | 逐个节点更新：先在一个节点上删旧 Pod 建 new Pod，完成后再处理下一个节点 |
| `OnDelete` | 不自动更新。只有当你手动删除 Pod 后，DaemonSet 才会用新模板重建 |

```yaml
spec:
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1    # 最多同时有 1 个节点的 Pod 在更新中
```

### OnDelete 的使用场景

当你需要精确控制更新时机时（比如只能在凌晨维护窗口更新），用 `OnDelete`：

1. 修改 DaemonSet 的 Pod 模板（比如换镜像）
2. 现有 Pod **不会**自动更新
3. 你选择合适的时间，逐个 `kubectl delete pod` 来触发更新
4. DaemonSet 用新模板重建被删除的 Pod

## 关键字段详解

| 字段 | 含义 |
|------|------|
| `spec.selector` | 标签选择器，和其他 Workload 一样 |
| `spec.template` | Pod 模板 |
| `spec.updateStrategy` | 更新策略：`RollingUpdate` 或 `OnDelete` |
| `spec.updateStrategy.rollingUpdate.maxUnavailable` | 滚动更新时最多允许多少个 Pod 不可用（数字或百分比） |
| `spec.minReadySeconds` | Pod 就绪后等待多久才被认为可用 |
| `spec.template.spec.nodeSelector` | 简单节点选择 |
| `spec.template.spec.tolerations` | 容忍度，允许调度到有 Taint 的节点 |

> DaemonSet **没有 `replicas` 字段**。副本数完全由节点数量决定。

## Step by Step 操作

### Step 1: 创建 DaemonSet

```bash
kubectl apply -f log-collector-daemonset.yaml

# 查看 DaemonSet
kubectl get daemonset
# NAME            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
# log-collector   3         3         3       3            3           <none>          10s

# DESIRED = 3，因为有 3 个节点（1 control-plane + 2 worker）
```

### Step 2: 观察 Pod 分布

```bash
# 查看 Pod 运行在哪些节点上
kubectl get pods -l app=log-collector -o wide
# NAME                  READY   STATUS    RESTARTS   AGE   IP           NODE
# log-collector-abc12   1/1     Running   0          30s   10.244.0.x   k8s-learning-control-plane
# log-collector-def34   1/1     Running   0          30s   10.244.1.x   k8s-learning-worker
# log-collector-ghi56   1/1     Running   0          30s   10.244.2.x   k8s-learning-worker2

# 每个节点恰好一个 Pod！
```

### Step 3: 查看 Pod 日志

```bash
# 查看某个 Pod 的输出，确认它在"采集日志"
kubectl logs -l app=log-collector --tail=5

# 你会看到类似：
# [2024-01-15 10:30:00] Collecting logs from /var/log on node k8s-learning-worker
# [2024-01-15 10:30:05] Collected 42 log entries
```

### Step 4: 删除一个 Pod，观察自愈

```bash
# 删除某个节点上的 Pod
kubectl delete pod -l app=log-collector --field-selector spec.nodeName=k8s-learning-worker

# 立刻查看
kubectl get pods -l app=log-collector -o wide
# 被删除的 Pod 已重建，仍然运行在同一个节点上
```

> DaemonSet 的"自愈"和 Deployment 类似，但它保证的是**每个节点一个 Pod**，而不是固定的副本数。

### Step 5: 模拟新增节点

```bash
# 查看当前节点
kubectl get nodes

# 在 kind 集群中，可以通过修改集群配置来添加节点
# 这里就不实际操作了，但要知道：
# 新节点加入集群后，DaemonSet 控制器会自动检测到，
# 并在新节点上创建一个 Pod
```

### Step 6: 测试 nodeSelector

```bash
# 给一个 worker 节点打标签
kubectl label nodes k8s-learning-worker log-collector=enabled

# 修改 yaml 文件，加上 nodeSelector（见下面的示例）
# spec.template.spec.nodeSelector:
#   log-collector: enabled

# 重新 apply
# kubectl apply -f log-collector-daemonset.yaml

# 观察 Pod 只运行在有标签的节点上
# kubectl get pods -o wide
```

### Step 7: 更新 DaemonSet

```bash
# 修改镜像版本触发滚动更新
kubectl set image daemonset/log-collector log-collector=busybox:1.37

# 查看滚动更新状态
kubectl rollout status daemonset/log-collector

# 查看更新事件
kubectl describe daemonset log-collector | tail -20
```

### Step 8: 清理

```bash
kubectl delete -f log-collector-daemonset.yaml
```

## 查看节点标签和污点

```bash
# 查看所有标签
kubectl get nodes --show-labels

# 查看某个节点的污点
kubectl describe node <node-name> | grep Taints
# control-plane 通常有：
#   Taints: node-role.kubernetes.io/control-plane:NoSchedule

# 给节点打标签
kubectl label nodes <node-name> <key>=<value>

# 去除标签
kubectl label nodes <node-name> <key>-

# 给节点加污点
kubectl taint nodes <node-name> <key>=<value>:NoSchedule

# 去除污点
kubectl taint nodes <node-name> <key>:NoSchedule-
```

## 常见困惑

### 困惑 1：节点是什么？DaemonSet 按节点部署，但 kind 集群里节点是 Docker 容器，有意义吗？

在 kind 集群中，每个"节点"是一个 Docker 容器，确实共享宿主机内核，但**各有独立的文件系统和 network namespace**。DaemonSet 的 hostPath 挂载的是**该容器**内的目录，不会跨容器重复采集。

真实生产环境中节点是独立物理机/云主机，DaemonSet 的"每节点一个 Pod"语义完全相同——只是规模从 3 个容器变成 100 台机器。

### 困惑 2：Toleration 和 Taint 的关系

- **Taint（污点）**：节点说"我有洁癖，普通 Pod 别来"（如 control-plane 默认有 `node-role.kubernetes.io/control-plane:NoSchedule`）
- **Toleration（容忍）**：Pod 说"没事，我不介意"（DaemonSet 的 Pod 加对应 toleration 才能跑在 control-plane 上）

没有 toleration 的 DaemonSet 会跳过有 taint 的节点，导致 control-plane 上没有 Pod。这在日志采集、监控代理等场景下不可接受——你需要覆盖所有节点。



1. 如果一个节点被临时隔离（`kubectl cordon`），DaemonSet 会怎么处理这个节点上的 Pod？新版本的 DaemonSet 会更新这个节点上的 Pod 吗？
2. 为什么网络插件（如 Calico、Flannel）通常用 DaemonSet 部署？如果用 Deployment 部署会有什么问题？
3. `OnDelete` 更新策略在什么场景下比 `RollingUpdate` 更合适？
4. 如果你的集群有 100 个节点，DaemonSet 的 `maxUnavailable` 设为 `50%`，更新时会怎样？这样安全吗？

---

下一个 → [05 - Job & CronJob](../05-job-cronjob/)
