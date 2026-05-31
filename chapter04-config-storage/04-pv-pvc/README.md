# 04 - PV 与 PVC：持久化存储

## 问题：Pod 不应该关心存储细节

前面三节讲了 ConfigMap、Secret 和 emptyDir。它们有一个共同特点：**生命周期和 Pod 绑定**。

但在真实场景中，数据库的数据、用户上传的文件、应用的日志——这些数据必须比 Pod 活得更久。你需要：

1. **数据在 Pod 删除后依然存在**
2. **Pod 不需要知道底层用什么存储**（NFS？云盘？本地磁盘？）
3. **开发者和存储管理员各司其职**

这就是 PV 和 PVC 存在的原因。

## 两个角色的分离

想象一个公司里的分工：

- **存储管理员** — 购买存储设备、创建存储池、划分空间 → 创建 **PV（PersistentVolume）**
- **应用开发者** — "我需要 1GB 空间" → 创建 **PVC（PersistentVolumeClaim）**
- **Kubernetes** — 自动把 PVC 和合适的 PV 匹配起来 → **绑定（Binding）**

```
存储管理员:  "我有一块 100GB 的 NFS 存储" → 创建 PV
                                        ↓
应用开发者:  "我需要 1GB"               → 创建 PVC
                                        ↓
Kubernetes: "匹配成功！"                → 绑定 PV ↔ PVC
                                        ↓
应用 Pod:    通过 PVC 使用存储           → 不关心底层细节
```

### PV vs PVC

| 特性 | PV（PersistentVolume） | PVC（PersistentVolumeClaim） |
|------|----------------------|---------------------------|
| 作用 | 集群中的存储资源 | 对存储的请求 |
| 作用域 | 集群级别（无 namespace） | 命名空间级别 |
| 创建者 | 管理员或 StorageClass 自动 | 开发者 |
| 生命周期 | 独立于 Pod | 独立于 Pod |
| 类比 | 服务器上的磁盘 | "给我一块磁盘"的工单 |

## 绑定过程

PVC 找到匹配 PV 的规则：

1. **存储容量** — PVC 的请求值 ≤ PV 的容量
2. **访问模式** — PVC 要求的模式必须是 PV 支持的模式子集
3. **StorageClass** — 两者的 storageClassName 必须一致
4. **选择器（Selector）** — PVC 可以用 label selector 进一步筛选

```
PVC: "我要 512Mi，ReadWriteOnce，storageClassName=local-storage"
         ↓
K8s 在所有可用的 PV 中寻找匹配的...
         ↓
PV: "我有 1Gi，ReadWriteOnce，storageClassName=local-storage"
         ↓
匹配！绑定成功。
```

> PVC 请求 512Mi 但绑定了 1Gi 的 PV——这是正常的。PVC 的 `resources.requests` 是最低要求，不是精确值。一旦绑定，PVC 就独占整个 PV。

## 访问模式（Access Modes）

| 模式 | 缩写 | 说明 |
|------|------|------|
| `ReadWriteOnce` | RWO | 单节点读写（最常用） |
| `ReadOnlyMany` | ROX | 多节点只读 |
| `ReadWriteMany` | RWX | 多节点读写 |
| `ReadWriteOncePod` | RWOP | 单 Pod 读写（1.27+ GA） |

注意：访问模式是**底层存储的能力声明**，不是强制约束。比如你声明了一个 NFS 存储为 RWO，但实际上 NFS 支持 RWX。你需要如实声明存储的实际能力。

> 不是所有存储类型都支持所有模式。比如 AWS EBS 只支持 RWO，EFS 支持 RWX。在选择存储方案时要考虑这一点。

## 回收策略（Reclaim Policy）

当 PVC 被删除后，PV 何去何从？

| 策略 | 行为 | 适用场景 |
|------|------|---------|
| `Retain` | 保留 PV 和数据，需要管理员手动清理 | 手动管理，数据安全 |
| `Delete` | 删除 PV 和底层存储资源 | 云存储自动回收 |
| `Recycle` | 执行 `rm -rf /*` 后重新可用 | **已废弃**，不推荐 |

> 生产环境建议用 `Retain`，除非你的存储后端支持自动清理（如 AWS EBS 的 Delete 会自动删除云盘）。

## 动手实践

### Step 1: 在 worker 节点上创建存储目录

local PV 需要节点上实际存在指定路径。先在 kind 的 worker 容器中创建：

```bash
# 查看 worker 节点名称
kubectl get nodes
# 记下 worker 节点的名字，通常类似 k8s-learning-worker

# 在 kind worker 容器中创建目录
# kind 的节点实际上是 Docker 容器
docker exec k8s-learning-worker mkdir -p /tmp/k8s-pv-data

# 确认目录已创建
docker exec k8s-learning-worker ls -la /tmp/k8s-pv-data
```

> 如果你用的是其他 K8s 发行版，需要在对应节点上手动创建 `/tmp/k8s-pv-data` 目录。

同时，确认你的 `local-pv.yaml` 中的 `nodeAffinity` 配置了正确的节点名：

```bash
kubectl get nodes --show-labels | grep hostname
# k8s-learning-worker   kubernetes.io/hostname=k8s-learning-worker
```

如果节点名不同，修改 `local-pv.yaml` 中的 `values` 部分。

### Step 2: 创建 PV

```bash
kubectl apply -f local-pv.yaml

# 查看 PV
kubectl get pv
# NAME       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS     AGE
# local-pv   1Gi        RWO            Retain           Available           local-storage    3s

# 状态是 Available，等待 PVC 来绑定
```

`STATUS` 字段的含义：

| 状态 | 说明 |
|------|------|
| `Available` | 可用，等待绑定 |
| `Bound` | 已被 PVC 绑定 |
| `Released` | PVC 已删除，但回收策略是 Retain，PV 数据还在 |
| `Failed` | 自动回收失败 |

### Step 3: 创建 PVC

```bash
kubectl apply -f app-pvc.yaml

# 查看 PVC
kubectl get pvc
# NAME      STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS     AGE
# app-pvc   Bound    local-pv   1Gi        RWO            local-storage    3s

# 再看 PV——状态变成了 Bound
kubectl get pv
# NAME       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM            STORAGECLASS
# local-pv   1Gi        RWO            Retain           Bound    default/app-pvc  local-storage
```

PVC 请求了 512Mi，但绑定了 1Gi 的 PV。这是因为 Kubernetes 找到了满足条件的最小匹配。

### Step 4: 创建使用 PVC 的 Pod

```bash
kubectl apply -f pod-with-pvc.yaml

# 等待 Pod 就绪
kubectl wait --for=condition=Ready pod/app-with-pvc --timeout=30s

# 验证数据已写入
kubectl exec app-with-pvc -- cat /data/index.html
# Hello from PV demo!
# Written at: Mon Jun 1 12:34:56 UTC 2026
```

### Step 5: 删除 Pod，验证数据持久化

```bash
# 记录写入时间
kubectl exec app-with-pvc -- cat /data/index.html

# 删除 Pod
kubectl delete pod app-with-pvc

# PVC 还在！
kubectl get pvc
# NAME      STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS     AGE
# app-pvc   Bound    local-pv   1Gi        RWO            local-storage    2m

# 创建一个新的 Pod，挂载同一个 PVC
# 先修改 pod-with-pvc.yaml 中的写入命令，改为只读取
# 或者用这个命令验证：
kubectl run verify-pvc --image=busybox:1.36 --rm -it --restart=Never -- \
  cat /data/index.html
# 报错？因为没挂载 PVC

# 正确的方式：重新用 yaml 创建
kubectl apply -f pod-with-pvc.yaml
kubectl wait --for=condition=Ready pod/app-with-pvc --timeout=30s

# 查看数据——之前写入的内容还在！
kubectl exec app-with-pvc -- cat /data/index.html
# Hello from PV demo!
# Written at: Mon Jun 1 12:34:56 UTC 2026  （时间戳和之前一样）
```

> 这就是持久化存储的核心价值：**Pod 是临时的，数据是持久的。**

### Step 6: 理解 Released 状态

```bash
# 删除 Pod
kubectl delete pod app-with-pvc

# 删除 PVC
kubectl delete pvc app-pvc

# 查看 PV 状态
kubectl get pv local-pv
# STATUS 变成了 Released
# 因为回收策略是 Retain，PV 和数据还在，但不能被新的 PVC 直接绑定

# 需要管理员手动清理：
# 1. 清理 PV 中的数据（在节点上 rm -rf /tmp/k8s-pv-data/*）
# 2. 删除旧的 PV
# 3. 重新创建 PV

kubectl delete pv local-pv
docker exec k8s-learning-worker rm -rf /tmp/k8s-pv-data/*
```

> `Retain` 策略保护了你的数据——即使 PVC 被删除，数据也不会丢失。但代价是需要手动清理。

## 清理

```bash
kubectl delete pod app-with-pvc --ignore-not-found=true
kubectl delete pvc app-pvc --ignore-not-found=true
kubectl delete pv local-pv --ignore-not-found=true
```

## PV/PVC 的局限

手动管理 PV 有几个明显问题：

1. **管理员需要预先创建 PV** — 如果用户需要 100 个存储，管理员就要创建 100 个 PV
2. **容量浪费** — PVC 请求 512Mi 绑定了 1Gi 的 PV，浪费了 512Mi
3. **响应慢** — 用户提需求 → 管理员创建 PV → 用户创建 PVC，整个流程太慢

这些问题催生了 **StorageClass** 和 **动态供给**——下一节会讲。

## 思考题

1. 如果 PVC 请求的 accessMode 是 `ReadWriteMany`，但集群中没有支持 RWX 的 PV，会发生什么？
2. 两个不同的 PVC 能否绑定同一个 PV？为什么？
3. `Retain` 和 `Delete` 回收策略各适合什么场景？如果你不小心删除了一个 PVC，两种策略下数据的命运有什么不同？
4. 为什么 local 类型的 PV 必须设置 `nodeAffinity`？如果不设置会怎样？

---

下一个 → [05 - StorageClass 与动态供给](../05-storageclass/)
