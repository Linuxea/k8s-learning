# 05 - StorageClass：动态供给存储

## 上一节的问题

上一节我们手动创建了 PV，然后 PVC 来绑定它。这种方式叫**静态供给（Static Provisioning）**。

它有几个严重问题：

1. **管理员瓶颈** — 每个存储请求都需要管理员手动创建 PV
2. **容量预估困难** — 怎么知道用户需要多少存储？创建太多浪费，太少不够
3. **响应慢** — 从需求提出到可用，中间有人工等待

就像一个公司里，员工每次要用办公用品都要填工单等采购——效率太低了。

## StorageClass 的解决方案

StorageClass 引入了**动态供给（Dynamic Provisioning）**：

```
静态供给:
  管理员创建 PV → 用户创建 PVC → PVC 绑定已有 PV

动态供给:
  用户创建 PVC（指定 StorageClass） → provisioner 自动创建 PV → 自动绑定
```

就像自动售货机：你选择商品类型（StorageClass），投入需求（PVC），机器自动出货（创建 PV）。

### StorageClass 定义了什么

一个 StorageClass 包含：

| 字段 | 作用 | 示例 |
|------|------|------|
| `provisioner` | 谁来创建存储 | `rancher.io/local-path`、`kubernetes.io/aws-ebs` |
| `parameters` | 传给 provisioner 的参数 | 磁盘类型、IOPS、存储路径 |
| `reclaimPolicy` | PVC 删除后如何处理 | `Delete`、`Retain` |
| `volumeBindingMode` | 何时绑定 | `Immediate`、`WaitForFirstConsumer` |
| `allowVolumeExpansion` | 是否允许扩容 | `true`、`false` |

## kind 的默认 StorageClass

kind 集群自带一个默认 StorageClass：

```bash
kubectl get storageclass
# NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
# standard (default)   rancher.io/local-path   Delete          Immediate
```

带 `(default)` 标记意味着：**创建 PVC 时不指定 storageClassName，就会使用这个默认 StorageClass**。

默认标记通过 annotation 实现：

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"   # 这行让它成为默认
```

> 一个集群中应该只有一个默认 StorageClass。如果有多个被标记为默认，PVC 创建会失败。

## volumeBindingMode 的选择

| 模式 | 行为 | 适用场景 |
|------|------|---------|
| `Immediate` | PVC 创建后立即 provision 和绑定 | 网络存储（NFS、云盘） |
| `WaitForFirstConsumer` | 直到 Pod 使用 PVC 时才 provision | 本地存储、需要拓扑感知的存储 |

`WaitForFirstConsumer` 为什么重要？

假设你有一个多节点集群，每个节点都有本地存储。如果用 `Immediate`：
1. PVC 创建 → provisioner 随机选一个节点创建存储
2. Pod 被调度到另一个节点 → 找不到存储！

用 `WaitForFirstConsumer`：
1. PVC 创建 → 等待...
2. Pod 被调度到节点 A
3. provisioner 在节点 A 上创建存储 → PVC 绑定
4. Pod 在节点 A 上启动，完美！

## 动手实践

### Step 1: 查看现有 StorageClass

```bash
# 查看集群中的 StorageClass
kubectl get storageclass

# 查看默认 StorageClass 详情
kubectl describe storageclass standard
```

### Step 2: 创建自定义 StorageClass

```bash
kubectl apply -f fast-storageclass.yaml

# 验证
kubectl get storageclass
# NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
# fast-local           rancher.io/local-path   Delete          WaitForFirstConsumer
# standard (default)   rancher.io/local-path   Delete          Immediate
```

注意两个区别：
- `fast-local` 使用 `WaitForFirstConsumer` — 延迟绑定
- `standard` 使用 `Immediate` — 立即绑定

### Step 3: 创建 PVC（此时没有 PV）

```bash
# 先确认没有可用的 PV
kubectl get pv
# No resources found.

# 创建 PVC
kubectl apply -f dynamic-pvc.yaml

# 查看 PVC 状态
kubectl get pvc dynamic-pvc
# NAME          STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
# dynamic-pvc   Pending                                      fast-local     3s

# 注意！PVC 处于 Pending 状态
# 因为 volumeBindingMode 是 WaitForFirstConsumer
# 需要有 Pod 使用这个 PVC 才会触发 provisioning
```

> 这就是 `WaitForFirstConsumer` 的效果：PVC 已创建，但还没有 PV 与之绑定。它在等待一个 Pod。

### Step 4: 创建 Pod，观察自动 Provisioning

```bash
kubectl apply -f pod-dynamic-pvc.yaml

# 快速观察 PVC 状态变化
kubectl get pvc dynamic-pvc -w
# 你会看到状态从 Pending → Bound
# 同时一个新的 PV 被自动创建了

# Ctrl+C 退出 watch

# 查看自动创建的 PV
kubectl get pv
# NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM
# pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   256Mi      RWO            Delete           Bound    default/dynamic-pvc

# 查看 PVC 详情
kubectl get pvc dynamic-pvc
# NAME          STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
# dynamic-pvc   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   256Mi      RWO            fast-local
```

整个过程：

```
1. PVC 创建 → Pending（等待消费者）
2. Pod 创建，引用 PVC
3. 调度器将 Pod 调度到某节点
4. local-path-provisioner 在该节点创建存储
5. PV 被自动创建
6. PVC 绑定到新 PV
7. Pod 启动，挂载存储
```

### Step 5: 写入数据并验证

```bash
# 等待 Pod 就绪
kubectl wait --for=condition=Ready pod/app-dynamic-pvc --timeout=60s

# 写入数据
kubectl exec app-dynamic-pvc -- sh -c \
  'echo "<h1>Data on Dynamic PVC</h1>" > /usr/share/nginx/html/index.html'

# 验证
kubectl exec app-dynamic-pvc -- curl -s http://localhost
# <h1>Data on Dynamic PVC</h1>
```

### Step 6: 验证数据持久化

```bash
# 删除 Pod
kubectl delete pod app-dynamic-pvc

# PVC 和 PV 都还在
kubectl get pvc dynamic-pvc
# STATUS: Bound

# 重新创建 Pod
kubectl apply -f pod-dynamic-pvc.yaml
kubectl wait --for=condition=Ready pod/app-dynamic-pvc --timeout=60s

# 数据还在！
kubectl exec app-dynamic-pvc -- curl -s http://localhost
# <h1>Data on Dynamic PVC</h1>
```

### Step 7: 验证 Delete 回收策略

```bash
# 记录 PV 名字
PV_NAME=$(kubectl get pvc dynamic-pvc -o jsonpath='{.spec.volumeName}')
echo "PV name: $PV_NAME"

# 删除 Pod
kubectl delete pod app-dynamic-pvc

# 删除 PVC
kubectl delete pvc dynamic-pvc

# 观察 PV — 因为回收策略是 Delete，PV 也被自动删除了
kubectl get pv $PV_NAME
# Error from server (NotFound): persistentvolumes "pvc-xxx" not found

# 底层存储也被清理了
```

> 和上一节的 `Retain` 策略不同，`Delete` 策略在 PVC 删除时自动清理 PV 和底层存储。适合临时数据和开发/测试环境。

### Step 8: 测试默认 StorageClass（不指定 storageClassName）

```bash
# 创建一个不指定 storageClassName 的 PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: default-sc-pvc
spec:
  resources:
    requests:
      storage: 128Mi
  accessModes:
    - ReadWriteOnce
  # 没有指定 storageClassName
EOF

# 查看详情——它会自动使用默认 StorageClass
kubectl get pvc default-sc-pvc
# STATUS 应该是 Bound（因为 standard 的 volumeBindingMode 是 Immediate）

# 清理
kubectl delete pvc default-sc-pvc
```

## StorageClass 最佳实践

| 实践 | 原因 |
|------|------|
| 生产数据用 `Retain` | 防止误删 PVC 导致数据丢失 |
| 开发环境用 `Delete` | 自动回收，不浪费资源 |
| 本地存储用 `WaitForFirstConsumer` | 确保存储和 Pod 在同一节点 |
| 网络存储用 `Immediate` | 存储不绑定节点，无需延迟 |
| 只设一个默认 StorageClass | 避免歧义 |
| 开启 `allowVolumeExpansion: true` | 方便日后扩容 |

## 对比：静态供给 vs 动态供给

| 维度 | 静态供给 | 动态供给 |
|------|---------|---------|
| PV 创建 | 管理员手动 | provisioner 自动 |
| 适用场景 | 固定存储、预分配 | 按需分配、多租户 |
| 运维复杂度 | 高（需要管理 PV 生命周期） | 低（自动化） |
| 灵活性 | 低 | 高 |
| 存储利用率 | 可能有浪费 | 按需分配 |

## 章节总结

本章我们学习了 Kubernetes 配置与存储的五大核心概念：

```
ConfigMap    → 非敏感配置（环境变量、配置文件）
Secret       → 敏感数据（密码、证书）
emptyDir     → Pod 内容器间临时共享
PV/PVC       → 持久化存储的手动管理
StorageClass → 持久化存储的自动管理
```

选择决策树：

```
需要存储数据？
├── 配置文件 → ConfigMap
├── 敏感信息 → Secret
├── 临时数据
│   └── 容器间共享？ → emptyDir
└── 持久化数据
    ├── 静态供给 → PV + PVC
    └── 动态供给 → StorageClass + PVC
```

## 思考题

1. 如果一个 PVC 的 `storageClassName` 设为空字符串（`""`），它的行为和不指定 `storageClassName` 有什么不同？
2. 为什么生产环境通常不建议使用默认 StorageClass？如何确保应用使用正确的 StorageClass？
3. `allowVolumeExpansion: true` 允许 PVC 扩容，但能缩容吗？为什么？
4. 如果 provisioner（如 local-path-provisioner）崩溃了，创建 PVC 后会发生什么？恢复后 PVC 会自动绑定吗？

---

[返回章节目录](../)
