# 08-01 Kubernetes 日志管理

## 为什么日志如此重要

在传统单体应用中，你可以直接登录服务器查看日志文件。但在 Kubernetes 中：

- Pod 可能随时被调度到不同节点
- 容器重启后，之前的日志可能丢失
- 一个应用可能由多个容器组成，日志分散在不同容器中
- 大规模集群中，手动 SSH 到节点查看日志完全不现实

因此，理解 Kubernetes 的日志机制是排查问题、保障服务稳定性的基础能力。

## Kubernetes 日志基础

### 日志从哪里来

Kubernetes 本身不提供集群级别的日志解决方案，但它定义了一个关键的约定：

> **容器化应用应该将日志写入 stdout（标准输出）和 stderr（标准错误）**

为什么？因为这样 Kubernetes 才能统一管理日志的生命周期。

```
应用程序 → stdout/stderr → 容器运行时（containerd）日志驱动 → 节点上的日志文件
```

### 日志在节点上的存储

当你运行一个容器时，containerd 会把容器的 stdout/stderr 输出重定向到节点上的日志文件中：

```
/var/log/containers/<pod-name>_<namespace>_<container-name>-<container-id>.log
→ 软链接到 /var/log/pods/<namespace>_<pod-name>_<pod-uid>/<container-name>/<restart-count>.log
→ 最终指向 /var/lib/containerd/... 下的文件
```

> **注意：** Kubernetes 默认使用 json-file 日志驱动，日志文件会持续增长。生产环境需要配置日志轮转（log rotation），否则可能耗尽节点磁盘空间。

可以通过在节点上查看日志文件来验证：

```bash
# 先找到你的 Pod 所在节点
kubectl get pod -n kube-system -o wide

# 使用 docker exec 进入 kind 的 control-plane 节点查看日志目录
docker exec -it kind-control-plane ls /var/log/containers/
```

## kubectl logs 详解

`kubectl logs` 是查看容器日志最直接的方式。

### 基本用法

```bash
# 查看 Pod 日志
kubectl logs <pod-name>

# 指定命名空间
kubectl logs <pod-name> -n <namespace>

# 查看最近 20 行
kubectl logs <pod-name> --tail=20
```

### 实时跟踪日志 (-f)

```bash
# 类似 tail -f，持续输出新日志
kubectl logs <pod-name> -f
```

### 查看崩溃前的日志 (--previous)

当一个容器因为崩溃被重启后，默认的 `kubectl logs` 只能看到新容器的日志。要查看上次崩溃的容器日志：

```bash
kubectl logs <pod-name> --previous
# 或简写
kubectl logs <pod-name> -p
```

> **提示：** `--previous` 是排查 CrashLoopBackOff 问题的关键命令。容器崩溃后新容器启动，旧日志会被"隔离"，但不会立即删除。

### 多容器 Pod 的日志 (-c)

一个 Pod 中可能有多个容器（sidecar 模式），需要指定容器名：

```bash
# 列出 Pod 中的容器
kubectl get pod <pod-name> -o jsonpath='{.spec.containers[*].name}'

# 查看指定容器的日志
kubectl logs <pod-name> -c <container-name>

# 查看所有容器的日志
kubectl logs <pod-name> --all-containers
```

### 常用参数速查

| 参数 | 说明 | 示例 |
|------|------|------|
| `-f` | 持续跟踪日志 | `kubectl logs <pod> -f` |
| `--previous` | 查看上次容器的日志 | `kubectl logs <pod> --previous` |
| `-c` | 指定容器名 | `kubectl logs <pod> -c sidecar` |
| `--tail` | 显示最后 N 行 | `kubectl logs <pod> --tail=50` |
| `--since` | 显示相对时间后的日志 | `kubectl logs <pod> --since=1h` |
| `--since-time` | 显示指定时间后的日志 | `kubectl logs <pod> --since-time=2024-01-01T00:00:00Z` |
| `--timestamps` | 在每行添加时间戳 | `kubectl logs <pod> --timestamps` |
| `-l` | 按 label 选择多个 Pod | `kubectl logs -l app=nginx` |

## 日志聚合架构

`kubectl logs` 只适合查看单个 Pod 的日志。在生产环境中，你需要一个集中式的日志系统来：

1. **集中存储**：所有节点的日志汇聚到一个地方
2. **搜索过滤**：快速找到关键信息
3. **长期保存**：容器销毁后日志仍然可查
4. **告警联动**：日志中出现异常模式时触发告警

### 经典日志架构

```
┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│   Node 1    │   │   Node 2    │   │   Node 3    │
│  ┌───────┐  │   │  ┌───────┐  │   │  ┌───────┐  │
│  │Fluent │  │   │  │Fluent │  │   │  │Fluent │  │
│  │  Bit  │──┼───┼──│  Bit  │──┼───┼──│  Bit  │  │
│  └───────┘  │   │  └───────┘  │   │  └───────┘  │
└─────────────┘   └─────────────┘   └─────────────┘
        │                │                 │
        └────────────────┼─────────────────┘
                         ▼
              ┌──────────────────┐
              │  中央存储 (后端)   │
              │ Elasticsearch /  │
              │      Loki        │
              └────────┬─────────┘
                       ▼
              ┌──────────────────┐
              │    可视化层       │
              │  Kibana /        │
              │  Grafana         │
              └──────────────────┘
```

### 为什么用 DaemonSet 部署日志采集器

日志采集器需要运行在每个节点上，因为日志文件存储在节点本地。DaemonSet 正好满足这个需求——它确保每个节点运行一个 Pod 副本。

### 常见日志方案对比

| 方案 | 采集器 | 存储 | 可视化 | 特点 |
|------|--------|------|--------|------|
| EFK | Fluentd | Elasticsearch | Kibana | 经典方案，功能全面，资源消耗较大 |
| PLG | Promtail | Loki | Grafana | 轻量级，与 Prometheus 生态集成好 |
| Fluent Bit → Loki | Fluent Bit | Loki | Grafana | 最轻量，适合资源受限环境 |

### Fluent Bit vs Fluentd

| 特性 | Fluentd | Fluent Bit |
|------|---------|------------|
| 语言 | Ruby + C | C |
| 内存占用 | 较高（~100MB+） | 极低（~5MB） |
| 插件生态 | 丰富 | 足够用 |
| 适用场景 | 需要复杂转换 | 轻量采集 + 转发 |

> **最佳实践：** 在 Kubernetes 中，通常用 Fluent Bit 做采集（DaemonSet），用 Fluentd 做中间层的聚合和转换（可选）。本教程使用更轻量的 Fluent Bit。

## 结构化日志 vs 非结构化日志

### 非结构化日志

```
2024-01-15 10:23:45 INFO User john logged in from 192.168.1.100
2024-01-15 10:23:46 ERROR Database connection failed: timeout after 30s
```

人类可读，但机器难以解析。搜索"所有来自 192.168.1.100 的 ERROR 日志"需要正则匹配。

### 结构化日志（JSON 格式）

```json
{"time":"2024-01-15T10:23:45Z","level":"INFO","user":"john","ip":"192.168.1.100","msg":"user login"}
{"time":"2024-01-15T10:23:46Z","level":"ERROR","error":"timeout","duration":30,"msg":"db connection failed"}
```

机器可轻松解析。搜索 `level=ERROR AND ip=192.168.1.100` 直接用字段过滤，效率高得多。

> **建议：** 新项目应使用结构化日志（JSON）。大多数现代日志系统都能直接索引 JSON 字段。

## 实战演练

### 环境准备

确保你的 kind 集群正在运行：

```bash
# 查看集群状态
kubectl get nodes

# 期望输出：1 control-plane + 2 worker
# NAME                   STATUS   ROLES           AGE   VERSION
# kind-control-plane     Ready    control-plane   XXd   v1.xx.x
# kind-worker            Ready    <none>          XXd   v1.xx.x
# kind-worker2           Ready    <none>          XXd   v1.xx.x
```

### Step 1：部署日志生成器

```bash
# 部署一个持续生成日志的应用
kubectl apply -f log-generator.yaml

# 等待 Pod 就绪
kubectl get pods -l app=log-generator -w
```

### Step 2：查看日志

```bash
# 查看最新日志
kubectl logs -l app=log-generator --tail=10

# 持续跟踪
kubectl logs -l app=log-generator -f

# 带时间戳查看
kubectl logs -l app=log-generator --tail=5 --timestamps
```

### Step 3：模拟崩溃并查看 previous 日志

```bash
# 手动终止容器进程触发重启
kubectl exec -it <pod-name> -- kill 1

# 等待 Pod 重启（观察 RESTARTS 列增长）
kubectl get pods -l app=log-generator -w

# 查看崩溃前的日志
kubectl logs <pod-name> --previous
```

### Step 4：部署 Fluent Bit DaemonSet

```bash
# 部署 Fluent Bit（每个节点一个 Pod）
kubectl apply -f fluent-bit-daemonset.yaml

# 验证每个节点都有一个 Fluent Bit Pod
kubectl get pods -l app=fluent-bit -o wide

# 期望：3 个 Pod 分布在 3 个节点上

# 查看 Fluent Bit 的输出日志（验证它正在采集容器日志）
kubectl logs -l app=fluent-bit --tail=20
```

### Step 5：清理

```bash
kubectl delete -f log-generator.yaml
kubectl delete -f fluent-bit-daemonset.yaml
```

## 日志最佳实践

1. **始终输出到 stdout/stderr**：不要写到文件里，除非你用 sidecar 容器来采集那个文件
2. **使用 JSON 格式**：方便日志系统解析和索引
3. **包含足够上下文**：request_id、user_id、trace_id 等便于关联排查
4. **控制日志级别**：生产环境避免过多 DEBUG 日志
5. **日志轮转**：配置 kubelet 的 `containerLogMaxSize` 和 `containerLogMaxFiles`

## 思考题

1. 如果一个 Pod 中有主容器和 sidecar 容器，它们的日志会混合存储吗？`kubectl logs` 如何区分？
2. 为什么 Kubernetes 推荐应用将日志写入 stdout/stderr 而不是文件？如果应用必须写文件，有什么解决方案？
3. Fluent Bit 以 DaemonSet 方式部署，它需要什么权限才能读取节点上的日志文件？想想 `volumeMounts` 中的 `/var/log` 是如何映射到宿主机的。
4. 在大规模集群中，如果所有日志都发送到同一个 Elasticsearch 集群，可能遇到什么瓶颈？你会如何优化？

---

**下一节：** [02-monitoring-prometheus - Prometheus 监控](../02-monitoring-prometheus/)
