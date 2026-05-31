# 05 - Gateway API

## 为什么需要 Gateway API

如果你学过 K8s 的 Ingress（第三章），可能会问：为什么还需要 Gateway API？

Ingress 的核心问题在于**扩展性不足**：

| Ingress 的局限 | 具体表现 |
|---------------|---------|
| **路由能力有限** | 只支持 HTTP/HTTPS 的基于主机名和路径的路由 |
| **不支持 TCP/UDP** | 数据库、gRPC、WebSocket 等非 HTTP 协议无法处理 |
| **角色混淆** | 集群运维和应用开发者的职责混在一个 Ingress 资源里 |
| **注解泛滥** | 高级功能（超时、重试、流量分割）只能通过每个 Controller 不同的注解实现 |
| **不可移植** | 不同 Ingress Controller（Nginx、Traefik、Istio）的注解不兼容 |

Gateway API 是 K8s 官方的下一代流量管理标准，目标是解决这些问题。

## 角色分离：Gateway API 的核心设计

Gateway API 最关键的改进是**角色分离**。在 Ingress 模型中，一个 Ingress 资源同时包含了基础设施配置和应用路由规则，导致集群运维和应用开发者的职责纠缠不清。

Gateway API 将职责拆分为三个角色：

```
┌───────────────────────────────────────────────────────┐
│                  Gateway API 角色                     │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐ │
│  │ Cluster     │  │Infrastructure│  │ Application  │ │
│  │ Operator    │  │ Provider     │  │ Developer    │ │
│  │ (集群运维)   │  │ (平台/云厂商) │  │ (应用开发者)  │ │
│  │             │  │             │  │              │ │
│  │ GatewayClass│  │ Gateway     │  │ HTTPRoute    │ │
│  │             │  │ (Listener)  │  │ (路由规则)    │ │
│  └─────────────┘  └─────────────┘  └──────────────┘ │
│       管理权限        基础设施权限        应用权限       │
└───────────────────────────────────────────────────────┘
```

| 角色 | 管理的资源 | 职责 | 类比 |
|------|-----------|------|------|
| **Cluster Operator** | `GatewayClass` | 选择网关实现，定义全局策略 | 选择用什么品牌的负载均衡器 |
| **Infrastructure Provider** | `Gateway` | 配置网关实例、监听端口、TLS 证书 | 配置负载均衡器的监听器 |
| **Application Developer** | `HTTPRoute` | 定义路由规则，将流量导向自己的服务 | 配置 Nginx 的 location 块 |

这种分离意味着：
- 集群运维不需要关心每个应用的路由细节
- 应用开发者不需要关心网关的基础设施配置
- 平台团队可以控制哪些命名空间可以使用网关

## 核心资源

Gateway API 定义了以下核心资源：

| 资源 | 作用 | 管理者 |
|------|------|--------|
| **GatewayClass** | 定义网关的类型（类似 IngressClass、StorageClass） | 集群运维 |
| **Gateway** | 网关实例，定义监听器（端口、协议、TLS） | 平台/基础设施团队 |
| **HTTPRoute** | HTTP 层的路由规则（路径、主机名、header 匹配） | 应用开发者 |
| **GRPCRoute** | gRPC 路由规则 | 应用开发者 |
| **TLSRoute** | TLS 透传路由（SNI 路由） | 应用开发者 |
| **TCPRoute / UDPRoute** | TCP/UDP 层的路由规则 | 应用开发者 |

资源之间的关系：

```
  GatewayClass          ← 定义网关类型
       │
       ▼
  Gateway               ← 创建网关实例（引用 GatewayClass）
    │   │
    │   └── listeners    ← 定义监听端口和协议
    │
    ├── HTTPRoute ──→ Service ──→ Pod
    ├── GRPCRoute ──→ Service ──→ Pod
    ├── TLSRoute ──→ Service ──→ Pod
    └── TCPRoute ──→ Service ──→ Pod
```

## Ingress vs Gateway API：详细对比

| 特性 | Ingress | Gateway API |
|------|---------|------------|
| **协议支持** | HTTP/HTTPS only | HTTP、HTTPS、gRPC、TCP、UDP、TLS |
| **路由匹配** | 主机名 + 路径 | 主机名 + 路径 + Header + Query |
| **流量分割** | 通过注解（不可移植） | 原生支持 weight（金丝雀发布） |
| **角色分离** | 单一资源 | 三层角色分离 |
| **TLS 配置** | 在 Ingress 中配置 | 在 Gateway 中集中管理 |
| **跨命名空间路由** | 有限支持 | 通过 `allowedRoutes` 精细控制 |
| **扩展性** | 依赖 CRD 注解 | 标准化的扩展点 |
| **可移植性** | 低（注解不兼容） | 高（标准 API） |

> Gateway API 不是 Ingress 的简单升级，而是一次重新设计。Ingress 仍然可用（且会继续维护），但新项目推荐使用 Gateway API。

## Step by Step 操作

### Step 1: 安装 Gateway API CRDs

```bash
# Gateway API 的 CRDs 需要手动安装（较新的 K8s 版本可能已内置）
# 从官方安装最新的 CRDs
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

# 验证 CRDs 已安装
kubectl get crd | grep gateway

# 期望看到：
# gatewayclasses.gateway.networking.k8s.io
# gateways.gateway.networking.k8s.io
# httproutes.gateway.networking.k8s.io
# grpcroutes.gateway.networking.k8s.io
# referencegrants.gateway.networking.k8s.io
```

### Step 2: 创建演示命名空间

```bash
kubectl create namespace gateway-demo
```

### Step 3: 创建 GatewayClass

```bash
# GatewayClass 定义网关的类型
kubectl apply -f gatewayclass.yaml

# 查看
kubectl get gatewayclass

# 输出类似：
# NAME                    CONTROLLER                      ACCEPTED   AGE
# example-gateway-class   example.com/gateway-controller   Unknown    5s
```

> `ACCEPTED` 列显示 `Unknown` 是正常的——因为没有实际的 Controller 在运行来处理这个 GatewayClass。

### Step 4: 创建 Gateway

```bash
# Gateway 定义网关实例和监听器
kubectl apply -f gateway.yaml

# 查看
kubectl get gateway -n gateway-demo

# 输出类似：
# NAME               CLASS                    ADDRESS   PROGRAMMED   AGE
# example-gateway    example-gateway-class              Unknown      5s
```

### Step 5: 创建 HTTPRoute

```bash
# HTTPRoute 定义路由规则和后端服务
kubectl apply -f httproute.yaml

# 查看 HTTPRoute
kubectl get httproute -n gateway-demo

# 输出类似：
# NAME            HOSTNAMES         PARENTREFS               AGE
# example-route   ["example.com"]   [{"name":"example-gateway"}]  5s

# 查看后端服务
kubectl get svc -n gateway-demo

# 输出类似：
# NAME             TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)   AGE
# api-service      ClusterIP   10.96.0.10       <none>        80/TCP    5s
# api-service-v2   ClusterIP   10.96.0.11       <none>        80/TCP    5s
# web-service      ClusterIP   10.96.0.12       <none>        80/TCP    5s
```

### Step 6: 理解路由规则

```bash
# 查看 HTTPRoute 的详细规则
kubectl describe httproute example-route -n gateway-demo
```

我们定义了两条规则：

| 规则 | 匹配条件 | 后端 | 流量比例 |
|------|---------|------|---------|
| 规则 1 | `Host: example.com` + `Path: /api*` | api-service (90%) + api-service-v2 (10%) | 金丝雀发布 |
| 规则 2 | `Host: example.com` + `Path: /*` | web-service (100%) | 默认路由 |

> `weight` 字段是 Gateway API 的原生功能——不需要任何注解，就能实现金丝雀发布的流量分割。这在 Ingress 中通常需要通过特定的注解（如 Nginx 的 `canary` 注解）才能实现。

### Step 7: 使用 Envoy Gateway 实际体验（可选）

如果你想在集群中实际体验 Gateway API 的路由功能，可以使用 [Envoy Gateway](https://gateway.envoyproxy.io/)：

```bash
# 安装 Envoy Gateway（Gateway API 的一个 Controller 实现）
helm install envoy-gateway oci://docker.io/envoyproxy/gateway-helm --version v1.2.0 -n envoy-gateway-system --create-namespace

# 等待就绪
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=envoy-gateway -n envoy-gateway-system --timeout=120s

# 修改 GatewayClass 的 controllerName 匹配 Envoy Gateway
kubectl patch gatewayclass example-gateway-class --type=merge -p '{"spec":{"controllerName":"gateway.envoyproxy.io/gatewayclass-controller"}}'

# 部署测试工作负载
kubectl apply -f httproute.yaml

# 等待 Gateway 获得 External IP
kubectl get gateway example-gateway -n gateway-demo -o wide

# 用 curl 测试路由
GATEWAY_IP=$(kubectl get gateway example-gateway -n gateway-demo -o jsonpath='{.status.addresses[0].value}')

# 测试 /api 路径
curl -H "Host: example.com" http://$GATEWAY_IP/api

# 测试默认路径
curl -H "Host: example.com" http://$GATEWAY_IP/
```

### Step 8: 清理

```bash
# 删除路由和网关
kubectl delete -f httproute.yaml
kubectl delete -f gateway.yaml
kubectl delete -f gatewayclass.yaml

# 删除命名空间
kubectl delete namespace gateway-demo

# 如果安装了 Envoy Gateway
helm uninstall envoy-gateway -n envoy-gateway-system
kubectl delete namespace envoy-gateway-system

# 卸载 Gateway API CRDs（可选）
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
```

## Gateway API 的高级特性

### 流量分割（金丝雀发布）

```yaml
backendRefs:
  - name: api-v1
    weight: 90
  - name: api-v2
    weight: 10
```

这是 Gateway API 的原生功能，不需要任何特定 Controller 的注解。

### Header 匹配

```yaml
matches:
  - path:
      type: PathPrefix
      value: /api
    headers:
      - name: X-Version
        value: "v2"
```

可以根据 HTTP Header 做精细路由——这在 A/B 测试中非常有用。

### 跨命名空间路由

Gateway 通过 `allowedRoutes` 控制哪些命名空间的 Route 可以绑定：

```yaml
allowedRoutes:
  namespaces:
    from: Selector
    selector:
      matchLabels:
        shared-gateway-access: "true"
```

只有带 `shared-gateway-access: "true"` 标签的命名空间才能使用这个 Gateway。

## Gateway API 的生态

| Controller | 说明 |
|-----------|------|
| **Envoy Gateway** | Envoy 官方的 Gateway API 实现，推荐入门使用 |
| **Istio** | 服务网格，支持 Gateway API 作为流量入口 |
| **Kong Gateway** | API Gateway，原生支持 Gateway API |
| **Traefik** | 反向代理/负载均衡器 |
| **Cilium** | eBPF 网络方案，支持 Gateway API |

## 思考题

1. Gateway API 的三层角色分离（GatewayClass → Gateway → HTTPRoute）分别对应什么样的组织权限划分？如果在一个小团队中，是否有必要遵守这种分离？
2. 如果一个 HTTPRoute 的 `parentRefs` 引用了一个不存在的 Gateway，会发生什么？这说明了什么设计理念？
3. Gateway API 的 `weight` 流量分割和 Ingress 的注解式金丝雀（如 Nginx Ingress 的 `canary` 注解）相比，有什么优势？
4. 为什么 Gateway API 要支持 TCP/UDP 路由？举出两个 Ingress 无法处理但 Gateway API 可以的场景。

---

上一个 → [04 - Validating Admission Webhook](../04-validating-admission/)
