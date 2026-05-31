# 10.5 灾难恢复：当一切崩塌时

## 为什么灾难恢复（DR）在 Kubernetes 中至关重要？

Kubernetes 提高了应用的可用性——自愈、滚动更新、副本集。但这不意味着"不可能出事"：

```
可能出事的场景：
┌──────────────────────────────────────────────────────┐
│                                                      │
│  🔴 集群级故障                                        │
│  ├── etcd 数据损坏（集群状态全部丢失）                  │
│  ├── 所有 control-plane 节点同时宕机                   │
│  └── 云服务商区域故障                                  │
│                                                      │
│  🟡 命名空间/应用级故障                                │
│  ├── 误删命名空间（kubectl delete ns prod --oops）     │
│  ├── 错误的配置推送（错误的环境变量导致所有 Pod CrashLoopBackOff）│
│  └── 有问题的镜像版本（新版本引入严重 bug）              │
│                                                      │
│  🟠 数据层故障                                        │
│  ├── PVC 数据损坏                                     │
│  ├── 数据库误操作（DROP TABLE）                        │
│  └── ConfigMap/Secret 被错误修改                       │
│                                                      │
└──────────────────────────────────────────────────────┘
```

> **灾难恢复不是"会不会发生"的问题，而是"什么时候发生"的问题。**
>
> 区别只在于：有准备的团队能在分钟级恢复，没准备的团队可能要花几小时甚至几天。

## 备份策略总览

| 备份方案 | 备份范围 | 恢复粒度 | 适用场景 |
|----------|----------|----------|----------|
| **etcd 备份** | 整个集群状态 | 整个集群 | 集群级灾难恢复 |
| **Velero** | 指定命名空间/资源 + PV 数据 | 按命名空间/资源 | 细粒度恢复、跨集群迁移 |
| **GitOps 仓库** | 所有声明式配置 | 按应用 | GitOps 已管理的资源 |
| **PV 快照** | 持久卷数据 | 按卷 | 数据库、文件存储 |

### 备份策略的层次

```
┌─────────────────────────────────────────────┐
│            灾难恢复层次                       │
│                                             │
│  Layer 4: etcd 全量备份                      │
│  ├── 最全面的备份（整个集群状态）              │
│  └── 恢复代价高（需要停集群）                 │
│                                             │
│  Layer 3: Velero 命名空间备份                │
│  ├── 选择性备份（按命名空间/标签）            │
│  └── 包含 PV 数据                            │
│                                             │
│  Layer 2: GitOps 清单（ArgoCD/Flux 管理）    │
│  ├── 所有部署配置已在 Git 中                  │
│  └── 恢复 = 重新 apply 清单                  │
│                                             │
│  Layer 1: PV 数据快照                        │
│  ├── 数据库、文件存储等有状态数据             │
│  └── 通常需要应用层配合                       │
└─────────────────────────────────────────────┘
```

## etcd 备份

etcd 是 Kubernetes 的"大脑"——存储了所有集群状态数据（Pod、Service、ConfigMap、Secret 等）。备份 etcd 就是备份整个集群的期望状态。

### etcd 备份原理

```
etcd 集群
    │
    │ etcdctl snapshot save
    ▼
快照文件（包含所有 KV 数据）
    │
    │ 存储到安全位置（S3、NFS、本地磁盘）
    ▼
恢复时：停止 etcd → etcdctl snapshot restore → 启动 etcd
```

### etcd 备份操作

```bash
# 前提：需要 SSH 到 control-plane 节点
# 在 kind 集群中，control-plane 是一个 Docker 容器

# 方式一：通过 kubectl（如果 etcd 以 Pod 运行）
# 查看 etcd Pod
kubectl get pods -n kube-system -l component=etcd

# 执行备份
kubectl exec -n kube-system etcd-kind-control-plane -- \
  etcdctl snapshot save /tmp/etcd-snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# 从 etcd Pod 复制备份文件到本地
kubectl cp kube-system/etcd-kind-control-plane:/tmp/etcd-snapshot.db ./etcd-snapshot.db

# 验证备份文件
kubectl exec -n kube-system etcd-kind-control-plane -- \
  etcdctl snapshot status /tmp/etcd-snapshot.db --write-table=true
# 预期输出：
# +----------+----------+------------+------------+
# | REVISION | RAFT     | KEYS       | SIZE       |
# +----------+----------+------------+------------+
# | 12345    | 67890    | 1500       | 4.2 MB     |
# +----------+----------+------------+------------+

# 方式二：在 kind Docker 容器内直接执行
docker exec kind-control-plane etcdctl snapshot save /tmp/etcd-snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

> **etcd 备份的限制：** etcd 备份只包含 etcd 中的数据，**不包含持久卷（PV）中的实际文件数据**。对于有状态应用（数据库等），还需要单独备份 PV 数据。

### etcd 恢复

```bash
# 警告：etcd 恢复需要停止整个控制平面！

# 1. 停止 etcd 和控制平面组件
ssh control-plane-node
sudo systemctl stop kubelet
sudo crictl stopp $(sudo crictl pods -q) 2>/dev/null

# 2. 恢复 etcd 数据
sudo etcdctl snapshot restore /tmp/etcd-snapshot.db \
  --data-dir /var/lib/etcd-restore \
  --name kind-control-plane \
  --initial-cluster "kind-control-plane=https://127.0.0.1:2380"

# 3. 替换 etcd 数据目录
sudo mv /var/lib/etcd /var/lib/etcd-old
sudo mv /var/lib/etcd-restore /var/lib/etcd

# 4. 重启控制平面
sudo systemctl start kubelet
```

> **etcd 恢复是"核弹级"操作。** 它会将整个集群状态回滚到备份时刻。备份之后创建的所有资源都会消失。只用于最严重的灾难场景。

## Velero：Kubernetes 备份利器

Velero（原名 Heptio Ark）是 VMware 开源的 Kubernetes 备份和迁移工具，功能比 etcd 备份更精细：

| 特性 | etcd 备份 | Velero |
|------|----------|--------|
| 备份粒度 | 整个集群 | 按命名空间、标签、资源类型 |
| PV 数据 | 不包含 | 支持（通过 CSI 快照或文件复制） |
| 需要停机 | 恢复时需要 | 不需要 |
| 跨集群迁移 | 不支持 | 支持 |
| 定时备份 | 需要外部 cron | 内建 Schedule CRD |
| 选择性恢复 | 不支持 | 支持 |

### Velero 架构

```
┌──────────────────────────────────────────────────┐
│                  Velero 架构                      │
│                                                  │
│  ┌──────────────┐     ┌──────────────────────┐  │
│  │ Velero       │     │ Backup Storage        │  │
│  │ Server       │────▶│ Location (S3/Minio)  │  │
│  │ (Controller) │     │ 存储备份文件           │  │
│  └──────┬───────┘     └──────────────────────┘  │
│         │                                        │
│         │ 读取/恢复                               │
│         ▼                                        │
│  ┌──────────────────────────────────────────┐    │
│  │          Kubernetes API Server           │    │
│  │  (Namespaces, Deployments, ConfigMaps,   │    │
│  │   Secrets, PVs, ...)                     │    │
│  └──────────────────────────────────────────┘    │
└──────────────────────────────────────────────────┘
```

## 动手实践：安装和使用 Velero

### 第一步：安装 Velero

```bash
# 下载 Velero CLI
curl -LO https://github.com/vmware-tanzu/velero/releases/download/v1.13.0/velero-v1.13.0-linux-amd64.tar.gz
tar -xzf velero-v1.13.0-linux-amd64.tar.gz
sudo mv velero-v1.13.0-linux-amd64/velero /usr/local/bin/
velero version --client-only

# 安装 Minio（本地 S3 兼容存储，用于学习环境）
# 生产环境使用真实的 S3/GCS/Blob 存储
docker run -d --name minio \
  -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  minio/minio server /data --console-address ":9001"

# 创建 Minio bucket
docker exec minio mc alias set local http://localhost:9000 minioadmin minioadmin
docker exec minio mc mb local/velero-backups

# 安装 Velero 到集群
# 参见 velero-install.yaml 了解详细参数说明
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket velero-backups \
  --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=http://$(hostname -I | awk '{print $1}'):9000 \
  --snapshot-location-config region=minio \
  --secret-file ./credentials-velero

# credentials-velero 文件内容：
# [default]
# aws_access_key_id=minioadmin
# aws_secret_access_key=minioadmin

# 等待 Velero 就绪
kubectl get pods -n velero -w
kubectl get pods -n velero
# 预期输出：
# NAME                      READY   STATUS
# velero-xxxxxxxxxx-xxxxx   1/1     Running

# 验证 Velero 可以连接到存储后端
velero backup-location get
# 预期输出：Available
```

### 第二步：创建定时备份

参见 `backup-schedule.yaml`。

```bash
# 创建定时备份（每天凌晨 2 点自动备份）
kubectl apply -f backup-schedule.yaml

# 查看定时备份状态
velero schedule get
# NAME          STATUS    CREATED                         SCHEDULE    BACKUP TTL   LAST BACKUP
# daily-backup   Enabled   2024-01-01 00:00:00 +0000 UTC   0 2 * * *   720h0m0s    2024-01-15 02:00:00 +0000 UTC

# 查看已有的备份
velero backup get
```

### 第三步：手动备份

参见 `backup-manual.yaml`。

```bash
# 手动创建备份（在重要操作前执行）
velero backup create pre-deploy-backup \
  --include-namespaces myapp-prod \
  --wait

# 查看备份详情
velero backup describe pre-deploy-backup --details
# 输出包含：
#   Phase: Completed
#   Namespaces: Included: myapp-prod
#   Resources: Included: *
#   Items backed up: 42

# 验证备份内容
velero backup logs pre-deploy-backup | head -20
```

### 第四步：模拟灾难——误删命名空间

```bash
# 创建一个测试命名空间和应用
kubectl create namespace disaster-demo

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: disaster-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
    spec:
      containers:
        - name: demo-app
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo-config
  namespace: disaster-demo
data:
  database-url: "postgres://prod-db:5432/myapp"
  cache-url: "redis://prod-cache:6379"
EOF

# 确认资源存在
kubectl get all,configmaps -n disaster-demo

# 先创建备份！
velero backup create disaster-demo-backup \
  --include-namespaces disaster-demo \
  --wait

# 确认备份完成
velero backup get | grep disaster-demo

# 模拟灾难：误删命名空间
kubectl delete namespace disaster-demo

# 确认资源全部消失
kubectl get namespace disaster-demo
# Error from server (NotFound): namespaces "disaster-demo" not found
```

### 第五步：从备份恢复

```bash
# 从备份恢复命名空间
velero restore create disaster-demo-restore \
  --from-backup disaster-demo-backup \
  --wait

# 查看恢复状态
velero restore get
# NAME                    BACKUP                  STATUS      STARTED
# disaster-demo-restore   disaster-demo-backup    Completed   2024-01-15 ...

# 确认资源已恢复
kubectl get all,configmaps -n disaster-demo
# NAME                           READY   STATUS    RESTARTS
# pod/demo-app-xxxxxxxxxx-xxxxx  1/1     Running   0
# pod/demo-app-xxxxxxxxxx-xxxxx  1/1     Running   0
# NAME                       READY   UP-TO-DATE   AVAILABLE
# deployment.apps/demo-app   2/2     2            2
# NAME               DATA   AGE
# configmap/demo-config   2      1m

# 查看恢复详情（包含每个资源的恢复状态）
velero restore describe disaster-demo-restore --details
```

## 灾难恢复计划模板

每个团队都应该有一份灾难恢复计划（DR Plan）：

```markdown
# Kubernetes 灾难恢复计划

## 1. 备份策略
| 备份类型 | 频率 | 保留期 | 存储位置 |
|----------|------|--------|----------|
| Velero 全集群备份 | 每天 02:00 | 30 天 | S3://k8s-backups/daily/ |
| Velero 命名空间备份 | 每次部署前 | 90 天 | S3://k8s-backups/pre-deploy/ |
| etcd 快照 | 每周 | 4 周 | NFS://etcd-snapshots/ |
| PV 快照 | 每天凌晨 | 7 天 | 云厂商快照服务 |

## 2. 灾难场景与恢复步骤

### 场景 A：误删命名空间
RTO（恢复时间目标）：< 5 分钟
RPO（恢复点目标）：< 24 小时

步骤：
1. velero restore create --from-backup=<latest-backup> --include-namespaces=<ns>
2. velero restore get  # 等待恢复完成
3. kubectl get all -n <ns>  # 验证资源已恢复

### 场景 B：错误配置推送
RTO: < 10 分钟
RPO: 0（GitOps 方式可精确回滚到任意 commit）

步骤：
1. git revert <bad-commit>  # 回滚 Git 中的错误配置
2. ArgoCD/Flux 自动同步回滚后的配置
3. 或者：velero restore create --from-backup=<pre-deploy-backup>

### 场景 C：集群级故障
RTO: < 2 小时
RPO: < 24 小时

步骤：
1. 创建新的 Kubernetes 集群
2. 安装 Velero 到新集群，连接同一个备份存储
3. velero restore create --from-backup=<latest-full-backup>
4. 验证所有资源和数据已恢复

## 3. 责任人
| 角色 | 人员 | 职责 |
|------|------|------|
| DR 负责人 | @team-lead | 审批恢复操作 |
| 执行者 | @sre-oncall | 执行恢复步骤 |
| 通知者 | @sre-oncall | 通知相关方 |

## 4. 演练计划
- 每季度进行一次 DR 演练
- 每次演练后更新此计划
```

### RTO 和 RPO

| 指标 | 全称 | 含义 |
|------|------|------|
| **RTO** | Recovery Time Objective | 从灾难发生到恢复服务的最大允许时间 |
| **RPO** | Recovery Point Objective | 允许丢失的最大数据量（时间跨度） |

```
备份时间点        灾难发生        恢复完成
    │                │              │
    ├──── RPO ───────┤              │
    │  最多丢失这段时间的数据         │
    │                ├── RTO ──────┤
    │                │  最多允许这么长停机时间
```

## Velero 常用命令速查

```bash
# 备份
velero backup create <name> --include-namespaces <ns>     # 备份指定命名空间
velero backup create <name> --exclude-namespaces <ns>     # 排除命名空间
velero backup create <name> --include-resources deployments,configmaps  # 只备份特定资源
velero backup create <name> --selector app=myapp          # 按标签选择
velero backup get                                          # 列出所有备份
velero backup describe <name> --details                   # 查看备份详情
velero backup logs <name>                                  # 查看备份日志

# 恢复
velero restore create --from-backup <name>                 # 从备份恢复
velero restore create --from-backup <name> --include-namespaces <ns>  # 只恢复指定命名空间
velero restore create --from-backup <name> --namespace-mappings <src>=<dst>  # 恢复到不同命名空间
velero restore get                                         # 列出所有恢复
velero restore describe <name> --details                  # 查看恢复详情

# 定时备份
velero schedule create <name> --schedule="0 2 * * *" --include-namespaces <ns>
velero schedule get                                        # 列出定时任务
velero schedule pause <name>                               # 暂停
velero schedule unpause <name>                             # 恢复
```

## 思考题

1. 如果 Velero 的备份存储（S3 bucket）和 Kubernetes 集群在同一个云服务商的同一个区域，区域故障时会怎样？应该如何设计备份存储的位置？
2. etcd 备份可以恢复到不同版本的 Kubernetes 集群吗？为什么？
3. GitOps（ArgoCD/Flux）管理了大部分资源的声明式配置。那么 Velero 备份和 GitOps 仓库之间的关系是什么？两者是否冗余？
4. 在演练 Velero 恢复时，发现恢复后的 ConfigMap 中的数据库密码和当前值不同。这说明什么问题？如何避免？

---

**恭喜你完成了第十章的学习！** 本章涵盖了 Kubernetes CI/CD 和 GitOps 的核心知识：从 CI 流水线设计到 ArgoCD/Flux 的 GitOps 实践，再到渐进式交付和灾难恢复。这些是生产级 Kubernetes 运维的必备技能。
