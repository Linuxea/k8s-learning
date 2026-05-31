# 10.1 CI/CD 流水线：从代码到部署

## 什么是 CI/CD？

CI/CD 是 **持续集成（Continuous Integration）** 和 **持续部署/交付（Continuous Deployment/Delivery）** 的缩写。在 Kubernetes 语境下，它的含义更加明确：

| 概念 | 全称 | 核心含义 |
|------|------|----------|
| CI | Continuous Integration | 代码合并后自动执行：lint → 测试 → 构建镜像 → 推送镜像 |
| CD | Continuous Delivery | 自动将构建好的镜像部署到目标环境（需人工审批） |
| CD | Continuous Deployment | 全自动部署，无需人工干预 |

### Kubernetes 中的 CI/CD 全流程

在传统部署中，CI/CD 的终点是"把二进制文件放到服务器上"。而在 Kubernetes 中，终点是 **"更新集群中的声明式配置（YAML）"**。整个流程如下：

```
开发者提交代码
      │
      ▼
  ┌─────────┐
  │   CI    │  1. 代码静态检查（lint）
  │ 流水线   │  2. 运行单元测试
  │         │  3. 构建 Docker 镜像
  │         │  4. 推送镜像到 Registry
  │         │  5. 更新 K8s 部署清单中的镜像标签
  └────┬────┘
       │
       ▼
  ┌─────────┐
  │   CD    │  6. 将更新后的清单应用到集群
  │ 部署阶段 │  7. Kubernetes 拉取新镜像并滚动更新
  └─────────┘
```

> **为什么 Kubernetes 的 CI/CD 和传统不同？**
>
> Kubernetes 是声明式系统——你告诉它"我想要 3 个 nginx:1.25 的 Pod"，它就会确保这个状态。因此 CI/CD 的核心不是"执行部署脚本"，而是 **"更新声明并让 Kubernetes 自动达成"**。

## 容器镜像生命周期

理解 CI/CD 的前提是理解容器镜像的生命周期：

```
构建 (build) → 标签 (tag) → 推送 (push) → 拉取 (pull) → 运行 (run)
     │              │             │             │
  Dockerfile    版本控制       存储在         K8s 节点
  docker build  语义化版本     Registry      kubelet 拉取
```

### 镜像标签策略

| 标签策略 | 示例 | 优点 | 缺点 |
|----------|------|------|------|
| 最新标签 | `nginx:latest` | 简单方便 | 不可重复、不可追溯 |
| 版本号 | `nginx:1.25.3` | 精确可追溯 | 需手动更新 |
| Git SHA | `nginx:abc1234` | 自动化、唯一 | 可读性差 |
| 构建号 | `nginx:bld-456` | 自动递增 | 需维护构建号 |

> **最佳实践：** 在生产环境中，**永远不要使用 `:latest` 标签**。推荐使用 Git SHA 或语义化版本号，这样可以精确追溯到某次代码提交。

## 镜像仓库（Image Registry）

镜像仓库是存储和分发容器镜像的服务：

| Registry | 类型 | 特点 |
|----------|------|------|
| Docker Hub | 公有 | 最流行，免费账户有限制（200 次拉取/6小时） |
| GitHub Container Registry (ghcr.io) | 公有 | 与 GitHub Actions 深度集成 |
| Harbor | 私有 | CNCF 项目，支持镜像扫描、签名、RBAC |
| 阿里云容器镜像服务 (ACR) | 公有/私有 | 国内访问快，支持企业版 |

```bash
# 登录 Docker Hub
docker login

# 登录 GitHub Container Registry
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin

# 标记并推送镜像到不同 registry
docker tag myapp:latest docker.io/myuser/myapp:v1.0.0
docker push docker.io/myuser/myapp:v1.0.0

docker tag myapp:latest ghcr.io/myorg/myapp:v1.0.0
docker push ghcr.io/myorg/myapp:v1.0.0
```

## CI 流水线设计

一个面向 Kubernetes 的完整 CI 流水线包含以下阶段：

```
代码检查 → 单元测试 → 构建镜像 → 推送镜像 → 更新清单
   │          │          │          │          │
  lint      pytest    docker     docker     sed/kustomize
  eslint    go test   build      push       set image
```

### 各阶段详解

| 阶段 | 工具示例 | 目的 |
|------|----------|------|
| 代码检查 | eslint, golint, ruff | 发现代码风格问题和潜在 bug |
| 单元测试 | pytest, go test, jest | 验证代码逻辑正确性 |
| 构建镜像 | docker build, kaniko, buildah | 将应用打包为容器镜像 |
| 推送镜像 | docker push | 将镜像存储到 Registry |
| 更新清单 | kustomize edit, yq, sed | 更新 K8s YAML 中的镜像引用 |

> **为什么不在 CI 中直接 kubectl apply？**
>
> 传统做法是在 CI 流水线中直接运行 `kubectl apply`。这种方式有几个问题：
> 1. CI 系统需要集群的管理员凭证——安全风险大
> 2. 无法追踪"当前集群状态"与"Git 仓库状态"的差异
> 3. 多人协作时容易产生冲突
>
> 更好的做法是：CI 只负责构建和推送镜像、更新 Git 仓库中的清单，然后由 GitOps 工具（如 ArgoCD）自动同步到集群。这将在下一节详细讨论。

## Skaffold：本地开发利器

Skaffold 是 Google 开源的本地 Kubernetes 开发工具，它能实现：

- **自动构建**：检测代码变更 → 自动构建镜像
- **自动部署**：构建完成后自动部署到本地集群
- **自动日志**：实时显示应用日志
- **端口转发**：自动配置端口转发

```bash
# 安装 Skaffold（Linux）
curl -Lo skaffold https://storage.googleapis.com/skaffold/releases/latest/skaffold-linux-amd64
chmod +x skaffold
sudo mv skaffold /usr/local/bin/

# 在项目目录中初始化
skaffold init

# 启动开发循环
skaffold dev
```

Skaffold 的典型工作流：

```
保存代码文件
    │
    ▼
Skaffold 检测变更
    │
    ▼
自动构建新镜像（使用本地 Docker 或 kaniko）
    │
    ▼
自动推送到本地 Registry（kind 集群内建的）
    │
    ▼
自动更新 Deployment 中的镜像引用
    │
    ▼
Kubernetes 执行滚动更新
    │
    ▼
Skaffold 显示新 Pod 的日志
```

> **什么时候用 Skaffold？** 开发阶段用 Skaffold 快速迭代，生产部署用 CI/CD + GitOps。

## 动手实践：构建一个 CI 流水线

### 第一步：编写 Dockerfile

参见 `Dockerfile` 文件。这是一个基于 nginx 的简单 Web 应用：

```bash
# 构建镜像
docker build -t myapp:v1.0.0 .

# 本地测试
docker run -d -p 8080:80 myapp:v1.0.0
curl http://localhost:8080

# 预期输出：Hello from Kubernetes CI/CD demo! Version: v1.0.0
```

### 第二步：编写 CI 流水线配置

参见 `ci-pipeline.yaml`。这是一个 GitHub Actions 风格的 CI 配置，展示了完整的流水线流程。

**GitHub Actions 关键概念：**

| 概念 | 说明 |
|------|------|
| `on` | 触发条件（push、PR、定时等） |
| `jobs` | 一组并行或串行的工作单元 |
| `steps` | job 内的具体执行步骤 |
| `uses` | 引用预定义的 Action |
| `runs` | 直接执行 shell 命令 |

### 第三步：使用 Kustomize 管理清单

参见 `kustomization.yaml`。Kustomize 允许你在不修改原始 YAML 的前提下，通过"补丁"的方式定制部署：

```bash
# 查看 Kustomize 渲染结果
kubectl kustomize .

# 直接应用
kubectl apply -k .

# 设置新镜像（CI 流水线中常用）
kustomize edit set image myapp=ghcr.io/myorg/myapp:new-tag
```

> **为什么用 Kustomize 而不是 Helm？**
>
> Kustomize 是 Kubernetes 原生工具（kubectl 内建），学习成本低，适合简单的清单管理。Helm 功能更强大但复杂度也更高。在 CI/CD 场景中，两者都可以使用，选择取决于团队偏好。

### 第四步：理解完整部署流程

将以上步骤串联起来的完整流程：

```bash
# 1. 开发者提交代码到 Git
git add .
git commit -m "feat: add new feature"
git push origin main

# 2. CI 系统自动触发（GitHub Actions 示例）
#    - 检出代码
#    - 构建镜像：docker build -t ghcr.io/myorg/myapp:abc1234 .
#    - 推送镜像：docker push ghcr.io/myorg/myapp:abc1234
#    - 更新清单：kustomize edit set image myapp=ghcr.io/myorg/myapp:abc1234
#    - 提交清单变更回 Git

# 3. GitOps 工具（如 ArgoCD）检测到 Git 变更
#    - 自动同步新清单到集群
#    - Kubernetes 拉取新镜像并滚动更新

# 4. 在集群中观察部署
kubectl rollout status deployment/myapp
kubectl get pods -l app=myapp
```

## 流程图：从代码到运行中的 Pod

```
┌──────────┐    ┌──────────┐    ┌───────────┐    ┌──────────┐
│  开发者   │───▶│   Git    │───▶│ CI 流水线  │───▶│ Registry │
│ 写代码    │    │  仓库    │    │ 构建镜像   │    │ 存储镜像  │
└──────────┘    └────┬─────┘    └───────────┘    └────┬─────┘
                     │                                  │
                     │  更新清单                         │ 拉取镜像
                     ▼                                  ▼
              ┌──────────┐                       ┌──────────┐
              │ GitOps   │──────────────────────▶│   K8s    │
              │ 控制器    │    同步清单到集群       │  集群    │
              └──────────┘                       └──────────┘
```

## 思考题

1. 为什么在生产环境中不应该使用 `:latest` 镜像标签？如果使用了会有什么潜在问题？
2. 假设 CI 流水线直接运行 `kubectl apply`，这和通过 GitOps 工具间接部署相比，安全模型有什么区别？
3. 如果 CI 流水线在"推送镜像"阶段成功了，但"更新清单"阶段失败了，会发生什么？如何保证这两个阶段的一致性？
4. Skaffold 的 `dev` 模式和 `run` 模式有什么区别？分别适合什么场景？

---

**下一节：** [10.2 ArgoCD 与 GitOps](../02-argocd/README.md)
