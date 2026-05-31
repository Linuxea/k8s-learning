# 03 - Mutating Admission Webhook

## K8s API 请求的生命周期

当你执行 `kubectl apply -f pod.yaml` 时，请求会经历以下阶段：

```
kubectl → API Server
              │
              ▼
         ① Authentication（认证：你是谁？）
              │
              ▼
         ② Authorization（授权：你能做什么？）
              │
              ▼
         ③ Admission Control（准入控制：这个请求合理吗？）← 本节重点
              │
              ▼
         ④ 写入 etcd（持久化存储）
              │
              ▼
         ⑤ Scheduler → kubelet（调度并运行）
```

**Admission Control** 在认证和授权之后、数据持久化之前拦截请求。这是最后一道关卡。

## 准入控制的两个阶段

Admission Control 分为两个阶段，按顺序执行：

```
              API 请求
                 │
                 ▼
   ┌─────────────────────────┐
   │  Mutation（变更阶段）     │  可以修改对象
   │  多个 Mutating Webhook  │  按顺序执行
   │  每个都可以修改对象       │
   └────────────┬────────────┘
                │ 修改后的对象
                ▼
   ┌─────────────────────────┐
   │  Validation（验证阶段）  │  只能接受或拒绝
   │  多个 Validating Webhook│  并行执行
   │  不能修改对象            │
   └────────────┬────────────┘
                │
                ▼
              写入 etcd
```

| 阶段 | 能做什么 | 不能做什么 | 类比 |
|------|---------|-----------|------|
| **Mutation（变更）** | 修改对象的字段 | 不能拒绝请求 | 中间件改写请求 |
| **Validation（验证）** | 接受或拒绝请求 | 不能修改对象 | 门卫检查放行 |

> 为什么先 Mutate 再 Validate？因为 Validation 看到的是"修改后"的最终对象。如果顺序反了，Validator 可能检查的是旧数据。

## MutatingAdmissionWebhook 是什么

**MutatingAdmissionWebhook** 是 K8s 内置的一种 Admission Controller，它的工作方式是：

1. 当 API 请求到达时，K8s 把请求内容打包成 `AdmissionReview` 对象
2. 通过 HTTPS 发送给一个**外部 Webhook 服务器**
3. Webhook 服务器返回一个 `AdmissionResponse`，其中包含 **JSONPatch** 操作
4. K8s API Server 应用这些 patch，修改原始对象

```
  API Server                         Webhook Server
      │                                    │
      │── AdmissionReview ────────────────→│
      │   {                                │
      │     request: {                     │
      │       object: <原始Pod>            │
      │     }                              │── 解析 Pod
      │   }                                │── 构造 patch
      │                                    │
      │←── AdmissionResponse ─────────────│
      │   {                                │
      │     response: {                    │
      │       allowed: true,               │
      │       patch: <base64 JSONPatch>    │── 返回修改指令
      │     }                              │
      │   }                                │
      │                                    │
      │── 应用 patch，写入 etcd             │
```

## 常见的使用场景

Mutating Webhook 在生产环境中的应用非常广泛：

| 场景 | 说明 | 代表项目 |
|------|------|---------|
| **Sidecar 注入** | 自动给 Pod 注入 sidecar 容器 | Istio（注入 Envoy proxy） |
| **标签/注解注入** | 自动添加组织标签、环境标签 | 自定义 webhook |
| **默认资源限制** | 给没有设置 resources 的 Pod 设置默认值 | LimitRanger、Kyverno |
| **安全策略** | 强制设置 `runAsNonRoot`、`readOnlyRootFilesystem` | OPA Gatekeeper、Kyverno |
| **Service Account 注入** | 自动为特定工作负载绑定 ServiceAccount | 自定义 webhook |

## JSONPatch 修改机制

Webhook 通过 **JSONPatch**（RFC 6902）告诉 API Server 如何修改对象：

| 操作 | 含义 | 示例 |
|------|------|------|
| `add` | 添加字段 | 给 Pod 添加 label |
| `replace` | 替换字段值 | 修改 image pull policy |
| `remove` | 删除字段 | 移除某个注解 |

例如，给 Pod 添加一个 label `environment: production`：

```json
[
  {
    "op": "add",
    "path": "/metadata/labels/environment",
    "value": "production"
  }
]
```

这个 JSON 数组会被 base64 编码后放入 `AdmissionResponse.patch` 字段。

## Webhook 的安全要求

K8s API Server 通过 HTTPS 调用 webhook，因此有以下安全要求：

1. **TLS 证书**：webhook 服务器必须有合法的 TLS 证书
2. **CA Bundle**：MutatingWebhookConfiguration 中需要配置 `caBundle`，让 API Server 验证 webhook 的证书
3. **命名空间隔离**：通过 `namespaceSelector` 限制 webhook 的生效范围

> 生产环境推荐使用 [cert-manager](https://cert-manager.io/) 自动管理 webhook 的 TLS 证书。

## Step by Step：理解 Mutating Webhook

> 完整的 webhook 服务器需要编写代码（Go/Python 等）并构建镜像。本节侧重理解配置和流程，不涉及 webhook 代码开发。

### Step 1: 创建命名空间

```bash
# 创建用于 webhook 演示的命名空间
kubectl create namespace webhook-demo

# 给命名空间打标签，方便后续的 namespaceSelector 匹配
kubectl label namespace webhook-demo webhook=enabled
```

### Step 2: 查看 Webhook 配置

```bash
# 查看集群中已有的 MutatingWebhookConfiguration
kubectl get mutatingwebhookconfigurations

# 在一个全新的 kind 集群中，这个列表可能是空的
# 但如果你的集群安装了 Istio、Kyverno 等工具，你会看到它们的 webhook
```

### Step 3: 理解 Webhook 配置文件

```bash
# 查看本节的 webhook 配置
cat mutating-webhook-config.yaml
```

重点关注这些字段：

| 字段 | 含义 |
|------|------|
| `webhooks[].clientConfig.service` | webhook 服务器的地址（集群内的 Service） |
| `webhooks[].rules` | 触发条件：哪些资源、哪些操作会调用 webhook |
| `webhooks[].namespaceSelector` | 限制在哪些命名空间生效 |
| `webhooks[].failurePolicy` | webhook 不可用时的策略（Ignore/Fail） |
| `webhooks[].caBundle` | CA 证书，用于验证 webhook 的 TLS 证书 |

### Step 4: 理解 Webhook 服务架构

```bash
# 查看 webhook 服务配置
cat webhook-service.yaml
```

一个典型的 webhook 部署包含：

```
┌───────────────────────────────────────────────┐
│                K8s Cluster                    │
│                                               │
│  ┌───────────┐    ┌────────────────────────┐ │
│  │API Server │───→│  label-webhook-service │ │
│  └───────────┘    │  (ClusterIP:443)       │ │
│                   └──────────┬─────────────┘ │
│                              │                │
│                   ┌──────────▼─────────────┐ │
│                   │  label-webhook (Pod)   │ │
│                   │  - TLS 证书挂载         │ │
│                   │  - 接收 AdmissionReview│ │
│                   │  - 返回 JSONPatch      │ │
│                   └────────────────────────┘ │
└───────────────────────────────────────────────┘
```

### Step 5: 用 Kyverno 体验 Mutating（可选）

如果你想在集群中实际体验 mutating webhook 的效果，可以安装 [Kyverno](https://kyverno.io/)——一个策略引擎，它底层就是通过 Mutating/Validating Webhook 实现的：

```bash
# 安装 Kyverno（它自带 webhook 服务器）
kubectl apply -f https://github.com/kyverno/kyverno/releases/download/v1.12.0/install.yaml

# 等待 Kyverno Pod 就绪
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kyverno -n kyverno --timeout=120s

# 创建一个 ClusterPolicy：自动给所有 Pod 添加 label
cat <<EOF | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-label
spec:
  rules:
    - name: add-label
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              managed-by: kyverno-webhook
EOF

# 创建一个测试 Pod
kubectl run test-nginx --image=nginx:1.27

# 查看 Pod 的 label——你会看到自动注入的 managed-by=kyverno-webhook
kubectl get pod test-nginx -o jsonpath='{.metadata.labels}' | jq .

# 清理
kubectl delete pod test-nginx
kubectl delete clusterpolicy add-default-label
```

### Step 6: 清理

```bash
# 如果安装了 Kyverno
kubectl delete -f https://github.com/kyverno/kyverno/releases/download/v1.12.0/install.yaml

# 清理命名空间
kubectl delete namespace webhook-demo
```

## Mutating Webhook 的注意事项

| 注意事项 | 说明 |
|----------|------|
| **性能影响** | 每次 API 请求都会调用 webhook，延迟增加。设置合理的 `timeoutSeconds` |
| **可用性** | webhook 不可用时，`failurePolicy: Fail` 会阻止所有资源创建！ |
| **调试困难** | webhook 修改是"隐式"的，用户看不到原始 YAML 被改了什么。用 `kubectl get -o yaml` 查看最终结果 |
| **顺序依赖** | 多个 mutating webhook 按字母顺序执行，前面的修改会影响后面的输入 |
| **命名空间排除** | 始终排除 `kube-system` 等系统命名空间，避免 webhook 影响 K8s 组件 |

> `failurePolicy` 是一个关键配置。如果你在 `kube-system` 中启用了 `Fail` 策略的 webhook，一旦 webhook 挂了，整个集群可能无法调度新 Pod。

## 思考题

1. 如果一个 Mutating Webhook 不可用且 `failurePolicy: Fail`，创建 Pod 会发生什么？这对集群有什么影响？
2. 为什么 Mutating Webhook 必须通过 HTTPS（TLS）通信？如果用 HTTP 会有什么安全风险？
3. 多个 Mutating Webhook 的执行顺序是什么？如果一个 webhook 添加的字段被另一个 webhook 删除了，会怎样？
4. 如果你想给所有 Pod 自动注入一个 sidecar 容器（如日志采集 agent），应该用 Mutating 还是 Validating Webhook？为什么？

---

上一个 → [02 - Operator 模式](../02-operator-pattern/)　｜　下一个 → [04 - Validating Admission Webhook](../04-validating-admission/)
