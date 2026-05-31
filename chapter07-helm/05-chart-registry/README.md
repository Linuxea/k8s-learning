# 07-05 Chart 仓库与发布

## 为什么需要 Chart 仓库？

经过前四节的学习，你已经能写 Chart 了。但 Chart 写好之后怎么分发给别人？

- **个人开发**：直接用本地路径 `helm install ./my-chart`
- **团队协作**：需要一个集中存储的地方，大家都能 `helm install my-chart`
- **开源社区**：需要一个公开的目录，让全世界都能搜索和安装

**Chart 仓库就是解决这个问题的基础设施**——类似 Docker Hub 之于 Docker 镜像、npm 之于 Node.js 包。

## 两种 Chart 存储方式

| 方式 | 协议 | 存储内容 | 适合场景 |
|------|------|---------|---------|
| **传统 Chart 仓库** | HTTP | `index.yaml` + `.tgz` 包 | 自建仓库、简单场景 |
| **OCI 注册表** | OCI（类似 Docker Registry） | Chart 作为 OCI Artifact | 已有容器注册表的企业 |

## 传统 Chart 仓库

### 工作原理

传统 Chart 仓库本质上就是一个 **HTTP 服务器**，上面放两个东西：

1. **`index.yaml`**：索引文件，列出所有 Chart 的名称、版本、描述、下载 URL 和 SHA256 校验和
2. **`.tgz` 文件**：打包好的 Chart 压缩包

```
charts.example.com/
├── index.yaml                          # 索引文件
├── my-chart-0.1.0.tgz                  # Chart 包
├── my-chart-0.2.0.tgz
└── another-chart-1.0.0.tgz
```

### helm package：打包 Chart

```bash
# 将 Chart 目录打包成 .tgz 文件
helm package ./packaged-chart
# 输出：packaged-chart-0.1.0.tgz
# 文件名格式：<chart-name>-<chart-version>.tgz

# 指定输出目录
helm package ./packaged-chart -d ./dist/
```

> **打包做了什么**：读取 `Chart.yaml` 中的 `name` 和 `version`，将 Chart 目录（排除 `.helmignore` 中的文件）压缩成 `.tgz` 文件。

### helm repo：管理仓库

```bash
# 添加仓库
helm repo add bitnami https://charts.bitnami.com/bitnami

# 查看已添加的仓库
helm repo list

# 更新仓库索引（拉取最新的 index.yaml）
helm repo update

# 搜索仓库中的 Chart
helm search repo bitnami/nginx
# 输出：名称、版本、appVersion、描述

# 搜索所有仓库（包括 Helm Hub）
helm search hub nginx
# 从 https://hub.helm.sh 搜索公开 Chart
```

### 搭建本地仓库

```bash
# 方法一：使用 helm serve（已在新版移除，仅作了解）
# 在指定目录启动 HTTP 服务器，自动生成 index.yaml
# helm serve --repo-path ./my-repo

# 方法二：手动搭建（推荐）

# 1. 创建仓库目录
mkdir -p ./my-repo

# 2. 打包 Chart 并移动到仓库目录
helm package ./packaged-chart -d ./my-repo/

# 3. 生成索引文件
helm repo index ./my-repo/
# 会在 ./my-repo/ 下生成 index.yaml

# 4. 用任意 HTTP 服务器托管（Python 一行命令）
cd ./my-repo && python3 -m http.server 8080

# 5. 在另一个终端添加本地仓库
helm repo add my-local http://localhost:8080

# 6. 搜索和安装
helm search repo my-local
helm install my-app my-local/packaged-chart
```

### helm repo index：生成索引

`helm repo index` 扫描目录下所有 `.tgz` 文件，生成或更新 `index.yaml`：

```bash
# 基本用法
helm repo index ./my-repo/

# 合并已有索引（增量更新）
helm repo index ./my-repo/ --url https://charts.example.com --merge ./my-repo/index.yaml
```

`index.yaml` 的结构：

```yaml
apiVersion: v1
entries:
  packaged-chart:
    - name: packaged-chart
      version: 0.1.0
      description: A ready-to-package Helm chart
      urls:
        - https://charts.example.com/packaged-chart-0.1.0.tgz
      digest: "sha256:abc123..."
      created: "2024-01-01T00:00:00Z"
```

## OCI 注册表

### 什么是 OCI？

OCI（Open Container Initiative）是容器镜像的标准规范。Helm 3 支持将 Chart 作为 OCI Artifact 推送到 **OCI 兼容的注册表**（如 Docker Hub、GitHub Container Registry、 Harbor 等）。

这意味着你可以**用管理 Docker 镜像的方式管理 Helm Chart**——同一个注册表既能存镜像又能存 Chart。

### OCI vs 传统仓库

| 对比项 | 传统 HTTP 仓库 | OCI 注册表 |
|--------|---------------|-----------|
| 协议 | HTTP/HTTPS | OCI Distribution（基于 HTTP） |
| 认证 | Basic Auth / TLS | Bearer Token（和 Docker 一样） |
| 存储 | 文件系统 | Blob 存储（和镜像一样） |
| 推送方式 | 手动上传 .tgz | `helm push` |
| 拉取方式 | `helm install` / `helm pull` | `helm pull` / `helm install` |
| 搜索 | `helm search repo` | `helm show`（暂不支持 search） |
| 镜像复用 | 需要单独的 Chart 仓库 | 复用已有的 Container Registry |

### 使用 OCI 注册表

```bash
# 1. 登录注册表（和 docker login 一样）
helm registry login registry.example.com -u myuser

# 2. 打包 Chart
helm package ./packaged-chart

# 3. 推送到 OCI 注册表
helm push packaged-chart-0.1.0.tgz oci://registry.example.com/my-charts
# oci:// 前缀表示使用 OCI 协议
# my-charts 是注册表中的仓库（repository）名

# 4. 从 OCI 注册表拉取
helm pull oci://registry.example.com/my-charts/packaged-chart --version 0.1.0

# 5. 直接从 OCI 注册表安装（无需先添加 repo）
helm install my-app oci://registry.example.com/my-charts/packaged-chart --version 0.1.0

# 6. 查看Chart信息
helm show all oci://registry.example.com/my-charts/packaged-chart --version 0.1.0
```

> **OCI 地址格式**：`oci://<registry-host>/<path>/<chart-name>`。注意没有 `https://`，以 `oci://` 开头。

### 使用 GitHub Container Registry（GHCR）

```bash
# 登录 GHCR（使用 GitHub Personal Access Token）
echo $GITHUB_TOKEN | helm registry login ghcr.io -u USERNAME --password-stdin

# 推送到 GHCR
helm push packaged-chart-0.1.0.tgz oci://ghcr.io/myorg/charts

# 从 GHCR 安装
helm install my-app oci://ghcr.io/myorg/charts/packaged-chart --version 0.1.0
```

## 语义化版本（Semantic Versioning）

Helm 要求 `Chart.yaml` 中的 `version` 字段遵循 [SemVer 2](https://semver.org/)：

```
MAJOR.MINOR.PATCH
  |     |     |
  |     |     └── 修复 bug，不改变 API
  |     └──────── 新增功能，向后兼容
  └────────────── 破坏性变更，不兼容旧版本
```

### 版本规则示例

| 版本变化 | 含义 | 用户升级风险 |
|---------|------|------------|
| 0.1.0 → 0.1.1 | 修复了模板 Bug | 低 |
| 0.1.1 → 0.2.0 | 新增了可选功能 | 低-中 |
| 0.2.0 → 1.0.0 | 改变了 values 结构 | 高（需要迁移） |
| 1.0.0 → 2.0.0 | 重构了模板结构 | 高（需要重写覆盖） |

> **重要**：在 SemVer 中，`0.x.x` 版本被认为是"初始开发阶段"，允许做不兼容的变更。一旦发布 `1.0.0`，就必须遵守向后兼容的承诺。

### Chart 版本 vs 应用版本

```yaml
# Chart.yaml
version: 0.3.0        # Chart 版本——模板/values 结构的版本
appVersion: "1.27.0"  # 应用版本——里面跑的 nginx 的版本
```

它们独立变化：
- 改了模板逻辑但 nginx 版本没变 → 只升 `version`
- nginx 升级到 1.28.0 但模板没改 → 只升 `appVersion`
- 两者都变了 → 两个都升

## 实战：打包与发布

### 第一步：打包 Chart

```bash
cd chapter07-helm/05-chart-registry

# 打包
helm package ./packaged-chart
# 输出：Successfully packaged chart and saved it to: packaged-chart-0.1.0.tgz

# 查看包内容
tar -tzf packaged-chart-0.1.0.tgz
```

### 第二步：搭建本地仓库

```bash
# 创建仓库目录
mkdir -p ./my-repo

# 打包到仓库目录
helm package ./packaged-chart -d ./my-repo/

# 生成索引
helm repo index ./my-repo/

# 启动 HTTP 服务器
cd ./my-repo && python3 -m http.server 8080
```

### 第三步：从本地仓库安装

```bash
# 在另一个终端
helm repo add my-local http://localhost:8080
helm repo update
helm search repo my-local

# 安装
helm install from-repo my-local/packaged-chart

# 验证
kubectl get pods -l app.kubernetes.io/instance=from-repo
```

### 第四步：模拟 OCI 推送（使用本地 Docker Registry）

```bash
# 启动本地 Docker Registry（如果还没运行）
docker run -d -p 5000:5000 --name registry registry:2

# 推送 Chart 到本地 OCI 注册表
helm push packaged-chart-0.1.0.tgz oci://localhost:5000/my-charts

# 从 OCI 注册表安装
helm install from-oci oci://localhost:5000/my-charts/packaged-chart --version 0.1.0
```

### 第五步：版本升级与发布流程

```bash
# 1. 修改 Chart（如增加副本数）
# 2. 更新 Chart.yaml 中的 version（如 0.1.0 → 0.2.0）
# 3. 重新打包
helm package ./packaged-chart -d ./my-repo/

# 4. 重新生成索引
helm repo index ./my-repo/

# 5. 用户端更新
helm repo update
helm upgrade from-repo my-local/packaged-chart
```

## Chart 发布清单

发布一个正式 Chart 前，检查以下事项：

| 检查项 | 命令 |
|--------|------|
| 模板渲染无误 | `helm template ./chart` |
| 可以成功安装 | `helm install --dry-run test ./chart` |
| Lint 通过 | `helm lint ./chart` |
| 版本号已更新 | 检查 `Chart.yaml` 的 `version` |
| CHANGELOG 已写 | 记录本次版本的变更内容 |
| 打包成功 | `helm package ./chart` |
| 索引已更新 | `helm repo index` |

## 思考题

1. OCI 注册表和传统 HTTP 仓库的核心区别是什么？在什么场景下你会选择 OCI？
2. 如果你的团队已有 Harbor 作为容器镜像仓库，如何复用它来存储 Helm Chart？具体操作步骤是什么？
3. 为什么 Helm 要求 Chart 版本遵循 SemVer？如果 `version` 字段随便写（如 `"latest"`），`helm dependency update` 会出什么问题？
4. 设计一个 CI/CD 流水线：当你修改 Chart 并推送到 Git 后，如何自动打包、测试、发布到 OCI 注册表？

---

[← 上一节：04-Chart Hook](../04-chart-hook/README.md) | [回到目录 ↑](../)
