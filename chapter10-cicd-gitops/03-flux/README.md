# 10.3 Flux：另一个 GitOps 选择

## Flux 简介

Flux 是由 Weaveworks 发起的 GitOps 工具，2019 年加入 CNCF，2022 年毕业（Graduated），是 CNCF 最高成熟度级别的项目之一。与 ArgoCD 一样遵循 GitOps 原则，但在架构和用户体验上有显著不同。

### Flux vs ArgoCD 对比

| 对比维度 | ArgoCD | Flux |
|----------|--------|------|
| **UI** | 功能丰富的 Web UI | 无官方 UI（有社区项目 Weaveworks UI） |
| **交互方式** | UI + CLI + CRD | CLI 为主 + CRD |
| **多租户** | AppProject 实现 | 原生较弱（需配合 RBAC） |
| **多集群** | 支持（Application 可指向远程集群） | 支持（通过 remote cluster） |
| **清单工具** | Kustomize、Helm、纯 YAML | Kustomize、Helm、纯 YAML |
| **通知** | 内建通知控制器 | Notification Controller |
| **镜像更新** | 需配合 Image Updater | 原生 Image Update Automation |
| **生态** | Argo Rollouts、Workflows | Flagger（渐进式交付） |
| **安装复杂度** | 较高（多个组件） | 较低（控制器按需安装） |
| **社区** | CNCF 孵化中 | CNCF 毕业 |

> **如何选择？**
>
> - 需要 Web UI 和可视化管理的团队 → **ArgoCD**
> - 偏好 CLI 驱动、Git 原生工作流的团队 → **Flux**
> - 需要精细的多租户隔离 → **ArgoCD**
> - 只需要简单的 GitOps 同步 → **Flux**
> - 两者都是成熟项目，功能上差距不大，选择更多取决于团队习惯

## Flux 核心组件

Flux 采用微服务架构，每个组件是独立的控制器，按需安装：

```
┌─────────────────────────────────────────────────────┐
│                  Flux 组件架构                       │
│                                                     │
│  ┌────────────────┐    ┌────────────────────────┐  │
│  │ source-        │    │ kustomize-             │  │
│  │ controller     │───▶│ controller             │  │
│  │ (管理源：Git    │    │ (Kustomize 清单协调)    │  │
│  │  Helm、Bucket) │    │                        │  │
│  └────────────────┘    └────────────────────────┘  │
│         │                                          │
│         │          ┌────────────────────────┐      │
│         ├─────────▶│ helm-                  │      │
│         │          │ controller             │      │
│         │          │ (Helm Release 协调)     │      │
│         │          └────────────────────────┘      │
│         │                                          │
│         │          ┌────────────────────────┐      │
│         └─────────▶│ notification-          │      │
│                    │ controller             │      │
│                    │ (告警和通知)             │      │
│                    └────────────────────────┘      │
│                                                     │
│  ┌──────────────────────────────────────────────┐  │
│  │ image-automation-controller                   │  │
│  │ (自动更新 Git 中的镜像引用)                     │  │
│  └──────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────┐  │
│  │ image-reflector-controller                    │  │
│  │ (扫描 Registry 获取最新镜像标签)                │  │
│  └──────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### 各组件职责

| 组件 | 职责 | 对应的 CRD |
|------|------|-----------|
| **source-controller** | 管理 Git、Helm、Bucket 等源 | `GitRepository`, `HelmRepository`, `Bucket` |
| **kustomize-controller** | 使用 Kustomize 构建并应用清单 | `Kustomization` |
| **helm-controller** | 管理 Helm Release 的生命周期 | `HelmRelease` |
| **notification-controller** | 发送事件通知（Slack、Webhook 等） | `Alert`, `Provider` |
| **image-reflector-controller** | 扫描镜像仓库获取标签信息 | `ImageRepository`, `ImagePolicy` |
| **image-automation-controller** | 自动更新 Git 中的镜像引用 | `ImageUpdateAutomation` |

### 数据流

```
GitRepository CR ──▶ source-controller 拉取代码
        │
        ▼
Kustomization CR ──▶ kustomize-controller 渲染清单 ──▶ 应用到集群
                                                              │
ImageRepository CR ──▶ image-reflector 扫描最新标签           │
        │                                                     │
        ▼                                                     │
ImageUpdateAutomation ──▶ image-automation 更新 Git 中的镜像   │
```

## Flux Bootstrap：初始化 GitOps

Flux 使用"自举"（Bootstrap）方式初始化——它将自己安装到集群，同时创建 Git 仓库中的初始配置：

```
flux bootstrap github
        │
        ├── 1. 在集群中安装所有 Flux 组件
        ├── 2. 在 GitHub 上创建 flux-system 仓库（或使用现有仓库）
        ├── 3. 将 Flux 自身的清单提交到 Git
        ├── 4. Flux 从自己的 Git 仓库拉取配置（自引用！）
        └── 5. 此后 Flux 的升级和配置都通过 Git 管理
```

> **自举的巧妙之处：** Flux 安装后，它自己的配置也存储在 Git 中。要升级 Flux？修改 Git 中 Flux 清单的版本号即可。这完美体现了 GitOps 的理念——**一切都是 Git 驱动的**。

## 动手实践：安装和使用 Flux

### 第一步：安装 Flux CLI

```bash
# macOS
brew install fluxcd/tap/flux

# Linux (amd64)
curl -s https://fluxcd.io/install.sh | sudo bash

# 验证安装
flux --version

# 检查集群兼容性（验证 Kubernetes 版本、必要组件等）
flux check --pre
# 预期输出：All checks passed
```

### 第二步：Bootstrap Flux

参见 `flux-install.yaml` 了解安装命令详解。

```bash
# 方式一：Bootstrap GitHub
# --owner: GitHub 用户或组织名
# --repository: 仓库名称
# --branch: 分支名
# --path: 清单在仓库中的路径
# --personal: 使用个人账户（而非组织）
flux bootstrap github \
  --owner=my-github-username \
  --repository=my-flux-repo \
  --branch=main \
  --path=./clusters/my-cluster \
  --personal

# 方式二：如果不想连接远程 Git（学习环境）
# 使用本地 kind 集群 + Git 仓库
flux install

# 等待所有组件就绪
kubectl get pods -n flux-system -w
kubectl get pods -n flux-system
# 预期输出：
# NAME                                       READY   STATUS
# helm-controller-xxxxxxxxxx-xxxxx           1/1     Running
# image-automation-controller-...-xxxxx      1/1     Running
# image-reflector-controller-...-xxxxx       1/1     Running
# kustomize-controller-xxxxxxxxxx-xxxxx      1/1     Running
# notification-controller-xxxxxxxxxx-xxxxx   1/1     Running
# source-controller-xxxxxxxxxx-xxxxx         1/1     Running
```

### 第三步：创建 GitRepository 源

告诉 Flux 从哪里拉取清单：

```bash
# 创建 GitRepository 资源（指向你的清单仓库）
flux create source git myapp \
  --url=https://github.com/myorg/k8s-manifests \
  --branch=main \
  --interval=1m

# 查看源状态
flux get sources git
# 输出类似：
# NAME    REVISION        SUSPENDED       READY   MESSAGE
# myapp   main@abc1234    False           True    Fetched revision: main@abc1234...
```

### 第四步：创建 Kustomization

告诉 Flux 用 Kustomize 构建并应用清单。参见 `flux-kustomization.yaml`。

```bash
# 创建 Kustomization（将 Git 源中的清单应用到集群）
flux create kustomization myapp \
  --source=myapp \
  --path="./overlays/production" \
  --prune=true \
  --interval=5m \
  --validation=client \
  --health-check="Deployment/myapp.production" \
  --health-check-timeout=2m

# 查看同步状态
flux get kustomizations
# 输出类似：
# NAME    REVISION        SUSPENDED       READY   MESSAGE
# myapp   main@abc1234    False           True    Applied revision: main@abc1234...
```

### 第五步：推送清单到 Git，观察自动同步

```bash
# 1. 在清单仓库中创建或修改资源
cd k8s-manifests
cat > deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: flux-demo
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
EOF

# 2. 提交并推送
git add .
git commit -m "feat: add demo app deployment"
git push

# 3. 回到集群，观察 Flux 自动同步（默认 1 分钟内检测到变更）
flux get kustomizations --watch

# 4. 查看 Pod 状态
kubectl get pods -n flux-demo
```

### 第六步：观察协调过程

```bash
# 查看 Flux 控制器日志
kubectl logs -n flux-system -l app=kustomize-controller --tail=50

# 强制立即同步（不等 interval）
flux reconcile kustomization myapp --with-source

# 暂停自动同步（用于维护窗口）
flux suspend kustomization myapp

# 恢复自动同步
flux resume kustomization myapp

# 查看 Flux 事件
kubectl get events -n flux-system --sort-by='.lastTimestamp'
```

## Flux 的镜像自动更新

这是 Flux 相对于 ArgoCD 的一个亮点功能——自动检测 Registry 中的新镜像并更新 Git 仓库：

```bash
# 1. 告诉 Flux 关注哪个镜像仓库
flux create image repository myapp \
  --image=ghcr.io/myorg/myapp \
  --interval=1m

# 2. 定义镜像选择策略（选最新版本）
flux create image policy myapp \
  --image-ref=myapp \
  --select-semver=^1.0

# 3. 配置自动更新：新镜像标签写入 Git
flux create image update myapp \
  --git-repo-ref=myapp \
  --image=myapp \
  --interval=1m
```

> **这个流程的意义：** CI 只需构建镜像并推送到 Registry，Flux 会自动检测到新镜像并更新 Git 中的清单。完全不需要 CI 去提交代码到 Git 仓库——进一步解耦了 CI 和 CD。

## Flux 与 ArgoCD 的 GitOps 工作流对比

```
# ArgoCD 工作流
CI 构建镜像 → CI 推送镜像 → CI 更新 Git 清单 → ArgoCD 检测 Git 变更 → 同步到集群

# Flux 工作流（使用 Image Automation）
CI 构建镜像 → CI 推送镜像 → Flux 扫描 Registry → Flux 自动更新 Git → Flux 自动同步到集群
                                   （CI 不需要操作 Git）       （可选，也可以只更新集群）
```

## 卸载 Flux

```bash
# 卸载 Flux（会删除所有 Flux 组件和 CRD）
flux uninstall
```

> **警告：** 卸载 Flux 时，由 Flux 管理的资源**不会被删除**（集群中的资源保留）。这和 ArgoCD 的 `finalizer` 行为不同。

## 思考题

1. Flux Bootstrap 将 Flux 自身的配置也存入 Git。如果这个 Git 仓库损坏了，如何恢复 Flux？
2. Flux 没有官方 Web UI，这对运维工作有什么影响？什么场景下 CLI-only 反而是优势？
3. 对比 Flux 的 Image Update Automation 和 ArgoCD 的 Image Updater，两者的工作方式有什么本质区别？
4. 如果需要在同一个集群中管理多个团队的应用，Flux 和 ArgoCD 分别如何实现多租户隔离？

---

**下一节：** [10.4 渐进式交付](../04-progressive-delivery/README.md)
