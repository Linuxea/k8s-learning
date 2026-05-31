# 02 - NodePort Service

## 什么是 NodePort

上一节学的 ClusterIP 只能在集群内部访问。那如果你需要从集群**外部**访问服务呢？

NodePort 是最简单的方式：它在**每个节点**上开放一个固定的端口（默认范围 30000-32767），外部可以通过 `任意节点IP:NodePort` 访问到你的服务。

```
┌────────────────────────────────────────────────────────────────┐
│                        K8s 集群                                 │
│                                                                │
│  ┌─────────────────┐    ┌─────────────────┐                    │
│  │   Node 1        │    │   Node 2        │                    │
│  │   kube-proxy    │    │   kube-proxy    │                    │
│  │   :30080 监听   │    │   :30080 监听   │                    │
│  └────────┬────────┘    └────────┬────────┘                    │
│           │                      │                             │
│           └──────────┬───────────┘                             │
│                      ▼                                         │
│              ┌──────────────┐                                  │
│              │   Service    │                                  │
│              │ (ClusterIP)  │                                  │
│              └──────┬───────┘                                  │
│                     │                                          │
│           ┌─────────┼─────────┐                                │
│           ▼         ▼         ▼                                │
│       ┌──────┐ ┌──────┐ ┌──────┐                              │
│       │Pod-1 │ │Pod-2 │ │Pod-3 │                              │
│       └──────┘ └──────┘ └──────┘                              │
└────────────────────────────────────────────────────────────────┘

外部请求: Client → NodeIP:30080 → kube-proxy → Pod
```

### 流量路径

```
Client
  → NodeIP:30080 (任何一个节点的 IP + NodePort 端口)
    → kube-proxy (iptables/IPVS 规则)
      → Pod (可能在任意节点上，不一定是接收请求的那个节点)
```

> 关键点：即使请求打到 Node 1 上，最终可能被转发到 Node 2 上的 Pod。kube-proxy 不关心 Pod 在哪个节点，它只做负载均衡。

## NodePort 的端口范围

| 配置 | 默认值 | 说明 |
|------|--------|------|
| 端口范围 | 30000-32767 | 由 API Server 的 `--service-node-port-range` 参数控制 |
| 自动分配 | 不指定 `nodePort` 时 | K8s 从范围内随机选一个可用端口 |
| 手动指定 | 指定 `nodePort: 30080` | 你自己选一个端口，必须范围内且未被占用 |

> 一般建议手动指定 `nodePort`，这样文档化和运维时更清晰。自动分配的端口号不直观，也不方便沟通。

## 什么时候用 NodePort

NodePort 的定位是：

- **简单外部访问** — 快速让外部能访问到服务
- **测试和开发环境** — 不需要复杂的负载均衡器
- **前提条件** — 你能访问到节点的 IP

**不推荐在生产环境直接使用**，原因：

1. **端口范围受限** — 只能用 30000-32767，不是标准端口（80/443）
2. **端口冲突** — 每个端口只能给一个 Service 用
3. **需要知道节点 IP** — 客户端需要知道节点的 IP 地址，节点挂了就不行
4. **没有健康检查** — 节点故障时不会自动摘除
5. **没有 TLS 终止** — 需要自己在应用层处理 HTTPS

生产环境应该用 LoadBalancer 或 Ingress（后面的章节会学）。

## Step by Step 实操

### Step 1: 创建 Deployment + NodePort Service

```bash
kubectl apply -f nginx-nodeport.yaml

# 输出：
# deployment.apps/nginx-nodeport created
# service/nginx-nodeport-svc created
```

### Step 2: 查看 Service

```bash
kubectl get svc nginx-nodeport-svc

# 输出类似：
# NAME                  TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
# nginx-nodeport-svc    NodePort   10.96.124.56    <none>        80:30080/TCP   30s
```

| 字段 | 含义 |
|------|------|
| `TYPE` | NodePort — 比 ClusterIP 多了节点端口映射 |
| `CLUSTER-IP` | 依然有 ClusterIP，集群内访问照常 |
| `PORT(S)` | `80:30080/TCP` — Service 端口 80，NodePort 端口 30080 |

注意 NodePort **同时拥有 ClusterIP 的所有能力**。它本质上是在 ClusterIP 的基础上，额外在每个节点上开放了一个端口。

### Step 3: 查看 Endpoints

```bash
kubectl get endpoints nginx-nodeport-svc

# 确认 Service 关联到了正确的 Pod
```

### Step 4: 从集群外部访问

首先确认节点 IP：

```bash
# 查看节点信息
kubectl get nodes -o wide

# 输出类似：
# NAME                         STATUS   ROLES           AGE   VERSION   INTERNAL-IP
# k8s-learning-control-plane   Ready    control-plane   1h    v1.31.0   172.18.0.4
# k8s-learning-worker          Ready    <none>          1h    v1.31.0   172.18.0.3
# k8s-learning-worker2         Ready    <none>          1h    v1.31.0   172.18.0.2
```

> **在 kind 环境中**，节点 IP 是 Docker 容器的内部 IP，不能直接从宿主机外部访问。
> 要测试 NodePort，需要在宿主机（kind 所在的 Docker 环境）内部访问。

```bash
# 方法一：在宿主机上用 docker exec 进入 kind 节点容器内测试
docker exec -it k8s-learning-worker curl -s http://localhost:30080

# 方法二：用 kubectl 的 port-forward 转发来模拟（虽然不是 NodePort 的真实路径）
kubectl port-forward svc/nginx-nodeport-svc 8080:80
# 然后在另一个终端：
curl http://localhost:8080
```

如果你用的是云服务器（如 Chapter 00 中的 Lightsail），并且防火墙放行了 30080 端口：

```bash
# 从你本机直接访问（需要 Lightsail 的公网 IP）
curl http://<Lightsail公网IP>:30080

# 看到 nginx 欢迎页就成功了
```

### Step 5: 测试负载均衡

```bash
# 多次请求，观察响应
kubectl run test-pod --image=busybox:1.36 --rm -it --restart=Never -- sh

# 在 Pod 内多次请求
for i in $(seq 1 10); do
  wget -qO- http://nginx-nodeport-svc 2>/dev/null | grep "Welcome"
done

# 每次请求可能被分发到不同的 Pod（可以看到 Pod 日志验证）
exit
```

### Step 6: 观察每个节点都有 NodePort

```bash
# 在任意 kind 节点容器内查看 30080 端口监听
docker exec k8s-learning-worker ss -tlnp | grep 30080
docker exec k8s-learning-worker2 ss -tlnp | grep 30080

# 两个 worker 节点都应该在监听 30080 端口
# 即使 Pod 只在其中一个节点上，所有节点都会监听 NodePort
```

> 这是 NodePort 的一个重要特性：**所有节点都会监听 NodePort 端口**，不管 Pod 在不在那个节点上。kube-proxy 负责把请求转发到正确的 Pod。

### Step 7: 清理

```bash
kubectl delete -f nginx-nodeport.yaml
```

## NodePort vs ClusterIP 对比

| 特性 | ClusterIP | NodePort |
|------|-----------|----------|
| 集群内访问 | 可以 | 可以 |
| 集群外访问 | 不可以 | 可以（通过 NodeIP:NodePort） |
| 端口范围 | 任意 | 30000-32767 |
| 每个节点的端口 | 无 | 都监听 |
| 生产环境推荐 | 内部服务用 | 一般不直接用 |
| 包含关系 | — | NodePort = ClusterIP + 节点端口 |

## 思考题

1. 如果你的 Service 指定了 `nodePort: 30080`，但这个端口已经被另一个 Service 占用了，会发生什么？
2. NodePort 模式下，如果客户端通过 Node1 的 IP 访问，但 Pod 只在 Node2 上，流量路径是怎样的？会有性能问题吗？
3. 为什么 NodePort 不推荐在生产环境使用？如果要对外暴露 HTTP 服务，更好的方案是什么？
4. 如果一个节点宕机了，通过这个节点的 IP:NodePort 还能访问到服务吗？这说明 NodePort 有什么缺陷？

---

下一个 → [03 - LoadBalancer Service](../03-loadbalancer/)
