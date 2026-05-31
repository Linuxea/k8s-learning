# 10.2 ArgoCD 与 GitOps

## 什么是 GitOps？

GitOps 是一种现代化的持续交付方法，其核心理念是：

> **Git 仓库是集群期望状态的唯一真实来源（Single Source of Truth）。**

传统部署方式（Push 模式）：

```
CI 流水线 ──kubectl apply──▶ K8s 集群
   │                           │
   │ 需要集群管理员凭证          │ 无法知道"谁改了什么"
   │ 安全风险高                  │ 缺乏审计追踪
```

GitOps 部署方式（Pull 模式）：

```
Git 仓库（声明式清单）  ◀──集群内的控制器持续拉取──  K8s 集群
   │                                                   │
   │ 变更通过 PR 审查                                     │ 控制器自动检测漂移
   │ 完整的变更历史                                       │ 自动修复配置偏移
   │ Git commit = 审计日志                                │ 无需外部凭证
```

### GitOps 四项原则（OpenGitOps 标准）

| 原则 | 说明 |
|------|------|
| **声明式** | 整个系统用声明式语言描述（Kubernetes YAML） |
| **版本控制且不可变** | 期望状态存储在 Git 中，变更通过 commit/PR |
| **自动拉取** | 软件代理自动从 Git 拉取期望状态 |
| **持续协调** | 软件代理持续对比期望状态和实际状态，自动纠正漂移 |

## ArgoCD 架构

ArgoCD 是 Kubernetes 原生的 GitOps 持续交付工具，由 Intuit 开发并捐赠给 CNCF。

### 核心组件

```
┌─────────────────────────────────────────────────────┐
│                    ArgoCD 架构                       │
│                                                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │
│  │ API      │  │ Repo     │  │ Application      │  │
│  │ Server   │  │ Server   │  │ Controller       │  │
│  │ (UI/API) │  │ (Git连接) │  │ (核心协调引擎)    │  │
│  └──────────┘  └──────────┘  └──────────────────┘  │
│       │              │               │              │
│       ▼              ▼               ▼              │
│  ┌──────────────────────────────────────────────┐  │
│  │              Redis (缓存)                      │  │
│  └──────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

| 组件 | 功能 |
|------|------|
| **Application Controller** | 核心控制器，持续对比 Git 仓库与集群实际状态 |
| **API Server** | 提供 Web UI 和 REST API，用户交互入口 |
| **Repository Server** | 管理 Git 仓库连接，缓存清单渲染结果 |
| **Redis** | 缓存 Git 仓库和集群状态查询结果 |

### 工作流程

```
1. 用户在 Git 仓库中更新 deployment.yaml（比如修改镜像版本）
2. ArgoCD 的 Application Controller 定期拉取 Git 仓库（默认 3 分钟）
3. 检测到 Git 中的期望状态与集群实际状态不一致（Drift）
4. 根据 Sync Policy 决定是自动还是手动同步
5. 如果自动同步，ArgoCD 将变更应用到集群
6. Kubernetes 执行滚动更新，创建新 Pod
```

## 核心概念

### Application

ArgoCD 最核心的 CRD（自定义资源），定义了"哪个 Git 仓库的哪个路径"映射到"集群的哪个命名空间"：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/myorg/k8s-manifests.git
    targetRevision: main
    path: overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp-prod
```

### AppProject

用于多租户隔离，控制一个项目可以访问哪些 Git 仓库、哪些集群、哪些命名空间：

| AppProject 字段 | 作用 |
|-----------------|------|
| `sourceRepos` | 允许的 Git 仓库列表 |
| `destinations` | 允许部署的目标集群和命名空间 |
| `clusterResourceWhitelist` | 允许创建的集群级资源 |
| `namespaceResourceBlacklist` | 禁止创建的命名空间级资源 |

### Sync Policy（同步策略）

| 策略 | 行为 | 适用场景 |
|------|------|----------|
| **Manual** | 检测到漂移后不自动同步，等待人工触发 | 生产环境，需要审批 |
| **Automated** | 检测到漂移后自动同步 | 开发/测试环境 |
| **Self-heal** | 集群状态被手动修改时自动恢复到 Git 定义的状态 | 任何需要防止手动修改的环境 |
| **Prune** | 自动删除 Git 中已移除但集群中仍存在的资源 | 保持集群与 Git 完全一致 |

> **Self-heal 的价值：** 假设有人通过 `kubectl scale deployment myapp --replicas=10` 手动修改了副本数，Self-heal 会在检测到偏差后自动恢复到 Git 中定义的副本数。这防止了"配置漂移"——集群的实际状态悄悄偏离了期望状态。

### ArgoCD vs 传统 CI/CD

| 对比维度 | 传统 CI/CD（Push） | ArgoCD（Pull） |
|----------|-------------------|----------------|
| 凭证管理 | CI 系统持有集群凭证 | 集群内部运行，无需外部凭证 |
| 审计追踪 | 分散在各 CI 系统中 | 集中在 Git 历史 |
| 配置漂移 | 无法检测 | 自动检测并修复 |
| 回滚方式 | 重新运行 CI 流水线 | `git revert` 或 ArgoCD 回滚 |
| 多集群部署 | 需要配置每个集群的凭证 | ArgoCD 统一管理 |
| 学习曲线 | 较低 | 需要理解 GitOps 概念 |

## 动手实践：安装和使用 ArgoCD

### 第一步：安装 ArgoCD

```bash
# 创建 argocd 命名空间
kubectl create namespace argocd

# 安装 ArgoCD（非 HA 模式，适合学习和开发）
# 参见 argocd-install.yaml
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 等待所有 Pod 就绪
kubectl get pods -n argocd -w

# 确认所有组件运行正常
kubectl get pods -n argocd
# 预期输出：
# NAME                                                READY   STATUS
# argocd-application-controller-0                     1/1     Running
# argocd-repo-server-xxxxxxxxxx-xxxxx                1/1     Running
# argocd-server-xxxxxxxxxx-xxxxx                     1/1     Running
# argocd-redis-xxxxxxxxxx-xxxxx                      1/1     Running
# argocd-dex-server-xxxxxxxxxx-xxxxx                 1/1     Running
# argocd-notifications-controller-xxxxxxxxxx-xxxxx   1/1     Running
```

### 第二步：访问 ArgoCD Web UI

```bash
# 获取初始管理员密码（自动生成的随机密码）
# 存储在 Secret 中，Base64 编码
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
# 记下输出的密码

# 方式一：端口转发（推荐用于学习）
kubectl port-forward svc/argocd-server -n argocd 8080:443
# 然后在浏览器访问 https://localhost:8080
# 用户名: admin
# 密码: 上一步获取的密码

# 方式二：NodePort 或 LoadBalancer（生产环境推荐）
# kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
```

### 第三步：安装 ArgoCD CLI

```bash
# Linux (amd64)
curl -sLO https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd-linux-amd64
sudo mv argocd-linux-amd64 /usr/local/bin/argocd

# 登录（跳过 TLS 验证，因为本地端口转发使用自签名证书）
argocd login localhost:8080 --username admin --password <上一步的密码> --insecure
```

### 第四步：创建 Application

参见 `argocd-app.yaml`。这个 Application 告诉 ArgoCD：

- 从 `https://github.com/argoproj/argocd-example-apps.git` 仓库拉取清单
- 使用 `guestbook` 路径下的 YAML
- 部署到当前集群的 `guestbook` 命名空间
- 启用自动同步和 Self-heal

```bash
# 创建 Application
kubectl apply -f argocd-app.yaml

# 在 ArgoCD 中查看同步状态
argocd app list
argocd app get guestbook

# 观察同步过程（首次可能需要 30 秒）
kubectl get pods -n guestbook -w
```

### 第五步：观察 GitOps 工作流

```bash
# 1. 查看 Application 状态
# "Synced" = 集群状态与 Git 一致
# "Out of Sync" = Git 有更新但尚未同步到集群
argocd app get guestbook

# 2. 查看同步详情
argocd app history guestbook

# 3. 手动触发同步（如果使用手动策略）
argocd app sync guestbook

# 4. 模拟配置漂移：手动修改副本数
kubectl scale deployment guestbook-ui --replicas=5 -n guestbook

# 5. 观察 Self-heal：ArgoCD 会自动恢复到 Git 定义的副本数
# 等待约 30 秒后检查
kubectl get deployment guestbook-ui -n guestbook -o jsonpath='{.spec.replicas}'
# 如果 Self-heal 启用，应该恢复到 Git 中定义的值

# 6. 查看 ArgoCD 事件日志
kubectl get events -n argocd --sort-by='.lastTimestamp'
```

### 第六步：修改 Git，观察自动同步

如果是你自己的仓库：

```bash
# 1. 克隆清单仓库
git clone https://github.com/yourorg/k8s-manifests.git
cd k8s-manifests

# 2. 修改 deployment 中的镜像版本
# 编辑 deployment.yaml，修改镜像标签

# 3. 提交并推送
git add .
git commit -m "chore: update image to v2.0.0"
git push

# 4. 回到集群，观察 ArgoCD 自动检测变更并同步
argocd app get guestbook --refresh

# 5. 查看滚动更新
kubectl rollout status deployment/guestbook-ui -n guestbook
```

## Application 状态详解

```
┌─────────────────────────────────────────┐
│         ArgoCD Application 状态          │
│                                         │
│  Sync Status: Synced / OutOfSync        │
│  ├── Synced: Git 状态 = 集群状态         │
│  └── OutOfSync: Git 有更新未同步         │
│                                         │
│  Health Status: Healthy / Degraded / ...│
│  ├── Healthy: 所有资源正常运行            │
│  ├── Progressing: 正在部署中             │
│  ├── Degraded: 有 Pod 异常               │
│  └── Suspended: 资源被暂停               │
│                                         │
│  Operation: Sync / Rollback / None      │
│  └── 显示当前正在执行的操作               │
└─────────────────────────────────────────┘
```

## 多环境管理

实际项目中通常有多个环境（dev、staging、prod），ArgoCD 推荐使用 "App of Apps" 模式：

```
argocd-apps/                    # 一个 Git 仓库管理所有环境的 Application
├── dev/
│   └── app.yaml                # 开发环境的 Application
├── staging/
│   └── app.yaml                # 预发布环境的 Application
├── production/
│   └── app.yaml                # 生产环境的 Application
└── apps.yaml                   # "App of Apps"：包含以上所有 Application
```

> **App of Apps 模式：** 创建一个"元 Application"，它的源路径包含其他所有 Application 的 YAML。ArgoCD 会自动管理这些子 Application，实现统一的 GitOps 管理。

## 思考题

1. 如果 Git 仓库被误删除了，ArgoCD 还能管理集群中的应用吗？如何恢复？
2. ArgoCD 默认每 3 分钟检查一次 Git 仓库。如果你需要"推送代码后立即部署"，有哪些方法可以减少延迟？
3. 在 Self-heal 模式下，紧急修复（hotfix）应该怎么做？直接修改集群还是修改 Git？
4. 如果一个团队同时使用 ArgoCD 和手动 `kubectl apply`，会发生什么？这种做法有什么问题？

---

**下一节：** [10.3 Flux GitOps](../03-flux/README.md)
