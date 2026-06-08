# 05 - Ingress

## 为什么需要 Ingress

前面的 LoadBalancer Service 解决了外部访问的问题，但它有一个致命缺陷：

**每个 Service 需要一个 LoadBalancer，很贵。**

假设你有 5 个 HTTP 服务：

```
api-service   → LoadBalancer → 外部 IP 1.2.3.4   → $20/月
web-service   → LoadBalancer → 外部 IP 5.6.7.8   → $20/月
auth-service  → LoadBalancer → 外部 IP 9.10.11.12 → $20/月
admin-service → LoadBalancer → 外部 IP 13.14.15.16 → $20/月
metrics-service → LoadBalancer → 外部 IP 17.18.19.20 → $20/月
                                                总计: $100/月
```

而且用户要记 5 个不同的 IP 或域名，很不方便。

**Ingress 的思路**：只用**一个** LoadBalancer（一个外部 IP），根据 HTTP 请求的**域名或路径**路由到不同的 Service。

```
                     ┌──────────────────┐
                     │   Ingress        │
Client ─────────────►│   Controller     │
  一个外部 IP         │   (NGINX)        │
                     └──────────────────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
         /api →        / →        /admin →
         api-service  web-service admin-service
```

一个 IP，按规则分流——这就是 Ingress。

## Ingress 的两个概念

很多人混淆这两个东西，理解它们的区别非常重要：

### Ingress Controller（控制器）

**实现层** — 一个反向代理软件（如 NGINX、Traefik、HAProxy），实际处理流量转发的组件。

- 它自己是一个 Pod，需要先安装到集群中
- 它监听集群中的 Ingress 资源变化，动态更新代理配置
- 它需要通过 Service（通常是 LoadBalancer 或 NodePort）对外暴露

### Ingress Resource（资源）

**规则定义** — 一个 K8s API 对象，用 YAML 声明路由规则。

```yaml
# 这是一个 Ingress Resource——你写的规则
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-ingress
spec:
  rules:
    - http:
        paths:
          - path: /api
            backend:
              service:
                name: api-service
```

两者的关系：

```
Ingress Resource (你写的规则) → Ingress Controller 读取规则 → 更新 NGINX 配置 → 流量按规则转发
```

> 类比：Ingress Resource 是"交通规则"（红灯停、绿灯行），Ingress Controller 是"红绿灯"（实际执行规则的设备）。

### 常见 Ingress Controller

| 名称 | 基于的软件 | 特点 |
|------|-----------|------|
| NGINX Ingress Controller | NGINX | 最流行，功能全面，我们在 Chapter 00 已经安装 |
| Traefik | Traefik | 云原生，自动发现，配置热更新 |
| HAProxy Ingress | HAProxy | 高性能，适合大规模 |
| Kong Ingress | Kong | 有 API 网关功能 |
| AWS ALB Ingress | AWS ALB | AWS 专用 |

> 本教程使用 NGINX Ingress Controller，已在 Chapter 00 安装。

## 路由方式

Ingress 支持两种路由方式：**基于路径（Path）** 和 **基于域名（Host）**。

### 基于路径路由

同一个域名，根据 URL 路径分发：

```
example.com/api    → api-service
example.com/web    → web-service
example.com/admin  → admin-service
```

```yaml
rules:
  - http:
      paths:
        - path: /api
          backend:
            service:
              name: api-service
        - path: /web
          backend:
            service:
              name: web-service
```

### 基于域名路由

不同域名指向不同 Service：

```
api.example.com    → api-service
web.example.com    → web-service
admin.example.com  → admin-service
```

```yaml
rules:
  - host: api.example.com
    http:
      paths:
        - path: /
          backend:
            service:
              name: api-service
  - host: web.example.com
    http:
      paths:
        - path: /
          backend:
            service:
              name: web-service
```

### 混合使用

也可以同时按域名和路径路由：

```
api.example.com/v1 → api-v1-service
api.example.com/v2 → api-v2-service
web.example.com/   → web-service
```

## pathType 说明

`pathType` 字段决定了路径匹配的严格程度：

| pathType | 行为 | 示例 |
|----------|------|------|
| `Exact` | 精确匹配，只有完全一致的路径才匹配 | `/api` 只匹配 `/api`，不匹配 `/api/v1` |
| `Prefix` | 前缀匹配，以 `/` 分割进行匹配 | `/api` 匹配 `/api`、`/api/v1`、`/api/users` |
| `ImplementationSpecific` | 由 Ingress Controller 决定 | NGINX 可以用正则表达式 |

> 最常用的是 `Prefix`。`Exact` 适合只需要匹配精确路径的场景。

## Ingress 和 TLS

Ingress 可以配置 TLS（HTTPS），让你的服务支持加密访问：

```yaml
spec:
  tls:
    - hosts:
        - example.com
      # 引用 K8s Secret 中存储的 TLS 证书
      secretName: example-tls-secret
  rules:
    - host: example.com
      http:
        paths:
          - path: /
            backend:
              service:
                name: web-service
                port:
                  number: 80
```

TLS 证书存储在 K8s Secret 中。在测试环境可以用自签名证书：

```bash
# 生成自签名证书
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=example.com"

# 创建 K8s Secret
kubectl create secret tls example-tls-secret \
  --key tls.key --cert tls.crt
```

> 生产环境通常使用 cert-manager（一个 K8s 插件）自动从 Let's Encrypt 获取和续期证书。

## Step by Step 实操

### Step 1: 确认 Ingress Controller 已安装

```bash
# 查看 Ingress Controller Pod
kubectl get pods -n ingress-nginx

# 期望输出（有 Running 的 controller Pod）：
# NAME                                        READY   STATUS    RESTARTS   AGE
# ingress-nginx-controller-xxxxxxxxxx-xxxxx   1/1     Running   0          1h
```

> 如果没有，回到 Chapter 00 安装 Ingress Controller。

### Step 2: 创建 API 服务

```bash
kubectl apply -f api-deployment.yaml

# 输出：
# deployment.apps/api-deployment created
# service/api-service created
```

### Step 3: 创建 Web 服务

```bash
kubectl apply -f web-deployment.yaml

# 输出：
# deployment.apps/web-deployment created
# service/web-service created
```

### Step 4: 确认服务和 Pod 都正常

```bash
kubectl get deployment,pods,svc -l app=api
kubectl get deployment,pods,svc -l app=web

# 确认两组服务都在运行
```

### Step 5: 创建 Ingress 路由规则

```bash
kubectl apply -f ingress-demo.yaml

# 输出：
# ingress.networking.k8s.io/demo-ingress created
```

### Step 6: 查看 Ingress 状态

```bash
kubectl get ingress

# 输出类似：
# NAME            CLASS   HOSTS   ADDRESS          PORTS   AGE
# demo-ingress    nginx   *       172.18.0.2       80      1m
```

| 字段 | 含义 |
|------|------|
| `CLASS` | `nginx` — 使用 NGINX Ingress Controller |
| `HOSTS` | `*` — 匹配所有域名（因为没有指定 host） |
| `ADDRESS` | Ingress Controller 的外部 IP |
| `PORTS` | `80` — HTTP 端口 |

```bash
# 查看 Ingress 详情
kubectl describe ingress demo-ingress

# 关注 Rules 部分，确认路由规则正确
```

### Step 7: 测试路径路由

在 kind 环境中，Ingress Controller 的 80 端口映射到了 kind 的 control-plane 容器。

```bash
# 方法一：在宿主机上直接访问（kind 已经映射了 80 端口）
curl http://localhost/api

# 期望输出：
# {"service":"api","message":"Hello from API service"}

curl http://localhost/

# 期望输出：
# <h1>Hello from Web service</h1><p>This is the web frontend.</p>

curl http://localhost/other-path

# 也会输出 Web 服务的响应（因为 / 匹配所有路径）
```

```bash
# 方法二：如果方法一不通，用 kubectl 的 port-forward
# 先找到 Ingress Controller 的 Service
kubectl get svc -n ingress-nginx

# port-forward 到 Ingress Controller
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80

# 在另一个终端测试
curl http://localhost:8080/api
# {"service":"api","message":"Hello from API service"}

curl http://localhost:8080/
# <h1>Hello from Web service</h1>
```

### Step 8: 查看路由效果

```bash
# 用 -v 参数看详细的请求过程
curl -v http://localhost/api

# 注意响应头：
# < HTTP/1.1 200 OK
# < Server: nginx  ← Ingress Controller（NGINX）
# ...
# {"service":"api","message":"Hello from API service"}
```

请求经过了两次 NGINX：
1. 第一次是 Ingress Controller 的 NGINX（负责路由）
2. 第二次是 Pod 里的 NGINX（实际服务）

### Step 9: 测试基于域名的路由（可选）

如果你想测试 host-based 路由，可以修改 `ingress-demo.yaml`：

```yaml
spec:
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: api-service
                port:
                  number: 80
    - host: web.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web-service
                port:
                  number: 80
```

```bash
# 应用修改
kubectl apply -f ingress-demo.yaml

# 测试时用 -H 指定 Host 头
curl -H "Host: api.example.com" http://localhost/
# {"service":"api","message":"Hello from API service"}

curl -H "Host: web.example.com" http://localhost/
# <h1>Hello from Web service</h1>
```

> 这种方式在测试环境很方便。生产环境中，真实域名通过 DNS 解析到 Ingress Controller 的外部 IP。

### Step 10: 清理

```bash
kubectl delete -f ingress-demo.yaml
kubectl delete -f api-deployment.yaml
kubectl delete -f web-deployment.yaml
```

## 流量全链路回顾

以本节示例为例，一个请求从发出到到达 Pod 的完整路径：

```
Client 发起请求
  curl http://localhost/api
       │
       ▼
Kind 容器端口映射（80 → control-plane:80）
       │
       ▼
Ingress Controller (NGINX Pod)
  匹配规则: path=/api → api-service
       │
       ▼
api-service (ClusterIP Service)
  kube-proxy 负载均衡
       │
       ▼
api Pod (nginx 容器)
  返回: {"service":"api","message":"Hello from API service"}
```

对比不用 Ingress 的方式：

```
# 没有 Ingress：
Client → LoadBalancer ($$$) → api-service → api Pod
Client → LoadBalancer ($$$) → web-service → web Pod
# 两个 LoadBalancer，两份钱

# 有 Ingress：
Client → LoadBalancer (1个) → Ingress Controller → 路由规则 → api-service / web-service
# 一个 LoadBalancer，按规则分流
```

## 本章总结

我们学完了 5 种 Service 和 Ingress，用一张图串联起来：

```
                        ┌──────────────────────────────────┐
                        │          外部流量入口              │
                        └───────────┬──────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
              LoadBalancer      NodePort        Ingress
             (云 LB 分配IP)   (NodeIP:Port)   (一个 LB+路由规则)
                    │               │               │
                    └───────┬───────┘               │
                            ▼                       ▼
                     ┌─────────────┐        ┌──────────────┐
                     │ ClusterIP   │        │ Ingress      │
                     │ (集群内IP)   │        │ Controller   │
                     └──────┬──────┘        └──────┬───────┘
                            │                      │
                            ▼                      ▼
                     ┌─────────────┐        ┌──────────────┐
                     │  Pod (标签   │◄───────│ 多个不同路径   │
                     │  匹配的)    │        │ 的 Service    │
                     └─────────────┘        └──────────────┘

              Headless Service: 不分配 ClusterIP，DNS 直接返回 Pod IP
```

| 资源 | 用途 | 访问方式 |
|------|------|---------|
| ClusterIP | 内部服务通信 | `service-name`（DNS） |
| NodePort | 简单外部访问 | `NodeIP:30000+` |
| LoadBalancer | 生产外部访问 | 云 LB 的外部 IP |
| Headless | 直连特定 Pod | `pod-name.service-name` |
| Ingress | HTTP 路由整合 | 一个 IP + 域名/路径规则 |

## 常见困惑

### 1. Ingress 和 Spring Gateway / 应用网关是什么关系？

角色相同——都是按路径/域名做 HTTP 路由。但层级不同：
- **Ingress** — K8s 集群层面，请求进集群的第一关
- **应用网关**（Spring Gateway / Zuul）— Pod 内部，微服务间的路由

常见架构：`外部 → Ingress → Service → 应用网关 → 具体微服务`。两层各管不同的事，不是替代关系。

### 2. Ingress 和 Service 哪个是"负载均衡"？

不是"更加负载均衡"，是**不同 OSI 层**：
- **Service（L4）** — 只看 IP+端口，在 Pod 之间做 TCP 负载均衡
- **Ingress（L7）** — 看 HTTP 的域名/路径，决定送到**哪个 Service**

实际流程：`请求 → Ingress 选 Service → Service 选 Pod`。两层分工，各做各的。

### 3. Ingress 的后端 Service 为什么用 ClusterIP 就够了？

因为 Ingress Controller 和所有 Service 都在集群内部。Controller 通过 ClusterIP 就能连通后端 Service，不需要把 Service 暴露到集群外。NodePort/LoadBalancer 是给集群外部访问用的。

### 4. kind 环境踩坑

- **多个 Ingress 资源冲突**：如果有旧的 Ingress 资源也匹配了 `/` 路径，会抢流量。我们清理了之前的 `nginx-test` ingress 才让路径路由正常工作。
- **`curl localhost` 不通**：Ingress Controller 的 80 端口映射在 Docker 容器上，不是宿主机。必须 `docker exec` 进节点内测试，或设 port-forward。

1. Ingress 只支持 HTTP/HTTPS 协议。如果你的服务是 TCP 协议（比如 MySQL、Redis），能用 Ingress 吗？（提示：有些 Ingress Controller 支持 TCP stream，但不是标准 Ingress 功能）
2. 本章示例中，`/api` 路径被路由到 api-service，但 api-service 的 nginx 返回的是根路径 `/index.html` 的内容。如果 API 应用期望收到 `/api` 路径（如 `/api/users`），会有什么问题？怎么解决？（提示：看看 `rewrite-target` 注解）
3. 如果 Ingress Controller 的 Pod 挂了，所有通过 Ingress 的请求都会失败。如何提高 Ingress Controller 的高可用性？
4. 为什么 Ingress 的后端 Service 通常用 ClusterIP 类型就够了，不需要 NodePort 或 LoadBalancer？

---

[回到 Chapter 03 目录](../)
