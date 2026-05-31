# 05 - Pod Security Admission：集群级安全策略

## 从 PodSecurityPolicy 到 Pod Security Admission

Kubernetes 的 Pod 安全策略经历了一次重要的演变：

```
PodSecurityPolicy (PSP)          Pod Security Standards (PSS)
v1.0 - v1.25                    v1.22+
  ↓                                ↓
已移除 (v1.25)                  Pod Security Admission (PSA)
                               v1.23+ (稳定版 v1.25+)
```

### PodSecurityPolicy（已移除）

PSP 是早期的安全方案（v1.25 中移除），它的问题：

| 问题 | 说明 |
|------|------|
| 难以使用 | 需要为每个用户/ServiceAccount 创建 RoleBinding，配置复杂 |
| 默认不安全 | 没有匹配到 PSP 的 Pod 不受任何限制 |
| 顺序敏感 | 授权的 PSP 列表顺序影响结果，行为不可预测 |
| 升级困难 | 修改 PSP 可能影响大量已有的工作负载 |

### Pod Security Admission（当前方案）

PSA 是 PSP 的替代方案，设计理念完全不同：

| 特性 | PSP | PSA |
|------|-----|-----|
| 配置方式 | 创建 PSP 资源 + RBAC | 命名空间标签 |
| 复杂度 | 高 | 低 |
| 作用范围 | 按 ServiceAccount | 按命名空间 |
| 默认行为 | 不限制 | 可以设置默认限制 |
| 状态 | 已移除 | 稳定版 |

> PSA 的核心思路：**在命名空间级别设置安全标准，而不是给每个 ServiceAccount 单独配置**。这大大简化了管理。

## 三个安全标准级别

Kubernetes 定义了三个递进的安全级别：

### Privileged（特权）

完全不做限制，允许一切。适用于：

- 系统级 Pod（kube-proxy、CNI 插件等）
- 需要访问宿主机硬件的 Pod
- 特殊的管理工具

### Baseline（基线）

禁止明显危险的配置，允许基本的容器运行。禁止的项目包括：

| 禁止项 | 说明 |
|--------|------|
| hostNetwork / hostPID / hostIPC | 共享宿主机命名空间 |
| hostPort | 使用宿主机端口 |
| 特权容器（privileged: true） | 完全访问宿主机设备 |
| 危险的 Volume 类型 | hostPath、nfs 等未限制的挂载 |
| 危险的 capabilities | NET_RAW 以外的"非标准"能力 |
| /proc mount 类型 | 非默认的 proc 挂载 |

### Restricted（受限）

最严格，遵循安全最佳实践。在 Baseline 基础上额外要求：

| 要求 | 说明 |
|------|------|
| 必须非 root 运行 | `runAsNonRoot: true` 或镜像设置了非 root USER |
| 不能提权 | `allowPrivilegeEscalation: false` |
| 丢弃所有能力 | `capabilities.drop` 包含 `ALL` |
| 限制 Volume 类型 | 只允许 configMap、emptyDir、projected、secret、persistentVolumeClaim 等 |
| Seccomp profile | 必须使用 RuntimeDefault 或 Localhost |

```
Privileged（无限制）
    │
    │  禁止明显危险的配置
    ▼
Baseline（基本安全）
    │
    │  要求遵循安全最佳实践
    ▼
Restricted（高度安全）
```

> 选择哪个级别？系统 Pod 用 Privileged，普通应用用 Baseline，安全要求高的用 Restricted。大多数应用应该能跑在 Baseline 下。

## 三种执行模式

PSA 提供三种模式来执行安全标准：

| 模式 | 行为 | 使用场景 |
|------|------|---------|
| **enforce** | 违规 Pod 被拒绝创建 | 生产环境强制执行 |
| **audit** | Pod 可以创建，但在审计日志中记录 | 评估影响，准备上线 |
| **warn** | Pod 可以创建，但 kubectl 输出警告 | 提醒开发者修复 |

三种模式可以独立配置：

```bash
# 命名空间标签格式
pod-security.kubernetes.io/<MODE>: <LEVEL>

# 例子：enforce 用 restricted，audit 和 warn 也用 restricted
pod-security.kubernetes.io/enforce: restricted
pod-security.kubernetes.io/audit: restricted
pod-security.kubernetes.io/warn: restricted
```

> **推荐策略**：先用 `warn: restricted` 观察影响，确认没问题后再改为 `enforce: restricted`。这样不会破坏现有工作负载。

## 版本标签

除了模式和级别，PSA 标签还可以指定 Kubernetes 版本：

```bash
pod-security.kubernetes.io/enforce-version: v1.31
```

这确保了安全标准与你预期的 K8s 版本一致。当集群升级后，安全标准不会自动跟随变化（避免意外）。如果不设置，默认使用 kube-apiserver 的版本。

## Step by Step：Pod Security Admission 实验

### Step 1: 创建带 PSA 标签的命名空间

```bash
kubectl apply -f restricted-namespace.yaml

# 查看命名空间标签
kubectl get namespace psa-demo --show-labels
# NAME       STATUS   AGE   LABELS
# psa-demo   Active   10s   kubernetes.io/metadata.name=psa-demo,pod-security.kubernetes.io/audit-version=latest,...
```

### Step 2: 尝试创建违规 Pod（应该被拒绝）

```bash
kubectl apply -f privileged-pod.yaml -n psa-demo

# 输出类似：
# Error from server (Forbidden): error when creating "privileged-pod.yaml":
# pods "privileged-pod" is forbidden: violates PodSecurity "restricted:latest":
# ...
# - runAsNonRoot != true (pod must not run as root)
# - allowPrivilegeEscalation != false
#   (container "nginx" must set securityContext.allowPrivilegeEscalation=false)
# - unrestricted capabilities
#   (container "nginx" must set securityContext.capabilities.drop=["ALL"])
```

> 注意错误信息的详细程度——PSA 会告诉你具体哪项不符合要求，非常便于修复。

### Step 3: 创建合规 Pod（应该成功）

```bash
kubectl apply -f compliant-pod.yaml -n psa-demo

# 成功！没有任何错误
# Pod creation succeeded
```

### Step 4: 验证 Pod 状态

```bash
kubectl get pods -n psa-demo
# NAME            READY   STATUS    RESTARTS   AGE
# compliant-pod   1/1     Running   0          10s
```

### Step 5: 测试 warn 模式

创建一个只用 warn 模式的命名空间，违规 Pod 可以创建但会有警告：

```bash
# 创建 warn-only 命名空间
kubectl create namespace psa-warn-demo
kubectl label namespace psa-warn-demo pod-security.kubernetes.io/warn=restricted

# 尝试创建违规 Pod（会有警告但不会阻止）
kubectl apply -f privileged-pod.yaml -n psa-warn-demo

# 输出类似：
# Warning: would violate PodSecurity "restricted:latest": ...
# pod/privileged-pod created

# Pod 实际上被创建了
kubectl get pods -n psa-warn-demo
# NAME             READY   STATUS    RESTARTS   AGE
# privileged-pod   1/1     Running   0          5s
```

> `warn` 模式非常有用：它不阻止部署，但会告诉开发者"这个 Pod 不符合安全标准，需要修复"。是一种渐进式推进安全策略的方式。

### Step 6: 查看命名空间的安全标签

```bash
# 查看所有带 PSA 标签的命名空间
kubectl get namespaces --show-labels | grep pod-security

# 查看具体命名空间的详细标签
kubectl describe namespace psa-demo | grep -A5 Labels
```

### Step 7: 清理

```bash
kubectl delete namespace psa-demo
kubectl delete namespace psa-warn-demo
```

## 为现有命名空间添加 PSA 标签

在生产环境中，你可能需要给已有的命名空间添加 PSA 标签：

```bash
# 给 default 命名空间添加 warn 模式（安全，不会阻止任何东西）
kubectl label namespace default pod-security.kubernetes.io/warn=restricted

# 给 kube-system 保持 Privileged（系统 Pod 需要特权）
kubectl label namespace kube-system pod-security.kubernetes.io/enforce=privileged

# 给生产环境命名空间添加 enforce
kubectl label namespace production pod-security.kubernetes.io/enforce=baseline
kubectl label namespace production pod-security.kubernetes.io/audit=restricted
kubectl label namespace production pod-security.kubernetes.io/warn=restricted
```

> `kube-system` 命名空间**必须**设为 `privileged`，否则系统组件（如 CoreDNS、kube-proxy）将无法运行。

## 查看哪些 Pod 违反了安全标准

```bash
# 用 kubectl 的 --dry-run=server 模拟创建，检查是否符合标准
kubectl apply -f my-pod.yaml --dry-run=server -n psa-demo

# 或者用 kubectl debug 的 --pod-running-as-root 检查
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.containers[].securityContext == null) | .metadata.name'
```

## PSA 和 Security Context 的关系

PSA 和 Security Context 是**互补**的：

```
┌─────────────────────────────────────────────────┐
│         Pod Security Admission (PSA)             │
│         命名空间级别的"门卫"                       │
│         检查 Pod 是否符合安全标准                  │
│         不符合 → 拒绝/警告/审计                    │
└─────────────────────┬───────────────────────────┘
                      │ 通过检查
                      ▼
┌─────────────────────────────────────────────────┐
│         Security Context                         │
│         Pod/容器级别的具体安全配置                  │
│         定义运行身份、能力、文件系统等              │
└─────────────────────────────────────────────────┘
```

- **PSA**：决定"什么样的 Pod **可以**运行"（准入控制）
- **Security Context**：决定"Pod **怎样**运行"（运行时配置）

PSA 检查的很多项目就是 Security Context 的字段。要满足 `restricted` 级别，Pod 必须正确配置 Security Context。

## 版本兼容性

| Kubernetes 版本 | PSA 状态 |
|----------------|---------|
| < v1.22 | 不支持，只能用 PSP |
| v1.22 - v1.24 | PSA 可用（beta），PSP 也可用 |
| v1.25+ | PSA 稳定版，PSP 已移除 |
| v1.31+（kind 默认） | PSA 完全可用 |

## 关键概念总结

| 概念 | 要点 |
|------|------|
| PSP | 已废弃（v1.25 移除），不要使用 |
| PSS | Pod Security Standards，三个安全级别定义 |
| PSA | Pod Security Admission，基于命名空间标签的准入控制 |
| Privileged | 最宽松，不限制 |
| Baseline | 基本安全，禁止明显危险配置 |
| Restricted | 最严格，要求安全最佳实践 |
| enforce | 违规拒绝 |
| audit | 违规记录审计日志 |
| warn | 违规发出警告 |
| 配置方式 | 命名空间标签 `pod-security.kubernetes.io/<mode>: <level>` |

> **最佳实践**：新创建的集群应该从一开始就设置 PSA 标签。先用 `warn` 模式观察，确认无问题后切换到 `enforce`。系统命名空间（kube-system）设为 `privileged`，应用命名空间设为 `baseline` 或 `restricted`。

## 思考题

1. 为什么 Kubernetes 社区决定移除 PSP 而用 PSA 替代？PSA 解决了 PSP 的哪些痛点？
2. `enforce: restricted` 和 `enforce: baseline` 的区别是什么？在什么情况下你会选择 `baseline` 而不是 `restricted`？
3. 如果你的命名空间设置了 `enforce: restricted`，但有一个 Pod 必须以 root 运行（比如某个旧应用），你会怎么处理？
4. 为什么推荐先使用 `warn` 模式再切换到 `enforce`？直接用 `enforce` 有什么风险？

---

[回到目录](../../)
