# 02 - Operator 模式

## 从 CRD 到 Operator

上一节我们学习了 CRD——它让你可以定义自己的资源类型（如 `Website`、`Backup`）。但 CRD 只是**数据定义**，它不会帮你创建 Pod、不会监控状态、不会处理故障。

这就好比你有了一张数据库表，但没有业务代码去操作它。**Operator 就是那个"业务代码"**。

```
CRD    = 定义"想要什么"（What）
Operator = 实现"怎么做"（How）
```

**Operator = CRD + Custom Controller**

## 什么是 Controller

要理解 Operator，首先要理解 K8s 内置的 Controller 模式。K8s 几乎所有功能都是通过 Controller 实现的：

| 内置 Controller | 职责 |
|----------------|------|
| Deployment Controller | 监控 Deployment → 创建/管理 ReplicaSet |
| ReplicaSet Controller | 监控 ReplicaSet → 创建/删除 Pod 维持副本数 |
| Node Controller | 监控 Node 状态 → 标记 NotReady |
| Service Controller | 监控 Service → 管理 Endpoints |

它们都遵循同一个模式：**控制循环（Control Loop）**。

## 控制循环：Watch → Diff → Reconcile

这是 K8s 的核心设计哲学，也是 Operator 的灵魂：

```
                    ┌─────────────────────────┐
                    │                         │
                    ▼                         │
   ┌──────────┐  ┌──────────┐  ┌──────────┐  │
   │  Watch   │→│   Diff   │→│ Reconcile│──┘
   │ 监听变化  │  │ 对比差异  │  │ 执行调谐  │
   └──────────┘  └──────────┘  └──────────┘
        ↑                            │
        │                            ▼
   ┌──────────┐              ┌──────────────┐
   │  Event   │              │ Update Status│
   │ 事件源    │              │ 更新资源状态  │
   └──────────┘              └──────────────┘
```

### Watch（监听）

Controller 通过 K8s API Server 的 Watch 机制，实时监听资源变化。当用户创建、更新或删除一个 CR 时，API Server 会推送事件给 Controller。

### Diff（对比）

Controller 获取两份信息：
- **期望状态（Desired State）**：从 CR 的 `spec` 字段读取——用户想要什么
- **实际状态（Actual State）**：查询集群当前的资源——集群里现在有什么

对比两者，找出差异。例如：用户想要 3 个副本（spec.replicas=3），但集群里只有 2 个 Pod——差 1 个。

### Reconcile（调谐）

根据差异执行操作，使实际状态趋近期望状态。例如：差 1 个 Pod，就创建 1 个。

> **最终一致性**：Controller 不保证"立刻"达到期望状态。它可能失败、可能重启，但只要循环持续运行，最终一定会收敛到期望状态。这是 K8s 的核心设计理念。

## 为什么需要 Operator

传统的 K8s 应用部署方式是写一堆 YAML（Deployment、Service、ConfigMap……），然后手动管理。但复杂应用（如数据库、消息队列）有特殊的运维需求：

| 场景 | 传统方式 | Operator 方式 |
|------|---------|--------------|
| 数据库主从切换 | 人工执行 failover 脚本 | Operator 自动检测并执行切换 |
| 定期备份 | 外部 Cron 任务 | Operator 读取 Backup CR，自动调度 |
| 按数据量扩容 | 手动修改副本数 | Operator 监控指标，自动扩缩 |
| 版本升级 | 逐个手动更新 | Operator 执行滚动升级策略 |
| 配置变更重启 | 手动滚动重启 | Operator 自动检测并重启 |

**Operator 的核心价值：将运维知识编码为自动化逻辑。**

## Reconcile Loop 深入理解

以一个 Backup Operator 为例，看看 Reconcile 循环如何工作：

```
用户创建 Backup CR:
  spec:
    targetDatabase: my-db
    schedule: "0 2 * * *"
    storage: s3://backup-bucket

         │
         ▼
   ┌─────────────────────────────────────────────┐
   │           Reconcile Loop                    │
   │                                             │
   │  1. 读取 Backup CR 的 spec                  │
   │     → schedule="0 2 * * *"                  │
   │     → targetDatabase="my-db"                │
   │                                             │
   │  2. 查询集群：是否存在对应的 CronJob?         │
   │     → 不存在 → 需要创建                      │
   │                                             │
   │  3. 创建 CronJob:                           │
   │     - schedule: "0 2 * * *"                 │
   │     - command: pg_dump → s3 upload          │
   │                                             │
   │  4. 更新 Backup CR status:                  │
   │     status.lastBackupStatus = "Scheduled"   │
   └─────────────────────────────────────────────┘
```

每次 Controller 收到事件（或定期 re-sync），都会执行这个循环。即使 Controller 崩溃重启，重新进入循环后依然能恢复到正确状态——因为它总是从"当前状态"出发，而不是依赖内存中的中间状态。

## Operator SDK 框架

从零写一个 Controller 需要处理很多底层细节：Watch 机制、事件队列、错误重试、RBAC 权限……框架帮你处理这些样板代码：

| 框架 | 语言 | 特点 |
|------|------|------|
| **Kubebuilder** | Go | K8s 官方推荐，基于 `controller-runtime` 库，代码生成能力强 |
| **Operator SDK** | Go / Ansible / Helm | RedHat 出品，支持多语言，提供完整的项目脚手架 |
| **Metacontroller** | 任意语言 | 轻量级，通过 Webhook 实现，适合简单的编排需求 |

> 对于学习阶段，理解 Operator 的架构原理比掌握某个框架的 API 更重要。框架只是工具，模式才是核心。

## Operator 的典型架构

一个完整的 Operator 通常包含：

```
┌──────────────────────────────────────────────────┐
│                   K8s Cluster                     │
│                                                   │
│  ┌──────────────┐    ┌─────────────────────────┐ │
│  │   CRD        │    │   Operator Controller   │ │
│  │ (Backup)     │←──→│   (Deployment)          │ │
│  └──────────────┘    │                          │ │
│                      │  Watch CR → Reconcile    │ │
│  ┌──────────────┐    │                          │ │
│  │ CronJob      │←───│  Create/Manage           │ │
│  │ (备份任务)    │    │                          │ │
│  └──────────────┘    └─────────────────────────┘ │
│                                                   │
│  ┌──────────────┐                                 │
│  │ RBAC         │  Controller 需要权限才能操作资源 │
│  │ (权限配置)    │                                 │
│  └──────────────┘                                 │
└──────────────────────────────────────────────────┘
```

具体来说，Operator 需要以下 K8s 资源：

| 资源 | 作用 |
|------|------|
| **CRD** | 定义自定义资源的 schema |
| **Deployment** | 运行 Controller 进程 |
| **ServiceAccount** | Controller 运行时的身份 |
| **ClusterRole / Role** | 定义 Controller 可以操作哪些资源 |
| **ClusterRoleBinding / RoleBinding** | 将 Role 绑定到 ServiceAccount |

## Step by Step：理解 Operator 的运作

由于编写完整的 Operator 代码超出学习范围（需要 Go + controller-runtime），我们通过 CRD 和 CR 来理解 Operator 的工作方式。

### Step 1: 创建 Backup CRD

```bash
# 注册 Backup 自定义资源类型
kubectl apply -f simple-crd.yaml

# 验证 CRD 已注册
kubectl get crd backups.example.com
```

### Step 2: 查看 API 资源

```bash
# 确认 K8s API 已识别 Backup 资源
kubectl api-resources | grep backup

# 输出：
# backups   bk   example.com/v1alpha1   true   Backup
```

### Step 3: 创建 Backup CR

```bash
# 创建一个备份任务实例
kubectl apply -f backup-cr.yaml

# 查看
kubectl get backups

# 输出：
# NAME               SCHEDULE      TARGET          LAST STATUS   AGE
# daily-db-backup    0 2 * * *     my-db-service                 5s
```

### Step 4: 观察 Status 字段

```bash
# 目前 status 是空的，因为还没有 Operator 在管理它
kubectl get backup daily-db-backup -o yaml | grep -A10 status

# 如果有一个 Operator 在运行，它会：
# 1. 检测到 Backup CR 被创建
# 2. 创建对应的 CronJob
# 3. 等待第一次备份完成
# 4. 更新 status.lastBackupStatus = "Success"
# 5. 更新 status.lastBackupTime = "2025-01-01T02:00:00Z"
```

### Step 5: 查看 Operator 概念架构

```bash
# operator-concepts.yaml 中包含了 Operator 的概念架构说明
# 以及 Controller Deployment 和 RBAC 的参考配置
# 虽然不能直接部署（因为没有真实的 Operator 镜像），但可以帮助理解：
# - Controller 以 Deployment 形式运行
# - 通过 ServiceAccount 鉴权
# - ClusterRole 定义它需要的权限
cat operator-concepts.yaml
```

### Step 6: 清理

```bash
kubectl delete -f backup-cr.yaml
kubectl delete -f simple-crd.yaml
```

## 真实世界的 Operator 示例

在生产环境中，很多知名项目都使用 Operator 模式：

| 项目 | Operator 功能 |
|------|--------------|
| **Prometheus Operator** | 管理 Prometheus 实例的部署、配置、升级 |
| **cert-manager** | 自动签发和续期 TLS 证书 |
| **MySQL Operator** | MySQL 主从集群的部署、备份、故障恢复 |
| **Argo Rollouts** | 高级部署策略（金丝雀、蓝绿） |
| **Kafka Operator** | Kafka 集群管理、Topic 管理、扩缩容 |

## 思考题

1. Controller 崩溃重启后，为什么仍然能正确工作？它依赖什么机制保证"不遗漏事件"？
2. 为什么 Operator 的 RBAC 权限需要精确控制？如果权限过大会带来什么风险？
3. CRD 的 `status` subresource 和 `spec` 分开设计，这有什么好处？如果 Controller 更新 status 时和用户更新 spec 产生冲突怎么办？
4. 假设你要写一个 "Website Operator"（对应上一节的 Website CRD），Reconcile 循环需要做哪些事情？

---

上一个 → [01 - CRD：自定义资源定义](../01-crd/)　｜　下一个 → [03 - Mutating Admission Webhook](../03-mutating-admission/)
