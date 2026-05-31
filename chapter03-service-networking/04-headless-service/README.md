# 04 - Headless Service

## 什么是 Headless Service

前面三节学的 Service（ClusterIP、NodePort、LoadBalancer）都有一个共同特点：**它们提供一个虚拟 IP，请求被负载均衡到后端 Pod**。你不需要关心请求具体到了哪个 Pod。

但有时候你**需要知道具体的 Pod 是谁**。比如：

- 数据库集群中每个节点有不同角色（主/从），你需要明确连接主节点
- 分布式缓存中每个节点负责不同的数据分片
- StatefulSet 中每个 Pod 需要有稳定的网络标识

Headless Service 就是为此而生——设置 `clusterIP: None`，**不分配虚拟 IP，DNS 直接返回 Pod IP**。

```
普通 Service 的 DNS 解析：
  nginx-svc → 10.96.0.100 (一个虚拟 IP，背后负载均衡)

Headless Service 的 DNS 解析：
  nginx-headless-svc → 10.244.1.2, 10.244.2.3, 10.244.1.5 (直接返回所有 Pod IP)
```

## 为什么需要 Headless Service

### 场景一：StatefulSet

StatefulSet 是 K8s 管理有状态应用的控制器（后面的章节会学）。它给每个 Pod 一个**有序的名字**：

```
mysql-0, mysql-1, mysql-2
```

配合 Headless Service，每个 Pod 都有自己的 DNS 记录：

```
mysql-0.mysql-headless.default.svc.cluster.local  → Pod mysql-0 的 IP
mysql-1.mysql-headless.default.svc.cluster.local  → Pod mysql-1 的 IP
mysql-2.mysql-headless.default.svc.cluster.local  → Pod mysql-2 的 IP
```

这样，应用可以通过固定的 DNS 名找到特定的 Pod，不管 Pod 被重建后 IP 怎么变。

### 场景二：服务发现

某些应用（如 Cassandra、Elasticsearch）需要知道集群中所有节点的地址来组建集群。Headless Service 的 DNS 查询会返回所有 Pod IP，正好满足这个需求。

### 场景三：客户端负载均衡

有时候你不想用 K8s 内置的负载均衡（kube-proxy 的随机/轮询），而是想自己在客户端做负载均衡策略（一致性哈希、加权轮询等）。Headless Service 把所有 Pod IP 都给你，由你决定怎么分发。

## Headless Service vs 普通 Service

| 特性 | 普通 Service | Headless Service |
|------|-------------|-----------------|
| ClusterIP | 分配虚拟 IP | `None`（不分配） |
| DNS 查询 | 返回 Service 的虚拟 IP | 返回所有 Pod IP |
| 负载均衡 | kube-proxy 自动做 | **没有**，客户端自己决定 |
| Pod 级 DNS | 不支持 | `pod-name.svc.ns.svc.cluster.local` |
| Endpoints | 有 | 有 |
| 适用场景 | 无状态服务 | 有状态服务、需要直连 Pod |

### DNS 解析差异

```bash
# 普通 Service
nslookup nginx-clusterip-svc
# → 返回 1 个 IP: 10.96.198.123 (Service 的 ClusterIP)

# Headless Service
nslookup nginx-headless-svc
# → 返回多个 IP:
#   10.244.1.2
#   10.244.2.3
#   10.244.1.5
# (所有匹配 Pod 的 IP)
```

## Headless Service 的 DNS 记录

当 Headless Service 和 Pod 配合使用时，CoreDNS 会创建两类记录：

### 1. Service 级别的 DNS

```
nginx-headless-svc.default.svc.cluster.local
```

查询这个域名，返回所有匹配 Pod 的 IP 地址（A 记录）。

### 2. Pod 级别的 DNS

```
<pod-name>.nginx-headless-svc.default.svc.cluster.local
```

查询这个域名，返回**特定 Pod 的 IP**。

> Pod 级别的 DNS 需要 Pod 有一个规范化的名字（小写字母、数字、短横线）。
> Deployment 创建的 Pod 名字包含随机后缀（如 `nginx-headless-7d4f9b6c4d-abcde`），虽然也能解析，
> 但更常见的用法是配合 StatefulSet 的有序命名（如 `mysql-0`、`mysql-1`）。

## Step by Step 实操

### Step 1: 创建 Deployment + Headless Service

```bash
kubectl apply -f nginx-headless.yaml

# 输出：
# deployment.apps/nginx-headless created
# service/nginx-headless-svc created
```

### Step 2: 查看 Service

```bash
kubectl get svc nginx-headless-svc

# 输出类似：
# NAME                  TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
# nginx-headless-svc    ClusterIP   None         <none>        80/TCP    30s
```

注意 `CLUSTER-IP` 列是 **`None`**，这就是 Headless Service 的标志。

> Headless Service 的 TYPE 仍然显示 `ClusterIP`，但 ClusterIP 值是 `None`。

### Step 3: 查看 Endpoints

```bash
kubectl get endpoints nginx-headless-svc

# 输出类似：
# NAME                  ENDPOINTS                                AGE
# nginx-headless-svc   10.244.1.2:80,10.244.2.3:80,10.244.1.5:80  1m
```

Endpoints 还是正常的——Headless Service 仍然通过 selector 找到 Pod，只是不再做负载均衡。

### Step 4: DNS 解析对比

启动一个临时 Pod 来测试 DNS：

```bash
kubectl run dns-test --image=busybox:1.36 --rm -it --restart=Never -- sh
```

在 Pod 内执行：

```sh
# 1. 解析 Headless Service — 返回所有 Pod IP
nslookup nginx-headless-svc

# 输出类似：
# Server:    10.96.0.10
# Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local
# Name:      nginx-headless-svc
# Address 1: 10.244.1.2 nginx-headless-xxxxxxxxxx-abcde
# Address 2: 10.244.2.3 nginx-headless-xxxxxxxxxx-fghij
# Address 3: 10.244.1.5 nginx-headless-xxxxxxxxxx-klmno

# 注意：返回了 3 个 IP（因为有 3 个 Pod），而不是一个 Service IP

# 2. 对比：如果你还留着之前的 ClusterIP Service
nslookup nginx-clusterip-svc
# → 只返回一个 ClusterIP（虚拟 IP）

# 3. 尝试解析特定 Pod 的 DNS
# 先查看 Pod 名
# exit 退出后执行 kubectl get pods -l app=nginx-headless
# 然后用 Pod 名解析

# 退出
exit
```

```bash
# 先看看 Pod 名字
kubectl get pods -l app=nginx-headless -o custom-columns=NAME:.metadata.name,IP:.status.podIP

# 输出类似：
# NAME                                IP
# nginx-headless-7d4f9b6c4d-abcde     10.244.1.2
# nginx-headless-7d4f9b6c4d-fghij     10.244.2.3
# nginx-headless-7d4f9b6c4d-klmno     10.244.1.5
```

```bash
# 用 Pod 名解析（注意：Deployment Pod 名含随机后缀，也能解析）
kubectl run dns-test2 --image=busybox:1.36 --rm -it --restart=Never -- sh

# 在 Pod 内：
nslookup nginx-headless-7d4f9b6c4d-abcde.nginx-headless-svc.default.svc.cluster.local
# → 返回这个 Pod 的 IP: 10.244.1.2

exit
```

### Step 5: 直接用 IP 访问 Pod

```bash
kubectl run access-test --image=busybox:1.36 --rm -it --restart=Never -- sh

# 在 Pod 内直接用 Pod IP 访问（绕过 Service）
wget -qO- http://10.244.1.2
# 只会访问这一个 Pod，不会负载均衡

# 用 Headless Service 名称访问
wget -qO- http://nginx-headless-svc
# DNS 返回所有 IP，busybox 的 wget 会选第一个
# 不同的客户端库处理多 IP 的方式不同

exit
```

### Step 6: 观察 Pod 重建后 DNS 更新

```bash
# 删除一个 Pod
kubectl delete pod <某个pod名>

# 等 Deployment 重建新 Pod
kubectl get pods -l app=nginx-headless -o wide

# 再次查看 Endpoints
kubectl get endpoints nginx-headless-svc
# IP 列表已更新
```

### Step 7: 清理

```bash
kubectl delete -f nginx-headless.yaml
```

## Headless Service 的 Endpoints 是如何工作的

你可能好奇：既然 Headless Service 没有 ClusterIP，那 Endpoints 对象还有什么用？

答案是：**Endpoints 对象仍然是 Service 和 Pod 之间的桥梁**。K8s 控制器根据 selector 找到匹配的 Pod，把它们的 IP 写入 Endpoints。CoreDNS 通过 watch Endpoints 对象来维护 DNS 记录。

```
Pod (labels) → Service (selector) → Endpoints (IP list) → CoreDNS (DNS records)
```

对于 Headless Service：
- Endpoints 里的 IP 列表 → 变成多条 DNS A 记录
- 每个 Pod 名 → 变成单独的 DNS A 记录

## 小结

| 使用场景 | Service 类型 | 原因 |
|---------|-------------|------|
| 无状态 Web 服务 | ClusterIP | 只需负载均衡，不关心具体哪个 Pod |
| 外部测试访问 | NodePort | 需要从集群外访问 |
| 生产外部访问 | LoadBalancer | 需要稳定外部 IP + 云 LB |
| 有状态服务（数据库） | **Headless** | 每个节点需要独立 DNS，客户端直连 |
| 服务发现（集群组建） | **Headless** | 需要知道所有节点地址 |
| 客户端自定义负载均衡 | **Headless** | 拿到所有 IP 自己决定 |

## 思考题

1. Headless Service 没有虚拟 IP，那客户端访问 `nginx-headless-svc` 时，请求是怎么到达 Pod 的？（提示：DNS 返回多个 IP，客户端怎么选？）
2. 为什么说 Headless Service 是 StatefulSet 的"最佳搭档"？如果没有 Headless Service，StatefulSet 里的 Pod 还能有稳定的 DNS 名吗？
3. 如果 Headless Service 的 selector 没有匹配到任何 Pod，DNS 解析会返回什么？
4. Headless Service 和普通 Service 的 Endpoints 对象结构是一样的吗？你能想到它们在哪些场景下行为不同？

---

下一个 → [05 - Ingress](../05-ingress/)
