# 04 - Validating Admission Webhook

## 从 Mutation 到 Validation

上一节我们学习了 Mutating Webhook——它可以在 API 请求写入 etcd 之前**修改**对象。这一节来看 Validating Webhook——它只能**接受或拒绝**请求。

两者的关系：

```
   API 请求（原始对象）
        │
        ▼
   ┌─────────────┐
   │  Mutation    │  修改对象（可能多次）
   └──────┬──────┘
          │  修改后的对象
          ▼
   ┌─────────────┐
   │  Validation  │  接受 or 拒绝（不可修改）
   └──────┬──────┘
          │
     允许 → 写入 etcd
     拒绝 → 返回错误给用户
```

> **为什么需要 Validation？** 有些策略是硬性约束，不应该被"绕过"。比如"所有 Pod 必须设置资源限制"——这不是建议，是规定。Validating Webhook 就是执行这些规定的"执法者"。

## Validating vs Mutating：对比

| 特性 | Mutating Webhook | Validating Webhook |
|------|-----------------|-------------------|
| **能力** | 修改对象字段 | 只能接受或拒绝 |
| **返回** | JSONPatch + allowed | allowed (true/false) |
| **执行顺序** | 先执行 | 后执行（看到修改后的对象） |
| **执行方式** | 多个 webhook 按序执行 | 多个 webhook 并行执行 |
| **典型场景** | 注入 sidecar、添加标签、设置默认值 | 策略执行、命名规范、安全约束 |

## 常见的使用场景

Validating Webhook 在生产环境中用于执行各种合规策略：

| 场景 | 说明 | 示例策略 |
|------|------|---------|
| **强制资源限制** | 所有 Pod 必须设置 CPU/Memory limits | 防止资源饥饿 |
| **禁止特权容器** | 不允许 `privileged: true` | 安全合规 |
| **命名规范** | 资源名必须符合团队命名规则 | 组织管理 |
| **镜像来源限制** | 只允许从受信任的镜像仓库拉取 | 供应链安全 |
| **标签/注解检查** | 必须包含特定的标签（如 owner、team） | 成本分摊、审计 |
| **禁止 latest 标签** | 镜像标签不能是 `latest` | 可重复部署 |

## 工作流程详解

```
  用户: kubectl apply -f pod.yaml
        │
        ▼
  API Server 接收请求
        │
        ▼
  Authentication + Authorization
        │
        ▼
  ┌──────────────────────────────────────┐
  │        Admission Control             │
  │                                      │
  │  1. Mutating Webhooks (按序执行)      │
  │     → 可能修改了 Pod                  │
  │                                      │
  │  2. Validating Webhooks (并行执行)    │
  │     → webhook A: allowed=true  ✅    │
  │     → webhook B: allowed=true  ✅    │
  │     → webhook C: allowed=false ❌    │
  │                                      │
  │  只要有一个拒绝 → 整个请求被拒绝       │
  └──────────────────────────────────────┘
        │
        │ 全部通过
        ▼
      写入 etcd
```

关键规则：**所有 Validating Webhook 都必须通过**（返回 `allowed: true`），只要有一个拒绝，请求就被拒绝。

## Webhook 服务器处理逻辑

Validating Webhook 服务器收到 `AdmissionReview` 后的处理逻辑（伪代码）：

```python
def validate(admission_review):
    pod = admission_review.request.object
    
    # 检查每个容器是否设置了资源限制
    for container in pod.spec.containers:
        if not container.resources:
            return AdmissionResponse(
                allowed=False,
                status="Container '{}' must have resource limits".format(container.name)
            )
        
        if not container.resources.limits:
            return AdmissionResponse(
                allowed=False,
                status="Container '{}' must have resource.limits set".format(container.name)
            )
    
    # 所有检查通过
    return AdmissionResponse(allowed=True)
```

> 注意 Validating Webhook 的返回值只有 `allowed: true` 或 `allowed: false`，没有 patch 字段。

## Step by Step：理解 Validating Webhook

### Step 1: 查看集群中的 Validating Webhook

```bash
# 查看集群中已有的 ValidatingWebhookConfiguration
kubectl get validatingwebhookconfigurations

# 在全新的 kind 集群中，列表可能为空
# 安装了 Istio/Kyverno/Gatekeeper 等工具后会出现对应的配置
```

### Step 2: 理解配置文件

```bash
# 查看 Validating Webhook 配置
cat validating-webhook-config.yaml
```

与 Mutating Webhook 的关键区别：

| 配置项 | Mutating | Validating |
|--------|----------|------------|
| `kind` | `MutatingWebhookConfiguration` | `ValidatingWebhookConfiguration` |
| `webhook path` | 通常是 `/mutate` | 通常是 `/validate` |
| `failurePolicy` | 常用 `Ignore` | 常用 `Fail` |

> 对于安全策略（如禁止特权容器），`failurePolicy` 通常设为 `Fail`——宁可阻止创建，也不能放过不合规的 Pod。

### Step 3: 理解策略示例

```bash
# 查看策略示例文件
cat policy-example.yaml
```

文件中包含三种情况：

| Pod | 是否合规 | 原因 |
|-----|---------|------|
| `compliant-pod` | 合规 | 设置了 `resources.requests` 和 `resources.limits` |
| `non-compliant-pod` | 不合规 | 完全没有 `resources` 字段 |
| `partial-compliant-pod` | 可能不合规 | 只设置了 `limits`，没设置 `requests`（取决于策略严格程度） |

### Step 4: 用 OPA Gatekeeper 体验验证（可选）

OPA Gatekeeper 是一个基于 Validating Webhook 的策略引擎：

```bash
# 安装 Gatekeeper
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.15/deploy/gatekeeper.yaml

# 等待就绪
kubectl wait --for=condition=ready pod -l control-plane=gatekeeper-controller-manager -n gatekeeper-system --timeout=120s

# 定义一个 ConstraintTemplate（策略模板）
cat <<EOF | kubectl apply -f -
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredresources
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredResources
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not container.resources
          msg := sprintf("Container <%v> must have resource limits", [container.name])
        }
        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not container.resources.limits
          msg := sprintf("Container <%v> must have resource.limits set", [container.name])
        }
EOF

# 创建约束（触发策略）
cat <<EOF | kubectl apply -f -
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredResources
metadata:
  name: require-resource-limits
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    excludedNamespaces:
      - kube-system
      - gatekeeper-system
EOF

# 测试：创建不合规 Pod（会被拒绝）
kubectl run bad-pod --image=nginx:1.27
# Error from server (Forbidden): admission webhook "validation.gatekeeper.sh"
# denied the request: Container <bad-pod> must have resource limits

# 测试：创建合规 Pod（会成功）
kubectl run good-pod --image=nginx:1.27 --limits='cpu=500m,memory=512Mi'
# pod/good-pod created

# 清理
kubectl delete pod good-pod
kubectl delete k8srequiredresources.constraints.gatekeeper.sh require-resource-limits
kubectl delete constrainttemplate k8srequiredresources
kubectl delete -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.15/deploy/gatekeeper.yaml
```

### Step 5: 理解 AdmissionReview 请求/响应

```bash
# 查看 policy-example.yaml 中注释的 AdmissionResponse 示例
# 理解 webhook 的输入输出格式
```

## Mutating + Validating 组合使用

在实际生产中，通常会同时使用两种 Webhook：

```
场景：确保所有 Pod 都有资源限制

  1. Mutating Webhook：
     如果 Pod 没有设置 resources → 自动设置默认值（如 cpu=100m, memory=128Mi）
     （宽容策略：帮你补上）

  2. Validating Webhook：
     检查修改后的 Pod 是否满足最低要求（如 cpu >= 50m）
     （严格策略：底线不可逾越）
```

这种"先补后查"的模式非常常见：
- **Mutating** 负责修正/补全 → 减少用户犯错的机会
- **Validating** 负责底线检查 → 确保不会放过严重违规

## 生产环境建议

| 建议 | 说明 |
|------|------|
| **从宽松到严格** | 新策略先设 `failurePolicy: Ignore`，观察日志确认无误后再改为 `Fail` |
| **排除系统命名空间** | 始终排除 `kube-system`，避免 webhook 影响 K8s 核心组件 |
| **监控 webhook 延迟** | webhook 会增加 API 请求延迟，关注 P99 延迟 |
| **高可用部署** | webhook 至少部署 2 个副本，避免单点故障 |
| **审计日志** | 记录每个被拒绝的请求，用于安全审计和问题排查 |

## 思考题

1. 如果 Validating Webhook 的 `failurePolicy: Fail` 且 webhook 服务器崩溃了，会对集群产生什么影响？如何避免这种情况？
2. 为什么 Validating Webhook 看到的是"修改后"的对象而不是原始对象？如果它看到的是原始对象，会有什么问题？
3. 如果你想实现"所有 Pod 必须有 `owner` 标签"的策略，应该用 Mutating 还是 Validating Webhook？还是两者都用？
4. OPA Gatekeeper 使用 Rego 语言编写策略。相比直接写一个 webhook 服务器，使用策略引擎有什么好处？

---

上一个 → [03 - Mutating Admission Webhook](../03-mutating-admission/)　｜　下一个 → [05 - Gateway API](../05-gateway-api/)
