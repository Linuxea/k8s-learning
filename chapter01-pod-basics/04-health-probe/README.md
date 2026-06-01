# 04 - 健康检查（Health Probes）

## 为什么需要健康检查

一个容器里的进程还在运行（PID 存在），不代表应用真的"健康"。考虑这些场景：

- **死锁**：进程在，但无法响应任何请求
- **内存泄漏**：进程在，但已经 OutOfMemory，请求全部超时
- **依赖故障**：应用启动了，但连不上数据库，所有请求都返回 500
- **启动未完成**：Java 应用还在加载 Spring Bean，但端口已经开了

如果没有健康检查，K8s 只知道"进程还在不在"，不知道"服务能不能用"。这就是探针存在的意义。

## 三种探针

| 探针 | 作用 | 失败后果 |
|------|------|---------|
| **livenessProbe**（存活探针） | 容器是否还在正常运行？ | **重启容器** |
| **readinessProbe**（就绪探针） | 容器是否准备好接收流量？ | **从 Service 移除**（不接收新请求） |
| **startupProbe**（启动探针） | 容器是否已完成启动？ | **杀死容器**（然后按 restartPolicy 重启） |

### 它们的关系

```
容器启动
    │
    ▼
startupProbe 开始探测 ──── 失败 ──► 杀死容器，重启
    │
    │ 成功后（startupProbe 不再运行）
    ▼
livenessProbe 开始探测 ──── 失败 ──► 重启容器
    │
readinessProbe 开始探测 ──── 失败 ──► 从 Service Endpoints 移除
    │                                    （已有的连接不受影响）
    │ 成功
    ▼
容器开始接收 Service 转发的流量
```

> **关键区别**：livenessProbe 失败 → 容器被重启（重启有成本）。readinessProbe 失败 → 容器暂时不接收流量（不重启）。这是两个完全不同的响应策略。

### 什么时候用哪种探针

| 场景 | 推荐探针 | 原因 |
|------|---------|------|
| Web 服务 | liveness + readiness | 存活保证重启，就绪保证流量不打到未准备好的实例 |
| 启动慢的应用（Java） | startupProbe + liveness + readiness | startupProbe 避免在启动期被 livenessProbe 误杀 |
| 一次性任务 | 不需要 | 任务完成就退出 |
| 依赖外部服务 | readinessProbe | 依赖不可用时，不应重启（重启也解决不了），应暂停接收流量 |

## 三种探测方式

### HTTP GET

向容器发送 HTTP 请求，根据响应状态码判断：

```yaml
livenessProbe:
  httpGet:
    path: /healthz       # 请求路径
    port: 80             # 端口
    httpHeaders:         # 可选：自定义请求头
      - name: X-Custom-Header
        value: awesome
```

| 响应 | 判定 |
|------|------|
| 200-399 | 成功 |
| 其他状态码 | 失败 |

### TCP Socket

尝试建立 TCP 连接：

```yaml
livenessProbe:
  tcpSocket:
    port: 6379           # 端口
```

连接建立成功 = 健康。适合非 HTTP 服务（Redis、MySQL 等）。

### Exec

在容器内执行命令：

```yaml
livenessProbe:
  exec:
    command:
      - cat
      - /tmp/healthy     # 文件存在 = 成功
```

命令退出码为 0 = 成功，非 0 = 失败。适合自定义健康检查逻辑。

## 探针参数详解

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 80
  initialDelaySeconds: 15   # 容器启动后等待 15 秒才开始第一次探测
  periodSeconds: 10          # 每 10 秒探测一次
  timeoutSeconds: 5          # 每次探测超时时间 5 秒
  failureThreshold: 3        # 连续失败 3 次才认为不健康
  successThreshold: 1        # 连续成功 1 次就认为恢复了
```

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `initialDelaySeconds` | 0 | 容器启动后等待多久才开始探测 |
| `periodSeconds` | 10 | 探测间隔 |
| `timeoutSeconds` | 1 | 单次探测超时时间 |
| `failureThreshold` | 3 | 连续失败多少次才认为探测失败 |
| `successThreshold` | 1 | 连续成功多少次才认为恢复（readiness 被最小设为 1） |

### 参数计算示例

假设 `periodSeconds=10`，`failureThreshold=3`：
- 从探测失败到容器被重启/移除，最多等待 `10 × 3 = 30` 秒
- 加上 `initialDelaySeconds=15`，从容器启动到最坏情况下被重启：`15 + 30 = 45` 秒

> **注意**：`successThreshold` 对 livenessProbe 必须为 1（因为一旦失败就重启了，不存在"需要连续成功多次才认为存活"的场景）。readinessProbe 可以设大于 1，避免网络抖动导致频繁加入/移除。

## 最常见的错误：用 livenessProbe 做不该做的事

```yaml
# 错误做法
livenessProbe:
  httpGet:
    path: /check-database-connection
    port: 80
```

如果数据库挂了：
1. livenessProbe 失败 → 容器被重启
2. 重启后数据库还是挂的 → livenessProbe 再次失败 → 再次重启
3. 无限循环：**CrashLoopBackOff**

正确做法：数据库连接检查应该放在 **readinessProbe** 中。数据库挂了，容器暂时不接收流量，但不需要重启（重启解决不了数据库的问题）。

```
错误:  依赖故障 → livenessProbe 失败 → 重启 → 还是不行 → CrashLoopBackOff
正确:  依赖故障 → readinessProbe 失败 → 移出 Service → 依赖恢复 → 自动恢复
```

> **黄金法则**：livenessProbe 只检查应用自身是否死锁/卡死。外部依赖（数据库、缓存、第三方 API）的检查应该放在 readinessProbe。

## Step by Step：配置探针

### Step 1: 创建带探针的 Pod

```bash
kubectl apply -f probes-demo.yaml

# 观察启动过程
kubectl get pods -w
# probes-demo   0/1     Running   0          0s    ← startupProbe 还在探测
# probes-demo   0/1     Running   0          5s    ← readinessProbe 还没通过
# probes-demo   1/1     Running   0          10s   ← 全部就绪
```

注意 `READY` 列从 `0/1` 变为 `1/1` 的过程。

### Step 2: 查看探针配置

```bash
kubectl describe pod probes-demo | grep -A20 "Liveness"
```

你会看到类似这样的输出：

```
Liveness:       http-get http://:80/ delay=0s timeout=1s period=10s #success=1 #failure=3
Readiness:      http-get http://:80/ delay=0s timeout=1s period=5s #success=1 #failure=3
Startup:        http-get http://:80/ delay=0s timeout=1s period=5s #success=1 #failure=10
```

### Step 3: 验证探针在工作

```bash
# 正常情况下访问 Pod
kubectl exec probes-demo -- curl -s -o /dev/null -w "%{http_code}" http://localhost
# 200
```

### Step 4: 清理

```bash
kubectl delete -f probes-demo.yaml
```

## Step by Step：模拟 livenessProbe 失败

### Step 1: 创建会故意失败的 Pod

```bash
kubectl apply -f liveness-fail-demo.yaml
```

这个 Pod 的机制：
1. 启动时创建 `/tmp/healthy` 文件
2. livenessProbe 检查这个文件是否存在
3. 30 秒后删除这个文件 → livenessProbe 开始失败
4. 连续失败 3 次 → 容器被重启

### Step 2: 观察自动重启

```bash
# 持续观察 RESTARTS 列
kubectl get pods -w
# NAME               READY   STATUS    RESTARTS   AGE
# liveness-fail      1/1     Running   0          10s
# liveness-fail      1/1     Running   1          75s    ← 被重启了！
# liveness-fail      1/1     Running   2          2m     ← 又被重启了！
```

### Step 3: 查看重启原因

```bash
kubectl describe pod liveness-fail | grep -A10 "Last State"
# Last State:     Terminated
#   Reason:       Completed
#   Exit Code:    0

# 查看 Events，找到探针失败的记录
kubectl describe pod liveness-fail | grep -A5 "Warning"
```

### Step 4: 清理

```bash
kubectl delete -f liveness-fail-demo.yaml
```

## 探针配置建议

| 场景 | livenessProbe | readinessProbe | startupProbe |
|------|--------------|----------------|--------------|
| 简单 Web 服务 | HTTP GET `/` | HTTP GET `/` | 通常不需要 |
| 启动慢的应用 | HTTP GET `/healthz` | HTTP GET `/ready` | HTTP GET `/startup`，`failureThreshold: 30` |
| 数据库依赖 | 检查进程死锁 | 检查数据库连接 | 通常不需要 |

通用建议：

- `initialDelaySeconds`：宁可设大一点，也不要让应用在启动期被误杀
- `timeoutSeconds`：如果应用有慢请求，适当调大（避免健康检查被正常请求阻塞）
- `failureThreshold`：给应用"自愈"的机会，不要设太小
- livenessProbe 的端点应该轻量、快速，不要做复杂检查

## 常见困惑

### 1. 为什么需要三种探针，而不是一种？

三种探针职责不同，分别对应三个独立的问题：

```
startupProbe  → "启动完了吗？"   没完 → 别急着判死活，给它时间
livenessProbe → "还活着吗？"     死了 → 重启容器
readinessProbe → "能接客吗？"    不能 → 暂时不发流量过来，但不重启
```

| 探针 | 比喻 | 失败动作 |
|------|------|---------|
| startupProbe | 等水烧开 | 不给 liveness/readiness 判死刑的机会 |
| livenessProbe | 心跳监测 | 杀了重启 |
| readinessProbe | 营业状态牌 | 挂牌"暂停营业"，不接新客 |

### 2. 探针类型是 K8s 内置的吗？

三种探针（startupProbe、livenessProbe、readinessProbe）是 K8s Pod API **内置字段**，不是插件也不是自定义资源。你只需要决定**探测方式**（三选一）：

| 方式 | 适用 |
|------|------|
| `httpGet` | Web 服务 |
| `tcpSocket` | Redis、MySQL 等非 HTTP 服务 |
| `exec` | 自定义逻辑（检查文件、跑脚本） |

### 3. 不配探针时，READY 为什么立刻变 1/1？

没有 readinessProbe 时，K8s 默认容器启动即就绪。配了之后，READY 要从 `0/1` 变成 `1/1`——这是在等 readinessProbe 返回成功。这个差异在你 `kubectl get pods -w` 时很明显。

## 关键概念总结

| 概念 | 要点 |
|------|------|
| 探针的目的 | K8s 不仅要知道进程在不在，还要知道服务能不能用 |
| livenessProbe | 检查容器是否死锁，失败 → 重启 |
| readinessProbe | 检查是否准备好接收流量，失败 → 移出 Service |
| startupProbe | 给慢启动应用"豁免期"，期间不执行 liveness/readiness |
| 探测方式 | HTTP GET / TCP Socket / Exec |
| 黄金法则 | 依赖检查放 readiness，自身健康放 liveness |

## 思考题

1. 如果只配了 livenessProbe 没配 readinessProbe，当应用暂时过载（响应变慢）时会发生什么？
2. 一个 Java Spring Boot 应用启动需要 60 秒，你如何设计探针参数来避免启动期被误杀？（至少给出两种方案）
3. 为什么 `successThreshold` 对 livenessProbe 只能为 1，但 readinessProbe 可以大于 1？
4. 如果 livenessProbe 的 `timeoutSeconds` 设得太小（比如 1 秒），而应用的健康检查端点偶尔需要 1.5 秒响应，会发生什么？

---

下一个 → [05 - 资源限制](../05-resource-limits/)
