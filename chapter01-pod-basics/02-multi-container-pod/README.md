# 02 - 多容器 Pod

## 为什么要把多个容器放在一个 Pod 里

上一节我们创建了只有一个容器的 Pod —— 这是大多数场景。但有时候，一个容器"不够用"。

考虑一个现实场景：你有一个 nginx 服务，需要有人定期更新它的首页内容。你可以：
1. 在 nginx 容器里加一个 cron 任务 —— 但这违反了"一个容器只做一件事"的原则
2. 创建两个独立的 Pod —— 但它们需要共享文件系统，还要保证调度到同一节点，太复杂了

**多容器 Pod** 就是解决这类问题的。同一个 Pod 内的容器天然享有：

| 共享资源 | 说明 |
|---------|------|
| **网络命名空间** | 同一个 IP，通过 `localhost` 互相访问 |
| **存储卷（Volume）** | 可以挂载同一个 Volume 来共享文件 |
| **调度位置** | 永远被调度到同一个节点上，不会被分开 |
| **生命周期** | 同时创建、同时销毁（几乎） |

> 多容器 Pod 不是"把一堆微服务塞到一个 Pod 里"。它解决的是**一个主容器需要辅助功能**的问题。

## 三种经典模式

### 1. Sidecar（边车模式）

**类比**：你骑摩托车（主容器），旁边挂了一个边车（辅助容器）。边车不负责前进，但帮你运货。

主容器负责核心业务，Sidecar 容器负责辅助工作：
- 日志收集（主容器写日志，Sidecar 把日志发到中心）
- 配置热更新（Sidecar 监听配置变化，写到共享 Volume）
- 内容生成（Sidecar 生成静态文件，主容器直接 serve）

**示例**：nginx + busybox Sidecar。busybox 每 5 秒生成新的 `index.html`，nginx 直接读取并返回给用户。

### 2. Ambassador（大使模式）

**类比**：你去外国办事，大使帮你翻译和对接本地资源。

主容器不需要知道外部服务的真实地址，Ambassador 容器负责代理：
- 主容器访问 `localhost:16379`，Ambassador 把请求转发到真实的 Redis 集群
- 主容器访问 `localhost:3306`，Ambassador 把请求转发到真实的 MySQL
- 好处：主容器代码完全不需要处理服务发现、负载均衡、TLS 等逻辑

**示例**：主容器通过 `localhost:8888` 访问外部服务，Ambassador 容器用 busybox 模拟一个代理层。

### 3. Adapter（适配器模式）

**类比**：你的电器是国标插头，但墙上插座是欧标的。适配器负责转换。

主容器输出的数据格式不统一，Adapter 容器负责标准化：
- 主容器输出自定义格式的日志，Adapter 转成 Prometheus 指标
- 主容器输出 XML，Adapter 转成 JSON
- 不同版本的微服务输出不同格式，Adapter 统一处理

## 同一个 Pod 内容器如何通信

同一个 Pod 内的容器共享网络命名空间，这意味着：

```
┌─────────────────────────────────────┐
│           Pod (共享网络)              │
│                                     │
│  ┌──────────┐     ┌──────────┐     │
│  │ Container│     │ Container│     │
│  │  :80     │◄────│ :8080    │     │
│  │ (nginx)  │ localhost  │ (app)  │     │
│  └──────────┘     └──────────┘     │
│                                     │
│  共享 IP: 10.244.1.5               │
│  共享 Volume: /shared              │
└─────────────────────────────────────┘
```

- 容器 A 监听 80 端口，容器 B 通过 `localhost:80` 访问
- **不能**两个容器监听同一个端口（会冲突）
- 容器之间没有网络隔离，不要在这里做安全隔离

## 共享 Volume（emptyDir）

`emptyDir` 是最简单的共享存储方式 —— Pod 创建时自动创建，Pod 删除时一起消失。

```yaml
volumes:
  - name: shared-data
    emptyDir: {}   # 节点上的一个临时目录
```

两个容器都挂载这个 Volume，就实现了文件共享。

> `emptyDir` 的数据存在节点磁盘上。如果节点重启，数据会丢失。适合临时文件共享，不适合持久化存储。

## 什么时候用多容器 Pod，什么时候用独立 Pod

| 场景 | 选择 | 原因 |
|------|------|------|
| 主容器 + 日志收集 | 多容器 Pod | 需要共享日志文件 |
| 主容器 + 配置注入 | 多容器 Pod | 需要共享配置文件 |
| 前端 + 后端 API | 独立 Pod | 可以独立扩缩容、独立部署 |
| 用户服务 + 订单服务 | 独立 Pod | 完全不同的业务，生命周期不同 |
| 数据库 + Web 应用 | 独立 Pod | 需要不同的扩缩容策略 |

**判断标准**：如果一个容器离开另一个就毫无意义（比如没有 nginx 的"日志收集器"），放一个 Pod。如果它们各自能独立运行，分开。

## Step by Step：Sidecar 模式

### Step 1: 创建 Sidecar Pod

```bash
kubectl apply -f sidecar-demo.yaml

# 查看 Pod 状态，注意 READY 列是 2/2
kubectl get pods
# NAME            READY   STATUS    RESTARTS   AGE
# sidecar-demo    2/2     Running   0          10s
```

`READY` 显示 `2/2` — 两个容器都已就绪。

### Step 2: 验证 Sidecar 在工作

```bash
# 查看 nginx 返回的内容（由 busybox sidecar 生成）
kubectl exec sidecar-demo -c nginx -- curl -s http://localhost

# 你会看到类似这样的输出：
# <h1>Hello from Sidecar! Updated at: Mon Jun 01 12:00:00 UTC 2026</h1>

# 等几秒再访问一次
kubectl exec sidecar-demo -c nginx -- curl -s http://localhost
# 时间戳会变化，说明 sidecar 持续在更新文件
```

### Step 3: 分别查看两个容器的日志

```bash
# 查看 nginx 日志
kubectl logs sidecar-demo -c nginx

# 查看 sidecar（busybox）日志
kubectl logs sidecar-demo -c sidecar
```

多容器 Pod 中必须用 `-c` 指定容器名来查看日志。

### Step 4: 查看共享 Volume

```bash
# 在 nginx 容器中查看共享目录
kubectl exec sidecar-demo -c nginx -- ls -la /usr/share/nginx/html/

# 在 sidecar 容器中查看共享目录
kubectl exec sidecar-demo -c sidecar -- ls -la /work-dir
```

两个容器看到的是同一组文件 — 这就是 `emptyDir` 的效果。

### Step 5: 验证 restartPolicy 对多容器的影响

多容器 Pod 中 `restartPolicy`（默认 `Always`）对所有容器生效。一个容器崩溃不影响另一个，但 K8s 会自动重启崩溃的那个。

> **注意**：无法从容器内部 `kill 1` 来触发重启——PID namespace 会拦截。正确的验证方式是用一个必定崩溃的容器。

```bash
# 创建一个必定崩溃的 Pod
kubectl run crash-loop --image=busybox --restart=Always \
    --command -- sh -c 'echo "crash!"; exit 1'

# Watch RESTARTS 列的增长
kubectl get pods -w
# 你会看到: Error → CrashLoopBackOff，RESTARTS 不断增长
# 指数退避: 10s → 20s → 40s → 80s → 160s → 上限 5min

# 清理
kubectl delete pod crash-loop
```

如果你保留了 sidecar-demo，两个容器独立运行：nginx 照常服务，sidecar 崩溃只会导致它自己进入重启循环，页面内容停止更新。

### Step 6: 清理

```bash
kubectl delete -f sidecar-demo.yaml
```

## Step by Step：Ambassador 模式

### Step 1: 创建 Ambassador Pod

```bash
kubectl apply -f ambassador-demo.yaml

kubectl get pods
# NAME              READY   STATUS    RESTARTS   AGE
# ambassador-demo   2/2     Running   0          10s
```

### Step 2: 验证 Ambassador 代理

```bash
# 主容器通过 localhost:8888 访问，Ambassador 代理到真实服务
kubectl exec ambassador-demo -c main-app -- wget -qO- http://localhost:8888 2>/dev/null || \
  kubectl exec ambassador-demo -c main-app -- cat /etc/hosts
```

### Step 3: 清理

```bash
kubectl delete -f ambassador-demo.yaml
```

## 常见困惑

学习本节时学生常遇到以下问题，提前说明可以避免踩坑。

### 1. `kubectl logs` 在多容器 Pod 中的默认行为

如果 Pod 有多个容器，`kubectl logs` 不指定 `-c` 时，默认取第一个容器（按 YAML 定义顺序）。kubectl 会打印提示：

```
Defaulted container "nginx" out of: nginx, sidecar
```

**必须用 `-c` 指定容器名来分别查看日志。**

### 2. busybox 没有 `/bin/bash`

`busybox` 镜像只有 `/bin/sh`（ash），没有 bash。如果执行 `kubectl exec -it pod -c container -- /bin/bash` 会报错：

```
unable to start container process: exec: "/bin/bash": stat /bin/bash: no such file or directory
```

对于 busybox 容器，用 `/bin/sh` 或 `sh`。

### 3. 容器内 kill PID 1 几乎无效

容器的 PID 1（主进程）在 Linux PID namespace 中有特殊保护，SIGTERM 被忽略，SIGKILL 被内核拦截。所以从容器内部 `kill 1` 无法触发 `restartPolicy`。

**要观察重启行为，应该创建一个"天生会崩溃"的容器**——主进程以非 0 退出码退出：

```bash
kubectl run crash-loop --image=busybox --restart=Always \
    --command -- sh -c 'echo "crash!"; exit 1'
```

然后 watch RESTARTS 列的增长和 CrashLoopBackOff 状态。

### 4. `kubectl delete pod <name>` vs `kubectl delete -f <file>`

两者效果一样。前者按名字删除，后者按 YAML 文件删除。日常用 `-f` 更精确（不容易删错），用 `<name>` 更快捷。

### 5. Ambassador demo 的局限性

本节 Ambassador demo 用 busybox `httpd` 模拟了一个静态响应，**没有做真正的代理转发**。它只能验证"同 Pod 容器通过 localhost 互访"，无法展示 Ambassador 模式的核心价值——解耦外部服务、协议转换、TLS 封装等。真实场景中需替换为 nginx / Envoy / HAProxy 等真正做代理的容器。

### 6. Sidecar 日志为空

Sidecar 容器的脚本用 `echo "..." > file` 写文件而非输出到 stdout，所以 `kubectl logs -c sidecar` 为空。要验证 sidecar 在工作，应重复访问 nginx 看时间戳是否变化：

```bash
kubectl exec sidecar-demo -c nginx -- curl -s http://localhost
# 等 5 秒再执行，时间戳应更新
```

## 关键概念总结

| 概念 | 要点 |
|------|------|
| 多容器 Pod 的本质 | 一组紧密协作的容器，共享网络和存储 |
| Sidecar | 增强主容器功能（日志、配置、监控） |
| Ambassador | 代理主容器的外部访问 |
| Adapter | 转换主容器的输出格式 |
| emptyDir | Pod 级别的临时共享存储 |
| 判断标准 | 必须同生共死 → 同 Pod；可以独立运行 → 分开 Pod |

> **最佳实践**：如果不确定是否该用多容器 Pod，先用独立 Pod。合并很容易，拆分很痛苦。

## 思考题

1. 如果 Sidecar 容器崩溃了，主容器会怎样？（提示：Pod 的 `restartPolicy` 对所有容器生效）
2. 两个容器在同一个 Pod 里监听了同一个端口，会发生什么？怎么解决？
3. 为什么 Ambassador 模式可以让主容器"不需要知道外部服务的真实地址"？这个模式在现代 K8s 中还有必要吗？（提示：看看 Service 和 Istio/Linkerd）
4. `emptyDir` 和 `hostPath` 有什么区别？在多容器场景下，为什么 `emptyDir` 更合适？

---

下一个 → [03 - Pod 生命周期](../03-pod-lifecycle/)
