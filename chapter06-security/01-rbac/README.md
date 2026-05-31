# 01 - RBAC：基于角色的访问控制

## K8s 的安全模型

想象你是一家公司的管理员，你需要回答一个问题：**谁能在哪里做什么？**

Kubernetes 用 RBAC（Role-Based Access Control）来回答这三个维度：

```
谁 (Subject)  →  能做什么 (Verb)  →  对什么资源 (Resource)  →  在哪里 (Namespace/Cluster)
```

具体来说：

| 维度 | K8s 术语 | 例子 |
|------|---------|------|
| **谁** | Subject | 用户、组、ServiceAccount |
| **做什么** | Verb | get、list、create、delete |
| **对什么资源** | Resource | Pod、Service、Deployment |
| **在哪里** | Namespace / Cluster | default 命名空间、整个集群 |

> RBAC 在 Kubernetes v1.8 之后成为默认的授权模式。在这之前，ABAC（Attribute-Based）更常见，但 ABAC 需要重启 API Server 才能生效，难以管理。RBAC 是声明式的，动态生效。

## 核心概念

### Role vs ClusterRole

K8s 把权限分成两个作用域：

| 资源 | 作用域 | 使用场景 |
|------|--------|---------|
| **Role** | 单个命名空间 | "只能读 default 命名空间的 Pod" |
| **ClusterRole** | 整个集群 | "能读所有命名空间的 Pod" 或 "能管理节点等集群级资源" |

为什么这样设计？因为 K8s 中的资源分两类：

1. **命名空间级资源** — Pod、Service、Deployment、ConfigMap 等
2. **集群级资源** — Node、Namespace、PersistentVolume、ClusterRole 本身

Role 只能控制命名空间级资源，ClusterRole 可以控制所有资源。

> 不是所有"跨命名空间"的需求都需要 ClusterRole。如果一个用户需要访问 3 个命名空间的 Pod，可以在这 3 个命名空间各创建一个 Role + RoleBinding，而不是给一个全局的 ClusterRole。

### RoleBinding vs ClusterRoleBinding

有了 Role（定义权限），还需要把权限"绑定"到具体的人：

| 绑定资源 | 作用 | 效果 |
|---------|------|------|
| **RoleBinding** | 把 Role 绑定到 Subject | Subject 获得该命名空间的 Role 权限 |
| **ClusterRoleBinding** | 把 ClusterRole 绑定到 Subject | Subject 获得整个集群的 ClusterRole 权限 |

一个容易忽略的细节：**RoleBinding 也可以引用 ClusterRole**。这有什么用？

假设你定义了一个 "pod-reader" ClusterRole（读 Pod 的权限），然后在 10 个命名空间各创建一个 RoleBinding 引用它。这样同一个 ClusterRole 被复用了 10 次，每个命名空间的人只能读自己命名空间的 Pod。比在每个命名空间写 10 个 Role 要简洁得多。

### 常用 Verb（动词）

| Verb | 含义 | 对应的 kubectl 操作 |
|------|------|-------------------|
| `get` | 获取单个资源 | `kubectl get pod xxx` |
| `list` | 列出资源 | `kubectl get pods` |
| `watch` | 监听资源变化 | `kubectl get pods --watch` |
| `create` | 创建资源 | `kubectl apply -f xxx.yaml` |
| `update` | 更新整个资源 | `kubectl replace -f xxx.yaml` |
| `patch` | 部分更新资源 | `kubectl patch pod xxx` |
| `delete` | 删除资源 | `kubectl delete pod xxx` |
| `deletecollection` | 批量删除 | `kubectl delete pods --all` |

> `get` 和 `list` 的区别很重要：`get` 是获取单个命名资源（知道名字），`list` 是列出所有（可能泄露资源名称）。在严格的安全场景下，可以只给 `get` 不给 `list`。

### Subject（主体）

RBAC 可以绑定到三种主体：

| Subject | 说明 | 使用场景 |
|---------|------|---------|
| **User** | 集群外部的人类用户（由外部认证系统管理） | 开发人员、运维人员 |
| **Group** | 用户组 | 按团队批量授权 |
| **ServiceAccount** | Pod 内进程使用的身份 | 自动化程序、CI/CD |

> K8s 本身不管理 User 和 Group，它们由外部认证系统（OIDC、证书等）提供。ServiceAccount 是 K8s 原生管理的。我们这节用 ServiceAccount 做演示。

## RBAC 的工作流程

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│ Subject     │────►│ RoleBinding  │────►│ Role            │
│ (SA/User)   │     │ (绑定关系)    │     │ (权限规则)       │
└─────────────┘     └──────────────┘     └─────────────────┘
                          │
                          │ 也可以引用
                          ▼
                    ┌─────────────────┐
                    │ ClusterRole     │
                    │ (集群级权限)     │
                    └─────────────────┘
```

1. **Role/ClusterRole** 定义了一组权限规则（谁能做什么）
2. **RoleBinding/ClusterRoleBinding** 把 Subject 和 Role 连起来
3. 当 Subject 发起 API 请求时，API Server 检查所有绑定的 Role，决定是否允许

## Step by Step：创建 RBAC 权限

我们的目标：创建一个 ServiceAccount，让它只能读取 Pod，不能做其他操作。

### Step 1: 创建命名空间和 ServiceAccount

```bash
# 创建一个专用命名空间
kubectl create namespace rbac-demo

# 创建 ServiceAccount
kubectl create serviceaccount pod-reader-sa -n rbac-demo

# 验证
kubectl get sa -n rbac-demo
# NAME            SECRETS   AGE
# default         0         10s
# pod-reader-sa   0         10s
```

每个命名空间都有一个 `default` ServiceAccount，Pod 默认使用它。

### Step 2: 创建 Role

```bash
kubectl apply -f pod-reader-role.yaml

# 验证
kubectl get role -n rbac-demo
# NAME             CREATED AT
# pod-reader       2026-06-01T00:00:00Z

# 查看 Role 详情
kubectl describe role pod-reader -n rbac-demo
```

### Step 3: 创建 RoleBinding

```bash
kubectl apply -f pod-reader-binding.yaml

# 验证
kubectl get rolebinding -n rbac-demo
# NAME                 ROLE             AGE
# pod-reader-binding   Role/pod-reader  10s

# 查看绑定详情
kubectl describe rolebinding pod-reader-binding -n rbac-demo
```

### Step 4: 创建一个测试 Pod

```bash
# 先创建一个普通 Pod 作为测试目标
kubectl run target-pod --image=nginx -n rbac-demo

# 等待 Pod 就绪
kubectl wait --for=condition=Ready pod/target-pod -n rbac-demo --timeout=30s
```

### Step 5: 验证权限 — kubectl auth can-i

`kubectl auth can-i` 是验证 RBAC 配置的最佳工具：

```bash
# 检查 pod-reader-sa 能否 list pods（应该可以）
kubectl auth can-i list pods --as=system:serviceaccount:rbac-demo:pod-reader-sa -n rbac-demo
# yes

# 检查能否 get 单个 pod（应该可以）
kubectl auth can-i get pods --as=system:serviceaccount:rbac-demo:pod-reader-sa -n rbac-demo
# yes

# 检查能否 delete pods（应该不行）
kubectl auth can-i delete pods --as=system:serviceaccount:rbac-demo:pod-reader-sa -n rbac-demo
# no

# 检查能否 create deployments（应该不行）
kubectl auth can-i create deployments --as=system:serviceaccount:rbac-demo:pod-reader-sa -n rbac-demo
# no

# 检查能否在其他命名空间读 pods（应该不行）
kubectl auth can-i list pods --as=system:serviceaccount:rbac-demo:pod-reader-sa -n default
# no
```

### Step 6: 用 Pod 实际测试

上面的 `can-i` 只是模拟检查。我们用一个真正的 Pod 来验证：

```bash
# 创建一个使用 pod-reader-sa 的 Pod
kubectl run test-rbac --image=nginx -n rbac-demo \
  --serviceaccount=pod-reader-sa \
  --restart=Never

# 等待就绪
kubectl wait --for=condition=Ready pod/test-rbac -n rbac-demo --timeout=30s

# 在 Pod 内访问 API Server
kubectl exec test-rbac -n rbac-demo -- \
  curl -s -k -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  https://kubernetes.default.svc/api/v1/namespaces/rbac-demo/pods \
  | head -20

# 你应该能看到 Pod 列表

# 尝试删除（应该被拒绝）
kubectl exec test-rbac -n rbac-demo -- \
  curl -s -k -X DELETE \
  -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  https://kubernetes.default.svc/api/v1/namespaces/rbac-demo/pods/target-pod
# 会返回 403 Forbidden
```

### Step 7: 清理

```bash
kubectl delete namespace rbac-demo
```

## YAML 详解

### pod-reader-role.yaml

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: rbac-demo
rules:
  - apiGroups: [""]          # "" 表示核心 API 组（core API group）
    resources: ["pods"]      # 控制的资源类型
    verbs: ["get", "list"]   # 允许的操作
```

关键字段：

| 字段 | 说明 |
|------|------|
| `apiGroups` | API 组名。`""` 是核心组（Pod、Service 等），`apps` 是 Deployment 等，`batch` 是 Job/CronJob |
| `resources` | 资源类型名。注意是复数形式：`pods`、`services`、`deployments` |
| `verbs` | 允许的操作动词 |
| `resourceNames`（可选） | 限制到特定名称的资源，如 `["my-pod"]` 表示只能操作叫这个名字的资源 |

### pod-reader-binding.yaml

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-reader-binding
  namespace: rbac-demo
subjects:                          # 谁获得权限
  - kind: ServiceAccount
    name: pod-reader-sa
    namespace: rbac-demo
roleRef:                           # 引用哪个 Role
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

> `roleRef` 是不可变的 —— 创建后不能修改。如果要更换 Role，只能删除 RoleBinding 重新创建。

## 常见 RBAC 场景

| 场景 | Role 示例 |
|------|----------|
| 开发者只读 | `verbs: [get, list, watch]`, `resources: [pods, services, deployments]` |
| CI/CD 部署 | `verbs: [get, list, create, update, patch, delete]`, `resources: [deployments, pods]` |
| 监控系统 | ClusterRole，`verbs: [get, list, watch]`, `resources: [pods, nodes, namespaces]` |
| 只能操作自己创建的资源 | 配合 `resourceNames` 字段限制 |

## 排查 RBAC 问题的技巧

```bash
# 查看某个 ServiceAccount 的所有绑定
kubectl get rolebinding,clusterrolebinding -A -o json | \
  jq -c '.items[] | select(.subjects[]? | .name == "pod-reader-sa")'

# 查看某个 Role 的完整权限
kubectl describe role pod-reader -n rbac-demo

# 查看 ClusterRole 的聚合规则（aggregation）
kubectl get clusterrole -o wide
```

> 初学者常见错误：创建了 Role 和 ServiceAccount，但忘了创建 RoleBinding。记住：**Role 和 ServiceAccount 是独立的，Binding 才是桥梁**。

## 思考题

1. 如果一个 ServiceAccount 同时被两个 RoleBinding 绑定到不同的 Role，它的最终权限是什么？（提示：RBAC 权限是累加的）
2. `get` 和 `list` 的区别是什么？为什么在严格安全场景下应该只给 `get`？
3. RoleBinding 引用 ClusterRole 时，权限范围是整个集群还是仅限该命名空间？为什么这样设计？
4. 如果误操作给了某个 ServiceAccount 过高的权限（比如 cluster-admin），你会怎么排查和修复？

---

下一个 → [02 - ServiceAccount](../02-service-account/)
