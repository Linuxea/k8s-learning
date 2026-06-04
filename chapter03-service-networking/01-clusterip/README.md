# 01 - ClusterIP Service

## 为什么需要 Service

在第一章我们学过 Pod，知道每个 Pod 都有自己的 IP 地址。但 Pod 有一个根本性的问题：

**Pod 是短暂的（ephemeral）。**

- Pod 被删除重建后，IP 会变
- Deployment 扩缩容时，Pod 数量和 IP 都会变
- 滚动更新时，旧 Pod 被新 Pod 替换，IP 全部换掉

如果你的应用 A 硬编码了应用 B 的 Pod IP 来调用，那 B 一旦重建，A 就断了。

Service 就是解决这个问题的——它提供了一个**稳定的虚拟 IP（ClusterIP）和 DNS 名称**，不管背后的 Pod 怎么变，访问 Service 的地址永远不变。

```
┌──────────┐        ┌─────────────┐        ┌──────────┐
│  Pod A   │ ──────►│   Service   │ ──────►│  Pod B-1 │
│ (调用方)  │  访问   │ (稳定入口)   │  转发   │  Pod B-2 │
└──────────┘  固定IP └─────────────┘  负载均衡 └──────────┘
                      10.96.0.100
                      nginx-svc
```

## Service 的发现机制：DNS

K8s 集群内部有一个 DNS 服务（CoreDNS），它自动为每个 Service 创建 DNS 记录：

```
<service-name>.<namespace>.svc.cluster.local
```

比如我们本节创建的 Service 全称是：

```
nginx-clusterip-svc.default.svc.cluster.local
```

| 格式 | 示例 | 使用场景 |
|------|------|---------|
| 全称 | `nginx-clusterip-svc.default.svc.cluster.local` | 跨命名空间访问 |
| 省略集群后缀 | `nginx-clusterip-svc.default.svc` | 较少用 |
| 省略命名空间 | `nginx-clusterip-svc.default` | 跨命名空间时简写 |
| 只写服务名 | `nginx-clusterip-svc` | **最常用**，同命名空间内 |

> 同一个命名空间内，直接用服务名 `nginx-clusterip-svc` 就能访问。这是最常见的方式。

## ClusterIP：默认的 Service 类型

ClusterIP 是 Service 的默认类型。它的特点是：

- **只在集群内部可达** — 分配一个虚拟 IP（ClusterIP），集群内任何 Pod 都能访问
- **外部无法直接访问** — 这个 IP 不会出现在任何节点的网络接口上
- **自动负载均衡** — 请求会被分发到后端的所有 Pod

这是最常用的 Service 类型，适用于：
- 微服务之间的内部调用
- 数据库、缓存等内部服务
- 不需要对外暴露的服务

## ClusterIP 是怎么工作的

Service 的实现依赖三个组件协同工作：

```
┌──────────────────────────────────────────────────────────────┐
│                         K8s 集群                             │
│                                                              │
│  ┌──────────┐    ┌──────────────┐    ┌────────────────────┐ │
│  │ Pod 发起  │    │   kube-proxy │    │ Endpoints/         │ │
│  │ 请求到    │───►│ (每个节点都有) │◄───│ EndpointSlices     │ │
│  │ Service  │    │ iptables/IPVS │    │ (记录后端 Pod IP)   │ │
│  │ ClusterIP│    │ 规则转发      │    │                    │ │
│  └──────────┘    └──────┬───────┘    └────────────────────┘ │
│                         │                                    │
│              ┌──────────┼──────────┐                         │
│              ▼          ▼          ▼                         │
│          ┌──────┐  ┌──────┐  ┌──────┐                       │
│          │Pod-1 │  │Pod-2 │  │Pod-3 │                       │
│          └──────┘  └──────┘  └──────┘                       │
└──────────────────────────────────────────────────────────────┘
```

### 工作流程

1. **API Server** — 你创建 Service 时，K8s 分配一个 ClusterIP，并写入 etcd
2. **Endpoints** — K8s 根据 Service 的 `selector`，自动找到匹配标签的 Pod，把它们的 IP 写入 Endpoints 对象
3. **kube-proxy** — 每个节点上运行的 kube-proxy 监听 Service 和 Endpoints 的变化，在节点上配置 iptables/IPVS 规则
4. **请求转发** — 当 Pod 访问 ClusterIP 时，iptables/IPVS 规则拦截请求，随机/轮询转发到 Endpoints 里的某个 Pod IP

### selector → 标签匹配 → Endpoints 自动管理

```yaml
# Service 的 selector
spec:
  selector:
    app: nginx-clusterip    # ← 找标签为 app=nginx-clusterip 的 Pod
```

```yaml
# Pod 的 labels（在 Deployment 的 template 里）
metadata:
  labels:
    app: nginx-clusterip    # ← 和 Service selector 匹配
```

> selector 和 labels **必须精确匹配**，Service 才能找到 Pod。如果拼写错误或者忘记加标签，Service 的 Endpoints 就是空的，请求会被拒绝。

你可以随时查看 Endpoints：

```bash
# 查看 Service 关联的 Endpoints
kubectl get endpoints nginx-clusterip-svc

# 输出类似：
# NAME                  ENDPOINTS                     AGE
# nginx-clusterip-svc   10.244.1.2:80,10.244.2.3:80   1m
```

`ENDPOINTS` 列显示了当前匹配到的 Pod IP 列表。Pod 增减时，这里会自动更新。

## Step by Step 实操

### Step 1: 确认集群就绪

```bash
kubectl get nodes

# 期望看到 3 个 Ready 节点
```

### Step 2: 创建 Deployment + ClusterIP Service

```bash
kubectl apply -f nginx-clusterip.yaml

# 输出：
# deployment.apps/nginx-clusterip created
# service/nginx-clusterip-svc created
```

### Step 3: 查看创建的资源

```bash
# 查看 Deployment 和 Pod
kubectl get deployment,pods -l app=nginx-clusterip

# 输出类似：
# NAME                               READY   UP-TO-DATE   AVAILABLE   AGE
# deployment.apps/nginx-clusterip    2/2     2            2           30s

# NAME                                   READY   STATUS    RESTARTS   AGE
# pod/nginx-clusterip-xxxxxxxxxx-xxxxx   1/1     Running   0          30s
# pod/nginx-clusterip-xxxxxxxxxx-xxxxx   1/1     Running   0          30s
```

```bash
# 查看 Service
kubectl get svc nginx-clusterip-svc

# 输出类似：
# NAME                  TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
# nginx-clusterip-svc   ClusterIP   10.96.198.123   <none>        80/TCP    1m
```

| 字段 | 含义 |
|------|------|
| `TYPE` | ClusterIP — 集群内部访问 |
| `CLUSTER-IP` | 虚拟 IP，集群内任何 Pod 都可以通过它访问 |
| `EXTERNAL-IP` | `<none>` — ClusterIP 类型没有外部 IP |
| `PORT(S)` | Service 端口/协议 |

```bash
# 查看 Endpoints（Service 关联的 Pod IP）
kubectl get endpoints nginx-clusterip-svc

# 输出类似：
# NAME                  ENDPOINTS                     AGE
# nginx-clusterip-svc   10.244.1.2:80,10.244.2.3:80   1m
```

### Step 4: 从集群内部访问 Service

ClusterIP 只能在集群内部访问，我们用一个临时 Pod 来测试：

```bash
# 启动一个临时 busybox Pod，在它里面测试 DNS 和访问
kubectl run test-pod --image=busybox:1.36 --rm -it --restart=Never -- sh

# 进入 Pod 后执行以下命令：

# 1. 通过 Service 名称访问（DNS 解析）
wget -qO- http://nginx-clusterip-svc
# 你会看到 nginx 默认欢迎页的 HTML

# 2. 查看 DNS 解析结果
nslookup nginx-clusterip-svc
# Server:    10.96.0.10
# Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local
# Name:      nginx-clusterip-svc
# Address 1: 10.96.198.123 nginx-clusterip-svc.default.svc.cluster.local

# 3. 通过 ClusterIP 直接访问
wget -qO- http://10.96.198.123
# 同样能访问到

# 4. 用全称域名访问
wget -qO- http://nginx-clusterip-svc.default.svc.cluster.local

# 退出临时 Pod
exit
```

> `--rm` 参数表示 Pod 退出后自动删除。`-it` 表示交互式终端。

### Step 5: 删除一个 Pod，观察 Service 依然正常

这是 Service 最核心的价值——后端 Pod 变化不影响访问。

```bash
# 查看当前 Pod
kubectl get pods -l app=nginx-clusterip -o wide

# 输出类似：
# NAME                               READY   STATUS    IP           NODE
# nginx-clusterip-xxxxxxxxxx-abcde   1/1     Running   10.244.1.2   k8s-learning-worker
# nginx-clusterip-xxxxxxxxxx-fghij   1/1     Running   10.244.2.3   k8s-learning-worker2
```

```bash
# 记住其中一个 Pod 名，然后删掉它
kubectl delete pod <某个pod名>

# Deployment 会自动创建新 Pod 来维持 replicas: 2
kubectl get pods -l app=nginx-clusterip -o wide
# 你会看到一个新 Pod 正在创建/已就绪，IP 已经变了
```

```bash
# 但 Service 的 IP 没变！再次访问
kubectl run test-pod --image=busybox:1.36 --rm -it --restart=Never -- wget -qO- http://nginx-clusterip-svc

# 依然能正常访问——这就是 Service 的意义
```

```bash
# 查看 Endpoints 更新
kubectl get endpoints nginx-clusterip-svc
# 你会看到 IP 列表已经更新为新 Pod 的 IP
```

### Step 6: 清理

```bash
kubectl delete -f nginx-clusterip.yaml
```

## 小结

| 特性 | 说明 |
|------|------|
| 访问范围 | 仅集群内部 |
| 默认类型 | 是（`type: ClusterIP` 可省略） |
| 稳定入口 | ClusterIP + DNS 名称 |
| 负载均衡 | 自动轮询后端 Pod |
| 后端管理 | selector 匹配 Pod 标签，自动维护 Endpoints |
| 适用场景 | 微服务间调用、数据库、缓存等内部服务 |

## 常见困惑

1. **busybox `nslookup` 报 NXDOMAIN，DNS 解析失败了？** — 不是失败，是 `nslookup` 按 `/etc/resolv.conf` 里的 search 域逐个尝试拼接域名。它先试 `nginx-clusterip-svc.cluster.local`（NXDOMAIN），再试 `nginx-clusterip-svc.svc.cluster.local`（NXDOMAIN），最终试到 `nginx-clusterip-svc.default.svc.cluster.local` 才匹配成功。看输出里有 `Name: ... Address: 10.96.x.x` 这行就是解析成功了，前面的 NXDOMAIN 可以忽略。**同一个 namespace 内直接用服务名就行**，CoreDNS 会自动补全 search domain。

2. **直接访问 Pod IP 也能通，那 Service 还提供了什么价值？** — 直接访问 Pod IP 本身是可达的，问题不在"能不能访问"，而在于"稳不稳定"。Pod 重建后 IP 会变，你写死在代码里的 IP 就失效了。Service 提供了：①**稳定入口**（DNS 名称不变）②**负载均衡**（多个后端 Pod 时自动分发请求）。你的代码永远用 `http://nginx-clusterip-svc` 就行，不管背后换了几批 Pod。

3. **ClusterIP 是个虚拟 IP，不绑定任何网卡，数据包怎么转发的？** — 靠 `kube-proxy`（每个节点上的 DaemonSet）监听 Service 和 Endpoints 的变化，在节点内核写入 **iptables/IPVS 规则**。Pod 发出的请求到达 ClusterIP 时，iptables 规则在内核层面做 DNAT（目标地址转换），把目标 IP 从 ClusterIP 改写为某个后端 Pod 的 IP，然后正常路由过去。整个过程对应用透明，不需要额外的代理进程。

4. **Service 的负载均衡是真正轮询吗？** — 默认 iptables 模式下是**随机选择**，不是轮询（round-robin）。小样本下可能不均匀，但理论上长期趋近均匀分布。如果用 IPVS 模式（`kube-proxy --proxy-mode=ipvs`），可以配置轮询、最少连接等更丰富的调度算法。

## 思考题

1. 如果 Service 的 `selector` 里写错了标签名（比如写成了 `app: nginx-wrong`），访问 Service 会发生什么？怎么排查？
2. ClusterIP 是一个虚拟 IP，它不会出现在任何网卡的 IP 列表里。那数据包是怎么被正确路由到后端 Pod 的？
3. 一个 Service 可以同时匹配不同 Deployment 管理的 Pod 吗？需要满足什么条件？
4. 如果两个 Service 的 selector 匹配到了同一组 Pod，会发生什么？这是好的设计吗？

---

下一个 → [02 - NodePort Service](../02-nodeport/)
