# 02 - ServiceAccount：Pod 的身份

## 什么是 ServiceAccount

在 Linux 系统中，每个进程都以某个用户的身份运行。类似地，在 Kubernetes 中，每个 Pod 中的进程也以一个"身份"运行——这个身份就是 **ServiceAccount**（简称 SA）。

但 ServiceAccount 代表的不是人类用户，而是**运行在 Pod 内的进程**。当 Pod 里的应用需要调用 Kubernetes API 时，它就用 ServiceAccount 的身份来证明"我是谁"。

| 概念 | 代表谁 | 管理方 |
|------|--------|--------|
| **User** | 人类用户（如运维工程师） | 外部认证系统（OIDC、证书等） |
| **ServiceAccount** | Pod 内的进程 | Kubernetes 自身 |

> 简单记忆：User 是"人"，ServiceAccount 是"程序"。人用 kubectl，程序用 ServiceAccount。

## 每个 Pod 都有一个 ServiceAccount

当你创建一个 Pod 时，Kubernetes 会自动做以下事情：

1. 如果没有指定 ServiceAccount，使用命名空间的 `default` ServiceAccount
2. 将 ServiceAccount 的 API 凭证（token）挂载到 Pod 内的固定路径
3. Pod 内的进程可以用这个 token 访问 Kubernetes API

```
┌─────────────────────────────────────┐
│               Pod                   │
│                                     │
│  ┌──────────┐                       │
│  │ 容器进程  │                       │
│  └────┬─────┘                       │
│       │ 读取                        │
│       ▼                             │
│  /var/run/secrets/kubernetes.io/    │
│  serviceaccount/                    │
│    ├── ca.crt    (CA 证书，验证 API Server) │
│    ├── namespace (当前命名空间名)       │
│    └── token     (JWT token，证明身份)  │
│                                     │
│  身份: default ServiceAccount        │
└─────────────────────────────────────┘
```

## Token 的三个文件

| 文件 | 作用 |
|------|------|
| `ca.crt` | 集群的 CA 证书，用于验证 API Server 的 TLS 证书，防止中间人攻击 |
| `namespace` | 当前命名空间的名称，让应用知道自己在哪个命名空间 |
| `token` | JWT（JSON Web Token），包含 ServiceAccount 的身份信息，用于向 API Server 认证 |

> 从 Kubernetes 1.24 开始，ServiceAccount 不再自动创建 Secret。Token 由 kubelet 通过 TokenRequest API 动态生成，并以 projected volume 的方式挂载到 Pod 中。这种方式更安全——token 有有效期，且与 Pod 生命周期绑定。

## automountServiceAccountToken

默认情况下，每个 Pod 都会自动挂载 ServiceAccount token。但很多应用根本不需要访问 Kubernetes API（比如一个静态网站），挂载 token 反而增加了安全风险——如果应用被入侵，攻击者可以读取 token 来访问 API。

你可以禁用自动挂载：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: no-api-access
spec:
  automountServiceAccountToken: false   # 不挂载 token
  containers:
    - name: nginx
      image: nginx
```

也可以在 ServiceAccount 上设置，这样所有使用该 SA 的 Pod 默认都不挂载：

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: no-mount-sa
automountServiceAccountToken: false
```

> Pod 级别的 `automountServiceAccountToken` 优先级高于 ServiceAccount 级别的设置。

## 为什么需要自定义 ServiceAccount

你可能会问：既然每个 Pod 已经有 `default` ServiceAccount 了，为什么还要创建自定义的？

答案是**最小权限原则**（Principle of Least Privilege）：

- `default` ServiceAccount 默认**没有任何权限**（除了基本的 API 发现），但它可以被绑定到任何 Role
- 如果你给 `default` ServiceAccount 授权，那同一个命名空间里**所有**没有指定 SA 的 Pod 都获得了这个权限
- 自定义 ServiceAccount 可以精确控制哪些 Pod 获得哪些权限

| 做法 | 安全性 | 说明 |
|------|--------|------|
| 给 `default` SA 授权 | 危险 | 命名空间内所有 Pod 都获得权限 |
| 为每个应用创建专用 SA | 安全 | 只有指定的 Pod 获得对应权限 |
| 不挂载 token | 最安全 | 不需要访问 API 的应用完全不暴露凭证 |

## Step by Step：自定义 ServiceAccount

### Step 1: 创建命名空间

```bash
kubectl create namespace sa-demo
```

### Step 2: 创建自定义 ServiceAccount

```bash
kubectl apply -f custom-sa.yaml

# 验证
kubectl get sa -n sa-demo
# NAME           SECRETS   AGE
# default        0         10s
# my-app-sa      0         5s
```

### Step 3: 查看 ServiceAccount 详情

```bash
kubectl describe sa my-app-sa -n sa-demo

# 输出类似：
# Name:                my-app-sa
# Namespace:           sa-demo
# Labels:              <none>
# Annotations:         <none>
# Image pull secrets:  <none>
# Mountable secrets:   <none>
# Tokens:              <none>
# Events:              <none>
```

注意 `Tokens: <none>` —— 这是 1.24+ 的正常行为，token 不再以 Secret 形式存储，而是由 kubelet 按需生成。

### Step 4: 创建使用自定义 SA 的 Pod

```bash
kubectl apply -f pod-custom-sa.yaml

# 查看 Pod 状态
kubectl get pods -n sa-demo
# NAME            READY   STATUS    RESTARTS   AGE
# my-app          1/1     Running   0          10s
```

### Step 5: 验证 Pod 使用的 ServiceAccount

```bash
# 查看 Pod 详情，确认使用了自定义 SA
kubectl get pod my-app -n sa-demo -o jsonpath='{.spec.serviceAccountName}'
# 输出: my-app-sa

# 对比：默认 Pod 使用的是 "default"
kubectl run default-pod --image=nginx -n sa-demo
kubectl get pod default-pod -n sa-demo -o jsonpath='{.spec.serviceAccountName}'
# 输出: default
```

### Step 6: 进入 Pod 查看挂载的凭证

```bash
# exec 进入 Pod 查看挂载的文件
kubectl exec my-app -n sa-demo -- ls /var/run/secrets/kubernetes.io/serviceaccount/
# ca.crt
# namespace
# token

# 查看 namespace 文件
kubectl exec my-app -n sa-demo -- cat /var/run/secrets/kubernetes.io/serviceaccount/namespace
# sa-demo

# 查看 token 的前几个字符（JWT 格式）
kubectl exec my-app -n sa-demo -- head -c 50 /var/run/secrets/kubernetes.io/serviceaccount/token
# eyJhbGciOiJSUzI1NiIsImtpZCI6...

# 查看 CA 证书
kubectl exec my-app -n sa-demo -- head -2 /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
# -----BEGIN CERTIFICATE-----
# MIID...
```

### Step 7: 用 Pod 内的 token 实际访问 API

```bash
# 在 Pod 内部用 token 访问 Kubernetes API
kubectl exec my-app -n sa-demo -- sh -c '\
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && \
  curl -s -k -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/sa-demo/pods'

# 因为没有给 my-app-sa 授权，应该返回 403 Forbidden
# 这说明 token 有效（认证通过），但 RBAC 不允许（授权失败）
```

### Step 8: 清理

```bash
kubectl delete namespace sa-demo
```

## JWT Token 的结构

Token 文件的内容是一个 JWT（JSON Web Token），由三部分组成，用 `.` 分隔：

```
eyJhbGciOiJSUzI1NiIs...  .  eyJpc3MiOiJrdWJlcm5ldGVz...  .  SflKxwRJSMCC...
↑ header                     ↑ payload                       ↑ signature
```

你可以用 `kubectl` 解码 payload 查看：

```bash
# 获取 token 并解码 payload
kubectl exec my-app -n sa-demo -- cat /var/run/secrets/kubernetes.io/serviceaccount/token | \
  cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
```

Payload 中包含：

| 字段 | 含义 |
|------|------|
| `iss` | 签发者（Kubernetes API Server） |
| `kubernetes.io/serviceaccount/service-account.name` | ServiceAccount 名称 |
| `kubernetes.io/serviceaccount/namespace` | 命名空间 |
| `exp` | 过期时间 |
| `aud` | 受众（audience），通常是 API Server |

> 不要在生产环境中将 JWT token 输出到日志中。Token 泄露等同于身份泄露。

## ServiceAccount 的 Image Pull Secrets

除了 API 访问凭证，ServiceAccount 还有一个重要用途：管理私有镜像仓库的拉取凭证。

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: private-registry-sa
imagePullSecrets:
  - name: my-registry-secret
```

所有使用这个 SA 的 Pod 都会自动获得拉取私有镜像的能力，不需要在每个 Pod 上单独配置 `imagePullSecrets`。

## 关键概念总结

| 概念 | 要点 |
|------|------|
| ServiceAccount | Pod 内进程的身份，由 K8s 管理 |
| default SA | 每个命名空间的默认身份，Pod 不指定时使用 |
| Token 挂载路径 | `/var/run/secrets/kubernetes.io/serviceaccount/` |
| automountServiceAccountToken | 控制是否自动挂载 token，不访问 API 时应设为 false |
| 最小权限 | 为每个应用创建专用 SA，只授予必要权限 |
| JWT Token | 包含 SA 身份信息，有有效期，1.24+ 动态生成 |

> **最佳实践**：不需要访问 Kubernetes API 的 Pod，设置 `automountServiceAccountToken: false`。需要访问的，创建专用 ServiceAccount 并通过 RBAC 授予最小权限。

## 思考题

1. 如果一个 Pod 不需要访问 Kubernetes API，但它挂载了 default ServiceAccount 的 token，会有什么安全风险？
2. `automountServiceAccountToken: false` 在 Pod 级别和 ServiceAccount 级别都设置了，以哪个为准？如果 Pod 设为 `true` 而 SA 设为 `false` 呢？
3. 从 Kubernetes 1.24 开始，为什么不再为 ServiceAccount 自动创建 Secret？这种变化带来了什么安全好处？
4. 假设你有 10 个应用，其中 3 个需要访问 Kubernetes API，你会如何设计 ServiceAccount 方案？

---

下一个 → [03 - NetworkPolicy](../03-network-policy/)
