# 03 - NetworkPolicy：Pod 网络防火墙

## 默认行为：全部互通

Kubernetes 的网络模型有一个基本假设：**所有 Pod 之间可以直接通信，不需要 NAT**。

这意味着，默认情况下：

```
┌──────────────────────────────────────────────────┐
│              Kubernetes 集群网络                    │
│                                                  │
│  ┌─────────┐    ┌─────────┐    ┌─────────┐      │
│  │ Pod A   │◄──►│ Pod B   │◄──►│ Pod C   │      │
│  │ frontend│    │ backend │    │ database│      │
│  └─────────┘    └─────────┘    └─────────┘      │
│                                                  │
│  任意 Pod 可以访问任意 Pod，没有隔离               │
└──────────────────────────────────────────────────┘
```

这个设计简化了服务发现和通信，但也带来了安全风险：如果你的数据库 Pod 可以被任何 Pod 访问，一个被入侵的前端 Pod 就能直接读取数据库数据。

**NetworkPolicy 就是用来解决这个问题的 —— 它是 Pod 级别的防火墙规则。**

## NetworkPolicy 是什么

NetworkPolicy 是一个 K8s 资源，它定义了 **哪些 Pod 可以和哪些 Pod 通信，以及通过哪些端口**。

关键概念：

| 概念 | 说明 |
|------|------|
| **Pod 选择器** | 选择 Policy 应用到哪些 Pod |
| **Ingress 规则** | 控制哪些流量**可以进入**选中的 Pod |
| **Egress 规则** | 控制选中的 Pod **可以发出**哪些流量 |
| **Policy 类型** | 指定规则对入站、出站还是两者生效 |

> NetworkPolicy 是**声明式**的：你声明"允许什么"，而不是"阻止什么"。没有被任何规则允许的流量都会被拒绝。

## CNI 插件的限制

NetworkPolicy 的**声明**是 Kubernetes API 的一部分，但**执行**依赖 CNI（Container Network Interface）插件。

| CNI 插件 | 支持 NetworkPolicy | 说明 |
|-----------|-------------------|------|
| Calico | 完整支持 | 企业级，功能最全 |
| Cilium | 完整支持 | 基于 eBPF，性能好 |
| Flannel | **不支持** | 只提供网络连通，无策略 |
| Weave | 支持 | 中等 |
| kindnet（kind 默认） | 基本支持 | 支持简单的 Ingress/Egress 策略 |

> 如果 CNI 插件不支持 NetworkPolicy，你创建了 Policy 也不会报错，但**不会生效**。这是一个容易踩的坑。kind 的 kindnet 支持基本的 NetworkPolicy 功能，足够学习使用。

## NetworkPolicy 的选择器

NetworkPolicy 用三种选择器来匹配流量来源或目标：

| 选择器 | 匹配方式 | 使用场景 |
|--------|---------|---------|
| `podSelector` | 匹配同一命名空间内的 Pod（通过标签） | 允许 frontend Pod 访问 backend Pod |
| `namespaceSelector` | 匹配整个命名空间（通过命名空间标签） | 允许 monitoring 命名空间的所有 Pod 访问 |
| `ipBlock` | 匹配 IP 地址段（CIDR） | 允许外部 IP 段访问，或允许 Pod 访问外部网络 |

> `podSelector` 和 `namespaceSelector` 可以组合使用（AND 关系），也可以单独使用。

## 工作机制详解

NetworkPolicy 是**白名单**机制：

1. 如果一个 Pod **没有被任何 NetworkPolicy 选中**，则所有流量都允许（默认行为）
2. 如果一个 Pod **被 NetworkPolicy 选中**，则只有规则明确允许的流量才能通过
3. 多个 NetworkPolicy 是**累加**的 —— 只要被任何一个规则允许就可以

```
Pod 被选中了吗？
    │
    ├── 否 → 所有流量允许（默认行为）
    │
    └── 是 → 检查每条连接
              │
              ├── 匹配到允许规则 → 放行
              └── 没有匹配的规则 → 拒绝
```

## Step by Step：NetworkPolicy 实验

我们的目标：创建 frontend 和 backend 两个 Deployment，先验证它们可以互相通信，然后用 NetworkPolicy 限制只有 frontend 才能访问 backend。

### Step 1: 创建命名空间和 Deployment

```bash
# 创建命名空间
kubectl create namespace netpol-demo

# 创建 backend Deployment
kubectl apply -f backend-deployment.yaml

# 创建 frontend Deployment
kubectl apply -f frontend-deployment.yaml

# 等待 Pod 就绪
kubectl wait --for=condition=Ready pod -l app=backend -n netpol-demo --timeout=30s
kubectl wait --for=condition=Ready pod -l app=frontend -n netpol-demo --timeout=30s

# 查看所有 Pod
kubectl get pods -n netpol-demo -o wide
# NAME                        READY   STATUS    IP           ...
# backend-xxxxxxxxxx-xxxxx     1/1     Running   10.244.x.x   ...
# frontend-xxxxxxxxxx-xxxxx    1/1     Running   10.244.x.x   ...
```

### Step 2: 验证默认可以通信

```bash
# 获取 backend Pod 的 IP
BACKEND_IP=$(kubectl get pods -l app=backend -n netpol-demo -o jsonpath='{.items[0].status.podIP}')

echo "Backend Pod IP: $BACKEND_IP"

# 从 frontend Pod 访问 backend（应该成功）
kubectl exec -n netpol-demo deployment/frontend -- \
  curl -s --max-time 5 http://$BACKEND_IP:80

# 你应该能看到 nginx 的默认页面
```

### Step 3: 应用"拒绝所有入站"策略

```bash
kubectl apply -f deny-all-policy.yaml

# 等几秒让策略生效
sleep 3
```

### Step 4: 再次验证通信（应该被拒绝）

```bash
# 从 frontend 访问 backend（现在应该超时或失败）
kubectl exec -n netpol-demo deployment/frontend -- \
  curl -s --max-time 5 http://$BACKEND_IP:80

# 会超时，因为 deny-all 策略拒绝了所有入站流量
```

### Step 5: 应用"只允许 frontend"策略

```bash
kubectl apply -f allow-frontend-policy.yaml

# 等几秒让策略生效
sleep 3
```

### Step 6: 验证 frontend 可以访问 backend

```bash
# 从 frontend 访问 backend（应该恢复）
kubectl exec -n netpol-demo deployment/frontend -- \
  curl -s --max-time 5 http://$BACKEND_IP:80

# 应该能看到 nginx 的默认页面
```

### Step 7: 验证其他 Pod 不能访问 backend

```bash
# 创建一个临时的"攻击者" Pod
kubectl run attacker --image=busybox -n netpol-demo --rm -it --restart=Never -- \
  wget -qO- --timeout=5 http://$BACKEND_IP:80

# 应该超时，因为 attacker Pod 没有被 NetworkPolicy 允许
```

### Step 8: 查看 NetworkPolicy

```bash
# 列出所有 NetworkPolicy
kubectl get networkpolicy -n netpol-demo

# 查看策略详情
kubectl describe networkpolicy deny-all-ingress -n netpol-demo
kubectl describe networkpolicy allow-frontend -n netpol-demo
```

### Step 9: 清理

```bash
kubectl delete namespace netpol-demo
```

## YAML 详解

### deny-all-policy.yaml

这是最严格的策略：拒绝所有入站流量。**这是零信任网络的最佳起点 —— 默认拒绝，按需放行。**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: netpol-demo
spec:
  podSelector: {}       # 空选择器 = 选中命名空间内所有 Pod
  policyTypes:
    - Ingress           # 只控制入站流量
  ingress: []           # 空规则 = 没有允许的入站流量 = 拒绝所有
```

关键点：

| 字段 | 说明 |
|------|------|
| `podSelector: {}` | 空的 `podSelector` 匹配命名空间内的**所有** Pod |
| `policyTypes: ["Ingress"]` | 声明此策略对入站流量生效 |
| `ingress: []` | 空的 ingress 规则列表 = 没有任何入站流量被允许 |

### allow-frontend-policy.yaml

允许带有 `app: frontend` 标签的 Pod 访问 backend 的 80 端口：

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend
  namespace: netpol-demo
spec:
  podSelector:
    matchLabels:
      app: backend        # 策略应用到 app=backend 的 Pod
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend    # 只允许 app=frontend 的 Pod
      ports:
        - port: 80             # 只允许 80 端口
```

关键点：

| 字段 | 说明 |
|------|------|
| `podSelector.matchLabels.app: backend` | 策略保护的目标是 `app=backend` 的 Pod |
| `ingress[].from[].podSelector` | 允许的来源：`app=frontend` 的 Pod |
| `ingress[].ports[].port: 80` | 只开放 80 端口 |

> 注意：`from` 下的 `podSelector` 只能匹配**同一命名空间**的 Pod。如果要跨命名空间，需要使用 `namespaceSelector`。

## 常见 NetworkPolicy 模式

### 允许特定命名空间访问

```yaml
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            environment: production    # 只允许有此标签的命名空间
```

> 命名空间标签需要手动添加：`kubectl label namespace production environment=production`

### 允许特定命名空间的特定 Pod

```yaml
ingress:
  - from:
      # podSelector 和 namespaceSelector 在同一个 from 条目中是 AND 关系
      - namespaceSelector:
          matchLabels:
            environment: production
        podSelector:
          matchLabels:
            role: frontend
```

### 允许访问外部网络（Egress）

```yaml
egress:
  - to:
      - ipBlock:
          cidr: 0.0.0.0/0           # 所有目标
          except:
            - 10.0.0.0/8            # 但不允许访问内网
            - 172.16.0.0/12
            - 192.168.0.0/16
    ports:
      - port: 53
        protocol: UDP               # 允许 DNS
      - port: 443
        protocol: TCP               # 允许 HTTPS
```

### 允许 DNS（常见需求）

任何需要域名解析的 Pod 都需要允许 DNS 流量：

```yaml
egress:
  - to:
      - namespaceSelector: {}        # 所有命名空间
    ports:
      - port: 53
        protocol: UDP
      - port: 53
        protocol: TCP
```

> **常见错误**：应用了 egress deny-all 策略后，Pod 内无法解析域名。这是因为 DNS 流量也被阻止了。解决方法：在 egress 规则中放行 53 端口。

## 生产环境的最佳实践

| 实践 | 说明 |
|------|------|
| **默认拒绝** | 先应用 deny-all 策略，再按需放行 |
| **最小端口** | 只开放应用实际使用的端口 |
| **限制来源** | 不要用空的 `from: []`（等于允许所有） |
| **考虑 DNS** | Egress 策略别忘了放行 DNS |
| **命名空间隔离** | 用 `namespaceSelector` 做粗粒度隔离 |
| **标签规范** | 确保 Pod 和 Namespace 的标签一致且规范 |

## 关键概念总结

| 概念 | 要点 |
|------|------|
| 默认行为 | 所有 Pod 可以互相通信，没有隔离 |
| NetworkPolicy | Pod 级别的防火墙，白名单机制 |
| Ingress | 控制入站流量 |
| Egress | 控制出站流量 |
| podSelector | 选择策略应用的 Pod，以及允许的来源/目标 Pod |
| namespaceSelector | 按命名空间选择 |
| ipBlock | 按 IP CIDR 选择 |
| 依赖 CNI | Policy 需要支持 NetworkPolicy 的 CNI 插件才能生效 |

## 思考题

1. 如果你创建了一个 NetworkPolicy 但 CNI 插件不支持（比如 Flannel），会发生什么？为什么这样设计而不是直接报错？
2. `deny-all` 策略的 `podSelector: {}` 和不写 `podSelector` 有什么区别？提示：不写会怎样？
3. 如果同时有 `deny-all-ingress` 和 `allow-frontend` 两个策略作用于同一个 Pod，最终效果是什么？为什么？
4. 为什么说 "default deny + 按需放行" 比 "default allow + 按需阻止" 更安全？

---

下一个 → [04 - Pod Security Context](../04-pod-security-context/)
