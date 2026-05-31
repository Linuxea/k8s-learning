# 03 - LoadBalancer Service

## 什么是 LoadBalancer

LoadBalancer 是 Service 类型的"终极形态"。它是 NodePort 的升级版：

- **ClusterIP** — 集群内访问
- **NodePort** — ClusterIP + 每个节点开端口
- **LoadBalancer** — NodePort + 云提供商创建外部负载均衡器

```
┌──────────────────────────────────────────────────────────────────┐
│                        云环境                                     │
│                                                                  │
│  ┌─────────────────────────┐                                    │
│  │   Cloud Load Balancer   │ ← 云提供商自动创建和管理             │
│  │   外部 IP: 1.2.3.4      │                                    │
│  └───────────┬─────────────┘                                    │
│              │                                                   │
│              ▼                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    K8s 集群                                │   │
│  │                                                          │   │
│  │  ┌──────────┐    ┌──────────┐                            │   │
│  │  │  Node 1  │    │  Node 2  │   ← 自动分配 NodePort      │   │
│  │  │ :31234   │    │ :31234   │                            │   │
│  │  └────┬─────┘    └────┬─────┘                            │   │
│  │       └───────┬───────┘                                  │   │
│  │               ▼                                          │   │
│  │       ┌──────────────┐                                   │   │
│  │       │   Service    │  ← 自动分配 ClusterIP              │   │
│  │       └──────┬───────┘                                   │   │
│  │              │                                           │   │
│  │       ┌──────┴──────┐                                    │   │
│  │       ▼             ▼                                    │   │
│  │   ┌──────┐    ┌──────┐                                   │   │
│  │   │Pod-1 │    │Pod-2 │                                   │   │
│  │   └──────┘    └──────┘                                   │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘

流量路径: Client → Cloud LB(外部IP) → NodePort → kube-proxy → Pod
```

### 创建 LoadBalancer 时发生了什么

1. K8s 创建 Service，分配 ClusterIP（和 ClusterIP 类型一样）
2. K8s 在每个节点上分配 NodePort（和 NodePort 类型一样）
3. K8s 调用**云提供商的 API**，创建一个外部负载均衡器
4. 云负载均衡器指向所有节点的 NodePort
5. K8s 将云 LB 的外部 IP 写入 Service 的 `EXTERNAL-IP` 字段

所以 LoadBalancer ** = ClusterIP + NodePort + 云负载均衡器**。

## 为什么 LoadBalancer 是生产级方案

| 特性 | NodePort | LoadBalancer |
|------|----------|--------------|
| 外部 IP | 节点 IP（不稳定） | 专用的外部 IP（稳定） |
| 端口 | 30000-32767 | 标准端口（80/443） |
| 健康检查 | 无 | 云 LB 自动检查节点健康 |
| 高可用 | 节点挂了就不能访问 | 自动摘除不健康节点 |
| TLS 终止 | 不支持 | 云 LB 可以处理 |
| DDoS 防护 | 无 | 云提供商提供 |

### LoadBalancer 的局限

虽然 LoadBalancer 解决了 NodePort 的大部分问题，但它有自己的局限：

1. **每个 Service 一个 LB** — 如果你有 10 个服务，就需要 10 个 LB，**费用很高**
2. **无法按域名/路径路由** — 每个 LB 对应一个 Service，不能按 HTTP 路径分流
3. **云锁定** — 不同云提供商的 LB 实现不同

这就是为什么有了 **Ingress**（第 05 节会学）——用一个 LB + 按规则路由，解决"一个 Service 一个 LB"的问题。

## LoadBalancer 在 kind/本地环境中的行为

> **重要提示**：kind 和本地 Minikube 环境**没有云提供商**，所以 LoadBalancer 无法真正工作。

```bash
# 创建 LoadBalancer Service 后查看
kubectl get svc nginx-loadbalancer-svc

# 输出类似：
# NAME                      TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
# nginx-loadbalancer-svc    LoadBalancer   10.96.45.67    <pending>     80:31234/TCP   1m
```

`EXTERNAL-IP` 会一直显示 `<pending>`，因为没人能创建云 LB。

但这并不意味着完全不能用——**NodePort 部分仍然生效**。你可以通过 `NodeIP:31234`（上面 PORT(S) 列里冒号后面的数字）来访问。

### MetalLB：给裸金属/kind 环境添加 LoadBalancer 能力

[MetalLB](https://metallb.universe.tf/) 是一个开源项目，可以在非云环境中提供 LoadBalancer 功能。

原理：它监听 K8s 中 LoadBalancer 类型的 Service，然后从预设的 IP 池中分配一个 IP，通过 ARP/BGP 把流量引导到正确的节点。

在 kind 中安装 MetalLB 的简要步骤：

```bash
# 1. 安装 MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml

# 2. 等待 MetalLB 就绪
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=120s

# 3. 查看 kind 网络的 IP 范围
docker network inspect kind | grep -A 5 "IPAM"

# 4. 配置 IPAddressPool（IP 范围要和 kind 网络在同一段）
# 假设 kind 网络是 172.18.0.0/16，分配 172.18.255.200-172.18.255.250 给 MetalLB
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: example
  namespace: metallb-system
spec:
  addresses:
    - 172.18.255.200-172.18.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: empty
  namespace: metallb-system
EOF

# 5. 现在 LoadBalancer Service 的 EXTERNAL-IP 就不再是 pending 了
```

> MetalLB 的详细配置不在本章范围内，这里只是让你知道在非云环境下也有解决方案。

## Step by Step 实操

### Step 1: 创建 Deployment + LoadBalancer Service

```bash
kubectl apply -f nginx-loadbalancer.yaml

# 输出：
# deployment.apps/nginx-loadbalancer created
# service/nginx-loadbalancer-svc created
```

### Step 2: 观察 Service 状态

```bash
kubectl get svc nginx-loadbalancer-svc

# 在 kind 环境中：
# NAME                      TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
# nginx-loadbalancer-svc    LoadBalancer   10.96.45.67    <pending>     80:31234/TCP   30s

# EXTERNAL-IP 是 <pending>，因为没有云提供商
# 但注意 PORT(S) 列：80:31234/TCP — 31234 是自动分配的 NodePort
```

```bash
# 查看 Service 详情
kubectl describe svc nginx-loadbalancer-svc

# 关注 Events 部分：
# Events:
#   Type    Reason                Age   From                Message
#   Normal  EnsuringLoadBalancer  60s   service-controller  Ensuring load balancer
```

`Ensuring load balancer` 会一直出现，因为 K8s 在持续尝试让云提供商创建 LB。

### Step 3: 通过 NodePort 访问（回退方案）

虽然 LoadBalancer 没分配到外部 IP，但 NodePort 部分是正常的：

```bash
# 查看自动分配的 NodePort（PORT(S) 列冒号后面的数字）
kubectl get svc nginx-loadbalancer-svc -o jsonpath='{.spec.ports[0].nodePort}'
# 比如：31234

# 在 kind 节点内测试
docker exec -it k8s-learning-worker curl -s http://localhost:31234

# 或者用 port-forward
kubectl port-forward svc/nginx-loadbalancer-svc 8080:80
# 另一个终端：
curl http://localhost:8080
```

### Step 4: 如果安装了 MetalLB

```bash
# 查看 EXTERNAL-IP 是否已分配
kubectl get svc nginx-loadbalancer-svc

# 如果 MetalLB 正常工作：
# NAME                      TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)        AGE
# nginx-loadbalancer-svc    LoadBalancer   10.96.45.67    172.18.255.200   80:31234/TCP   2m

# 通过 EXTERNAL-IP 访问
curl http://172.18.255.200
```

### Step 5: 对比三种 Service 类型

```bash
# 如果之前的 ClusterIP 和 NodePort 示例还在，一起查看
kubectl get svc

# 注意 TYPE 和 EXTERNAL-IP 列的区别：
# NAME                    TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)        AGE
# nginx-clusterip-svc     ClusterIP      10.96.198.123   <none>           80/TCP         10m
# nginx-nodeport-svc      NodePort       10.96.124.56    <none>           80:30080/TCP   5m
# nginx-loadbalancer-svc  LoadBalancer   10.96.45.67     172.18.255.200   80:31234/TCP   1m
```

### Step 6: 清理

```bash
kubectl delete -f nginx-loadbalancer.yaml
```

## 三种 Service 类型对比总结

| 特性 | ClusterIP | NodePort | LoadBalancer |
|------|-----------|----------|--------------|
| 集群内访问 | 可以 | 可以 | 可以 |
| 集群外访问 | 不可以 | NodeIP:NodePort | 外部 LB IP |
| 自动 LB | kube-proxy | kube-proxy | 云 LB + kube-proxy |
| 外部 IP | 无 | 无 | 云 LB 分配 |
| 费用 | 无 | 无 | 云 LB 收费 |
| 适用场景 | 内部服务 | 测试/简单暴露 | 生产环境外部访问 |
| 包含关系 | — | ClusterIP + 节点端口 | NodePort + 云 LB |

## 思考题

1. 如果你有 20 个 HTTP 服务需要对外暴露，全部用 LoadBalancer 类型，会有什么问题？（提示：费用、IP 消耗）
2. LoadBalancer Service 在 kind 环境中 EXTERNAL-IP 一直是 `<pending>`，但 NodePort 部分仍然工作。这说明 LoadBalancer 和 NodePort 是什么关系？
3. MetalLB 是如何让非云环境也拥有 LoadBalancer 能力的？它的原理和云提供商的 LB 有什么本质区别？
4. 为什么说 LoadBalancer 解决了 NodePort 的问题，但 Ingress 又解决了 LoadBalancer 的问题？它们各自的痛点是什么？

---

下一个 → [04 - Headless Service](../04-headless-service/)
