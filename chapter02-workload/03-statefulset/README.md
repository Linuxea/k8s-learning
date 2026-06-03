# 03 - StatefulSet

## 为什么需要 StatefulSet

前两节学的 Deployment 和 ReplicaSet 都是为**无状态应用**设计的。无状态应用的特点：

- 任何一个 Pod 都和其他 Pod 一模一样
- 不在乎自己的名字叫什么、IP 是多少
- 不在乎自己被调度到哪个节点
- 随时可以被另一个 Pod 替换

但现实世界中，很多应用是**有状态的**：

- **MySQL 主从** — master 和 slave 的角色不同，数据也不同
- **ZooKeeper 集群** — 每个节点需要有唯一 ID，需要知道其他节点是谁
- **Elasticsearch** — 每个节点存储不同的分片（shard），数据不能丢
- **Kafka** — 每个 broker 有自己的分区（partition），需要持久化日志

这些应用有三个共同需求，而 Deployment 满足不了：

| 需求 | Deployment | StatefulSet |
|------|-----------|-------------|
| **稳定的网络标识** | Pod 名字随机（`app-abc123-xyz`），每次重建都变 | Pod 名字有序（`app-0`、`app-1`），重建后名字不变 |
| **稳定的持久存储** | Pod 重建后，之前挂载的 PVC 可能丢失 | 每个 Pod 绑定专属 PVC，重建后自动重新挂载 |
| **有序的部署和终止** | 所有 Pod 同时创建/删除 | 按顺序：0 → 1 → 2 创建，2 → 1 → 0 删除 |

## StatefulSet vs Deployment 核心区别

### 1. 稳定的网络标识

```
# Deployment 的 Pod 名字（每次重建都变）
nginx-deployment-7fb96c846b-abc12  ← 删除后重建变成 -def34

# StatefulSet 的 Pod 名字（固定不变）
nginx-statefulset-0
nginx-statefulset-1
nginx-statefulset-2
# 删除 nginx-statefulset-1 后，重建的 Pod 仍然叫 nginx-statefulset-1
```

但稳定的名字还不够，还需要稳定的 DNS。这就是 **Headless Service** 的作用：

```
# 普通 Service（ClusterIP）
nginx-service.default.svc.cluster.local → 随机转发到某个 Pod

# Headless Service（ClusterIP: None）
nginx-statefulset-0.nginx-headless.default.svc.cluster.local → 永远指向 Pod-0
nginx-statefulset-1.nginx-headless.default.svc.cluster.local → 永远指向 Pod-1
```

> 其他应用可以通过 `nginx-statefulset-0.nginx-headless` 来**精确地**连接到特定的 Pod。这对数据库主从、分布式系统中的节点发现至关重要。

### 2. 稳定的持久存储

StatefulSet 使用 `volumeClaimTemplates` 为每个 Pod 自动创建专属的 PVC：

```
nginx-statefulset-0 → PVC: data-nginx-statefulset-0
nginx-statefulset-1 → PVC: data-nginx-statefulset-1
nginx-statefulset-2 → PVC: data-nginx-statefulset-2
```

当 Pod-1 被删除重建后，它会**重新挂载同一个 PVC**（`data-nginx-statefulset-1`），之前写入的数据还在。

> Deployment 的 PVC 是共享的（多个 Pod 挂同一个 PVC），或者每次重建可能分配不同的 PVC。对数据库来说这是灾难性的。

### 3. 有序操作

创建顺序：`Pod-0 → Pod-1 → Pod-2`（前一个 Ready 后才创建下一个）
删除顺序：`Pod-2 → Pod-1 → Pod-0`（反序）

这种顺序性保证了：
- 集群中的"种子节点"（通常是 Pod-0）先启动
- 下线时最后关闭种子节点
- 避免脑裂（split-brain）

## Headless Service 详解

Headless Service 和普通 Service 的区别只有一个字段：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-headless
spec:
  clusterIP: None    # ← 这就是"无头"的含义：不分配虚拟 IP
  selector:
    app: nginx-sts
  ports:
    - port: 80
```

普通 Service 的工作方式：
```
客户端 → Service ClusterIP → 随机选一个 Pod → 转发请求
```

Headless Service 的工作方式：
```
客户端 DNS 查询 nginx-statefulset-0.nginx-headless → 直接返回 Pod-0 的 IP
客户端 → 直接连 Pod-0 的 IP
```

> Headless Service **不做负载均衡**，它只负责 DNS 解析。每个 Pod 都有自己唯一的 DNS 记录。

## 关键字段详解

| 字段 | 含义 | 默认值 |
|------|------|--------|
| `spec.serviceName` | 关联的 Headless Service 名称。用于为每个 Pod 创建 DNS 记录 | 必填 |
| `spec.replicas` | 期望的 Pod 数量 | 1 |
| `spec.selector` | 标签选择器 | — |
| `spec.volumeClaimTemplates` | 为每个 Pod 自动创建的 PVC 模板 | — |
| `spec.podManagementPolicy` | Pod 管理策略：`OrderedReady`（顺序）或 `Parallel`（并行） | `OrderedReady` |
| `spec.updateStrategy` | 更新策略：`RollingUpdate` 或 `OnDelete` | `RollingUpdate` |
| `spec.updateStrategy.rollingUpdate.partition` | 分区更新：只有序号 ≥ partition 的 Pod 会被更新 | 0 |

### podManagementPolicy

- **`OrderedReady`**（默认）：严格顺序。Pod-0 Ready 后才创建 Pod-1。安全但慢。
- **`Parallel`**：同时创建所有 Pod。适用于不需要顺序启动的应用（比如只在乎数据持久化的场景）。

### partition（金丝雀更新）

```yaml
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    partition: 2
```

这表示：只更新序号 ≥ 2 的 Pod。Pod-0 和 Pod-1 保持旧版本。

用途：先在一小部分 Pod 上测试新版本（金丝雀发布），确认没问题后再把 `partition` 改为 0，全部更新。

## Step by Step 操作

### Step 1: 创建 StatefulSet + Headless Service

```bash
# 注意：StatefulSet 需要先有 Headless Service
# yaml 文件里已经包含了 Service 定义
kubectl apply -f nginx-statefulset.yaml

# 查看 Service
kubectl get svc
# NAME              TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
# nginx-headless    ClusterIP   None         <none>        80/TCP    10s
#                                              ^^^^
#                                     ClusterIP 是 None，这就是 Headless Service

# 查看 StatefulSet
kubectl get statefulset
# NAME                READY   AGE
# nginx-statefulset   3/3     30s

# 观察 Pod 的命名和创建顺序
kubectl get pods -l app=nginx-sts
# NAME                  READY   STATUS    RESTARTS   AGE
# nginx-statefulset-0   1/1     Running   0          45s
# nginx-statefulset-1   1/1     Running   0          35s
# nginx-statefulset-2   1/1     Running   0          25s
```

注意 AGE 列 — Pod-0 比 Pod-1 早 10 秒创建，Pod-1 比 Pod-2 早 10 秒。这就是有序创建。

### Step 2: 查看 PVC

```bash
kubectl get pvc
# NAME                        STATUS   VOLUME                                     CAPACITY   ACCESS MODES   AGE
# www-nginx-statefulset-0     Bound    pvc-xxx                                    1Gi        RWO            1m
# www-nginx-statefulset-1     Bound    pvc-yyy                                    1Gi        RWO            1m
# www-nginx-statefulset-2     Bound    pvc-zzz                                    1Gi        RWO            1m
```

每个 Pod 都有自己专属的 PVC。PVC 的名字格式：`{volumeClaimTemplates名}-{StatefulSet名}-{序号}`。

### Step 3: 验证稳定的网络标识

```bash
# 启动一个临时 Pod 来测试 DNS 解析
kubectl run dns-test --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup nginx-statefulset-0.nginx-headless.default.svc.cluster.local

# 你会看到返回 Pod-0 的 IP 地址

# 测试 Headless Service 本身的 DNS（返回所有 Pod IP）
kubectl run dns-test --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup nginx-headless.default.svc.cluster.local
# 会返回所有 3 个 Pod 的 IP
```

### Step 4: 验证稳定的持久存储

```bash
# 在 Pod-0 的持久卷里写入数据
kubectl exec nginx-statefulset-0 -- sh -c "echo 'hello from pod-0' > /usr/share/nginx/html/index.html"

# 删除 Pod-0
kubectl delete pod nginx-statefulset-0

# StatefulSet 会自动重建 Pod-0（名字相同！）
kubectl get pods -l app=nginx-sts
# NAME                  READY   STATUS    RESTARTS   AGE
# nginx-statefulset-0   1/1     Running   0          10s   ← 重建了，名字不变
# nginx-statefulset-1   1/1     Running   0          5m
# nginx-statefulset-2   1/1     Running   0          5m

# 验证数据还在
kubectl exec nginx-statefulset-0 -- cat /usr/share/nginx/html/index.html
# hello from pod-0
```

**数据在 Pod 重建后完好无损** — 因为 PVC 没有被删除，新 Pod 重新挂载了同一个 PVC。

### Step 5: 有序删除

```bash
# 缩容到 1
kubectl scale statefulset nginx-statefulset --replicas=1

# 观察删除顺序（-w = watch）
# kubectl get pods -l app=nginx-sts -w
# 你会看到 Pod-2 先被删除，然后 Pod-1，最后只剩 Pod-0
```

### Step 6: 清理

```bash
# StatefulSet 删除后 PVC 不会自动删除（这是设计如此，保护数据）
kubectl delete -f nginx-statefulset.yaml

# 查看残留的 PVC
kubectl get pvc
# PVC 还在！

# 需要手动删除 PVC
kubectl delete pvc -l app=nginx-sts

# 如果 kind 集群使用 local-path-provisioner，还需要手动删除 PV
kubectl get pv
kubectl delete pv <pv-name>
```

> **重要**：StatefulSet 删除后 PVC 不会自动清理。这是有意为之的 — 数据太重要了，不能因为一次误操作就丢了。但也意味着你需要记得手动清理。

## 什么时候用 StatefulSet

| 场景 | 用什么 |
|------|--------|
| Web 服务器、API 服务（无状态） | Deployment |
| 需要稳定网络标识的分布式系统 | StatefulSet |
| 数据库（MySQL、PostgreSQL、MongoDB） | StatefulSet |
| 消息队列（Kafka、RabbitMQ） | StatefulSet |
| 缓存集群（Redis Cluster） | StatefulSet |
| 搜索引擎（Elasticsearch） | StatefulSet |
| 日志采集、监控代理（每个节点一个） | DaemonSet（下一节） |

## 常见困惑

### 困惑 1：有状态 = 不能自动重建？

**误解**：StatefulSet 的 Pod 如果挂了不会自动重建，因为数据重要，不能随便迁移。

**正解**：StatefulSet 的控制器**会自动重建** Pod，这和 Deployment 一样。区别在于**重建之后**发生的事情——Pod 名字不变、同一张 PVC 绑回来、DNS 记录恢复。数据丢不丢不取决于"要不要自动重建"，而取决于**存储类型**：

- 本地磁盘（hostPath）：节点宕机 → Pod 在其他节点重建 → 数据丢失（新节点上找不到老节点的磁盘）
- 网络存储（NFS、Ceph、云盘）：节点宕机 → Pod 在其他节点重建 → PVC 从网络中重新挂载 → **数据完好**

**任何有状态应用在生产环境都应该使用网络存储**，否则节点宕机就意味着数据没了。

### 困惑 2：不要存储就别用 StatefulSet

**误解**：StatefulSet 的主要作用是持久存储，如果我的应用不需要磁盘，用 Deployment + 普通 Service 就够了。

**正解**：StatefulSet 解决的是**身份**问题，存储只是身份的一部分。一个应用可以只要身份不要存储（比如 ZooKeeper、etcd——它们的节点需要互相通过固定 DNS 名发现对方，但数据管理在自己手里）。Headless Service 提供的**稳定网络标识**（`pod-0.svc.ns.svc.cluster.local`）是 StatefulSet 的独立特性，Deployment + 普通 ClusterIP Service 做不到这一点。

### 困惑 3：StatefulSet 删除后 PVC 为什么还在？

这是**设计如此**，不是 bug。StatefulSet 控制器只管理 Pod 生命周期，不管理 PVC——因为数据太重要，不能因为误操作就丢了。你需要手动 `kubectl delete pvc -l app=xxx` 清理。

### 困惑 4：Headless Service 和普通 Service 的区别只在一个字段

`clusterIP: None` — 就这么简单。但效果差距巨大：

- 普通 Service：DNS 返回虚拟 IP → kube-proxy 做负载均衡 → 随机转发
- Headless Service：DNS 直接返回所有后端 Pod IP → 客户端自己选 → 还能用 `pod-name.service-name` 精确连到某个 Pod

## 思考题

1. 如果 StatefulSet 的 Pod-0 所在节点宕机了，会发生什么？Pod-0 会在其他节点重建吗？数据会怎样？
2. 为什么 Headless Service 设置 `clusterIP: None` 而不是分配一个普通 IP？如果用了普通 IP 会怎样？
3. 如果你的应用不需要持久存储，但需要稳定的网络标识（比如每个 Pod 需要注册自己的 DNS 名），用 StatefulSet 合适吗？
4. StatefulSet 的 `partition` 参数设为 2 时，如果缩容到 1 副本再扩回 3，哪些 Pod 会用新版本，哪些会用旧版本？

---

下一个 → [04 - DaemonSet](../04-daemonset/)
