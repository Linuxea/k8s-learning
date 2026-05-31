# 07-01 Helm 入门：第一个 Chart

## 什么是 Helm？

如果把 Kubernetes 比作一台服务器，那 **Helm 就是 Kubernetes 的包管理器**——类似于 Ubuntu 的 `apt`、CentOS 的 `yum`、macOS 的 `brew`。

为什么需要包管理器？因为一个真实的应用往往不只是一个 Deployment：

> 一个典型的 Web 应用可能包含：Deployment、Service、ConfigMap、Secret、Ingress、PersistentVolumeClaim……十几个 YAML 文件互相依赖，手动用 `kubectl apply` 一个个部署既容易出错，又难以管理版本和升级。

Helm 把这些 YAML 打包成一个 **Chart**，一条命令就能完成安装、升级、回滚和卸载。

## 核心概念

| 概念 | 类比 | 说明 |
|------|------|------|
| **Chart** | `.deb` / `.rpm` 包 | 一个应用的打包格式，包含所有 K8s 资源模板和默认配置 |
| **Release** | 已安装的软件实例 | Chart 的一次安装运行实例，同一个 Chart 可以安装多次 |
| **Repository** | apt 源 / yum 源 | 存放和分发 Chart 的 HTTP 服务器 |
| **values.yaml** | 配置文件 | Chart 的可定制参数，安装时可以覆盖 |

### Helm vs kubectl apply

| 对比项 | `kubectl apply -f` | Helm |
|--------|-------------------|------|
| 模板化 | 需要外部工具（envsubst、sed） | 内置 Go template 引擎 |
| 版本管理 | 无（需要自己用 git 管理） | 内置 Release 版本，支持回滚 |
| 依赖管理 | 无 | Chart 支持声明依赖子 Chart |
| 配置覆盖 | 需要准备多套 YAML | `--set` 或 `-f values.yaml` 灵活覆盖 |
| 卸载 | 需要手动删除每个资源 | `helm uninstall` 一键清理 |

> **一句话总结**：`kubectl apply` 是"手动挡"，Helm 是"自动挡"。不是取代关系，Helm 底层仍然调用 K8s API 创建资源。

## Chart 目录结构

```
my-first-chart/
├── Chart.yaml          # Chart 元数据（名称、版本、描述）
├── values.yaml         # 默认配置值（模板变量的默认值）
├── .helmignore         # 打包时忽略的文件（类似 .gitignore）
└── templates/          # K8s 资源模板目录
    ├── deployment.yaml
    ├── service.yaml
    ├── _helpers.tpl     # 可复用的模板片段（命名模板）
    └── NOTES.txt        # 安装后显示的提示信息
```

### 关键文件说明

| 文件 | 作用 | 是否必须 |
|------|------|---------|
| `Chart.yaml` | 声明 Chart 的名称、版本、appVersion 等元数据 | 是 |
| `values.yaml` | 提供模板变量的默认值 | 是（可以为空） |
| `templates/` | 存放 K8s 资源的 Go template 文件 | 是 |
| `templates/NOTES.txt` | `helm install` 成功后打印的使用说明 | 否（推荐） |
| `.helmignore` | 指定 `helm package` 时排除的文件 | 否 |

## 实战：创建并安装第一个 Chart

### 前提条件

- 已有 kind 创建的 3 节点集群（1 control-plane + 2 worker）
- 已安装 kubectl 并能连接集群

### 第一步：安装 Helm

```bash
# macOS
brew install helm

# Linux (官方安装脚本)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 验证安装
helm version
# 输出类似: version.BuildInfo{Version:"v3.14.0", ...}
```

### 第二步：用 helm create 生成 Chart 骨架

```bash
# 在本章目录下创建
cd chapter07-helm/01-first-chart
helm create my-first-chart
```

> `helm create` 会生成一个包含 nginx 的完整 Chart 示例，包括 Deployment、Service、Ingress、HPA 等。对于初学者来说内容偏多，我们后面会用精简版本演示。

### 第三步：理解生成的结构

我们先看 `helm create` 生成的核心文件（精简版在 `my-first-chart/` 目录中）：

**Chart.yaml** — Chart 的身份信息：

```yaml
apiVersion: v2              # Chart API 版本（v2 对应 Helm 3）
name: my-first-chart        # Chart 名称
description: A Helm chart for Kubernetes
type: application           # application（可部署）或 library（可复用模板）
version: 0.1.0              # Chart 自身的版本（每次修改 Chart 内容时递增）
appVersion: "1.16.0"        # 包含的应用版本（如 nginx 的版本，仅作信息展示）
```

> `version` 和 `appVersion` 的区别：`version` 是 Chart 打包格式自身的版本，`appVersion` 是里面运行的应用的版本。两者独立递增。

**values.yaml** — 默认配置（精简版）：

```yaml
replicaCount: 1

image:
  repository: nginx         # 镜像仓库地址
  pullPolicy: IfNotPresent  # 拉取策略：本地有就不拉
  tag: ""                   # 为空时使用 Chart.yaml 的 appVersion

service:
  type: ClusterIP           # Service 类型
  port: 80                  # Service 端口
```

### 第四步：安装 Chart

```bash
# 安装并指定 release 名称
helm install my-release ./my-first-chart

# 查看 release 状态
helm status my-release

# 查看 K8s 中创建的资源
kubectl get all -l app.kubernetes.io/instance=my-release
```

`helm install` 做了什么：
1. 读取 `values.yaml` 获取默认值
2. 将 `templates/` 中的模板与 values 合并渲染成最终 YAML
3. 调用 K8s API 创建资源
4. 打印 `NOTES.txt` 的渲染结果

### 第五步：查看渲染结果（不安装）

```bash
# --debug --dry-run 只渲染模板不真正部署，调试利器
helm install my-release ./my-first-chart --dry-run --debug
```

> **开发技巧**：写模板时反复用 `--dry-run` 检查渲染结果，确认无误后再真正安装。

### 第六步：升级 Release

修改 `values.yaml` 中的 `replicaCount: 2`，然后：

```bash
# 升级已有 release
helm upgrade my-release ./my-first-chart

# 查看升级历史
helm history my-release

# 确认副本数已变化
kubectl get deployment -l app.kubernetes.io/instance=my-release
```

### 第七步：回滚 Release

```bash
# 回滚到上一个版本
helm rollback my-release 1

# 再次查看历史，会发现多了一条 rollback 记录
helm history my-release
```

### 第八步：卸载 Release

```bash
# 卸载 release（会删除所有由该 release 创建的 K8s 资源）
helm uninstall my-release

# 验证资源已被清理
kubectl get all -l app.kubernetes.io/instance=my-release
# No resources found
```

## 实用 Helm 命令速查

| 命令 | 作用 |
|------|------|
| `helm install <name> <chart>` | 安装 Chart |
| `helm upgrade <name> <chart>` | 升级 Release |
| `helm upgrade --install <name> <chart>` | 安装或升级（幂等操作，推荐） |
| `helm uninstall <name>` | 卸载 Release |
| `helm list` | 列出所有 Release |
| `helm status <name>` | 查看 Release 状态 |
| `helm history <name>` | 查看 Release 版本历史 |
| `helm rollback <name> <revision>` | 回滚到指定版本 |
| `helm template <chart>` | 本地渲染模板（不连集群） |
| `helm install --dry-run --debug` | 渲染 + 调试信息（连集群） |

## 思考题

1. 如果同一个 Chart 分别安装到 `default` 和 `staging` 两个 namespace，它们共享同一份资源还是完全独立？为什么？
2. `helm upgrade` 和 `helm install` 在底层调用的 K8s API 有什么区别？（提示：一个是 Create，一个是 Patch/Replace）
3. 如果 `helm uninstall` 执行到一半失败了（部分资源已删除，部分未删除），Release 会处于什么状态？如何恢复？
4. 为什么 `Chart.yaml` 中的 `version` 字段要遵循语义化版本（SemVer）？如果随便写一个字符串会怎样？

---

[下一节：02-Chart Values 模板化 →](../02-chart-values/README.md)
