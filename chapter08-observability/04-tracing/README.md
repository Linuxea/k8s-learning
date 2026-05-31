# 08-04 分布式追踪

## 为什么需要分布式追踪

在微服务架构中，一个用户请求可能经过多个服务：

```
用户请求 → API Gateway → User Service → Order Service → Database
                            ↓
                         Cache Service
```

如果这个请求耗时 3 秒，你怎么知道是哪个服务慢？

- **日志**：可以记录每个服务的耗时，但需要手动关联多个服务的日志
- **监控**：可以看到每个服务的延迟，但看不到一个请求的完整链路
- **分布式追踪**：可以看到一个请求经过的完整路径，每个步骤的耗时

### 什么时候需要分布式追踪

| 场景 | 是否需要 |
|------|---------|
| 单体应用 | 不需要（日志足够） |
| 3-5 个微服务 | 有帮助（日志 + trace_id 关联也行） |
| 10+ 个微服务 | 强烈建议 |
| 需要分析请求瓶颈 | 必须 |
| 排查偶发超时 | 必须 |

## OpenTelemetry

[OpenTelemetry](https://opentelemetry.io/)（简称 OTel）是一个**厂商中立**的可观测性标准，由 CNCF 维护。它统一了三种信号：

| 信号 | 说明 |
|------|------|
| **Traces** | 追踪请求在分布式系统中的流转路径 |
| **Metrics** | 量化系统的运行指标（QPS、延迟、错误率） |
| **Logs** | 记录离散的事件 |

> **为什么强调"厂商中立"？** 以前有 OpenTracing 和 OpenCensus 两个标准，应用需要绑定特定的后端。OpenTelemetry 合并了两者，应用只需接入 OTel SDK，后端可以随时切换（Jaeger、Zipkin、Tempo 等）。

### OpenTelemetry 架构

```
┌──────────────────────────────────────────────────────────┐
│                    你的应用                                │
│  ┌──────────────────────────────────────────────────────┐│
│  │              OpenTelemetry SDK                        ││
│  │  自动/手动埋点 → 生成 Trace/Span 数据                  ││
│  └───────────────────────┬──────────────────────────────┘│
└──────────────────────────┼───────────────────────────────┘
                           │
                    OTLP (gRPC/HTTP)
                           │
              ┌────────────▼─────────────┐
              │  OpenTelemetry Collector  │
              │  (接收、处理、导出)         │
              └────────────┬──────────────┘
                           │
              ┌────────────▼──────────────┐
              │     追踪后端               │
              │  Jaeger / Tempo / Zipkin   │
              └──────────────────────────┘
```

### 核心概念

#### Trace（追踪）

一个 Trace 代表一个完整的请求链路，从用户发起请求到最终响应。每个 Trace 有一个唯一的 `Trace ID`。

```
Trace ID: abc123
├── Span 1: API Gateway (0ms - 3000ms)
│   ├── Span 2: User Service (50ms - 200ms)
│   │   └── Span 3: Cache Lookup (60ms - 80ms) ← 缓存未命中
│   │   └── Span 4: DB Query (90ms - 180ms)
│   └── Span 5: Order Service (250ms - 2800ms) ← 瓶颈！
│       └── Span 6: DB Query (260ms - 2750ms) ← 数据库慢查询
```

#### Span（跨度）

Span 是 Trace 中的单个操作。每个 Span 包含：

| 字段 | 说明 |
|------|------|
| `Trace ID` | 所属的 Trace |
| `Span ID` | 当前 Span 的唯一标识 |
| `Parent Span ID` | 父 Span（构成调用树） |
| `Operation Name` | 操作名称（如 `HTTP GET /api/users`） |
| `Start Time` | 开始时间 |
| `Duration` | 持续时间 |
| `Status` | 状态（OK / Error） |
| `Attributes` | 自定义属性（如 `http.method = GET`） |
| `Events` | 事件日志（如异常堆栈） |

#### Context Propagation（上下文传播）

这是分布式追踪的核心机制。当请求从服务 A 调用服务 B 时：

1. 服务 A 创建 Span，生成 `Trace ID` 和当前 `Span ID`
2. 服务 A 将这些 ID 通过 **HTTP Header**（如 `traceparent`）传递给服务 B
3. 服务 B 读取 Header，创建子 Span（Parent ID = 服务 A 的 Span ID）

```
服务 A ──HTTP Request──→ 服务 B
Headers:
  traceparent: 00-abc123-def456-01
              ↑       ↑      ↑
          版本号  Trace ID  Span ID
```

> **关键点：** 如果中间某个服务没有传播 trace context，链路就断了。所以分布式追踪需要**所有服务都参与**。

## Jaeger

[Jaeger](https://www.jaegertracing.io/) 是 CNCF 毕业项目，最流行的开源分布式追踪后端之一。

### Jaeger 部署模式

| 模式 | 说明 | 适用场景 |
|------|------|---------|
| All-in-One | 所有组件在一个 Pod 中 | 学习、开发、测试 |
| Production | Agent + Collector + Query 分离 | 生产环境 |

### Jaeger 架构（All-in-One）

```
┌──────────────────────────────────┐
│        Jaeger All-in-One         │
│                                  │
│  Agent ← 接收 trace 数据         │
│    ↓                             │
│  Collector ← 处理和存储           │
│    ↓                             │
│  Query ← UI 查询界面             │
│    ↓                             │
│  Storage (内存/ES/Badger)        │
└──────────────────────────────────┘
```

## 实战演练

### Step 1：部署 Jaeger

```bash
# 部署 Jaeger All-in-One（最简单的部署方式）
kubectl apply -f jaeger-all-in-one.yaml

# 等待 Pod 就绪
kubectl get pods -l app=jaeger -w

# 访问 Jaeger UI
kubectl port-forward svc/jaeger-query 16686:16686
# 浏览器打开 http://localhost:16686
```

### Step 2：部署带追踪的应用

```bash
# 部署示例应用
kubectl apply -f traced-app.yaml

# 等待 Pod 就绪
kubectl get pods -l app=traced-app -w
```

### Step 3：生成追踪数据

```bash
# 获取 Service 的 ClusterIP
kubectl get svc traced-app

# 发送请求（在集群内部）
kubectl run curl-test --image=busybox:1.36 --rm -it --restart=Never -- \
  wget -qO- http://traced-app:8080

# 或者使用 port-forward
kubectl port-forward svc/traced-app 8080:8080
# 在另一个终端发送请求
curl http://localhost:8080
```

### Step 4：在 Jaeger UI 中查看追踪

1. 打开 Jaeger UI（http://localhost:16686）
2. 在 Service 下拉框中选择 `traced-app`
3. 点击 "Find Traces"
4. 点击一条 Trace 查看详情
5. 观察 Span 树、每个 Span 的耗时和属性

### Step 5：清理

```bash
kubectl delete -f traced-app.yaml
kubectl delete -f jaeger-all-in-one.yaml
```

## 追踪最佳实践

1. **采样策略**：不是所有请求都需要追踪。生产环境通常设置 1%-10% 的采样率，出错时自动提升采样率
2. **Span 命名要有意义**：`HTTP GET /api/users` 比 `handle_request` 有用得多
3. **添加丰富的 Attributes**：`user.id`、`http.status_code`、`db.statement` 等便于过滤和分析
4. **记录错误**：当请求失败时，在 Span 中记录异常信息和堆栈
5. **保持上下文传播**：确保所有服务都正确传播 trace context，否则链路会断裂

## 思考题

1. 如果你的系统中有 100 个微服务，但只有 80 个接入了 OpenTelemetry SDK，追踪链路会是什么样子？缺失的部分会怎样？
2. Trace 的采样率设为 100% 和 1% 各有什么利弊？在什么情况下你会选择哪种？
3. Context Propagation 依赖 HTTP Header 传递 Trace ID。如果你的服务间通信使用消息队列（如 Kafka）而非 HTTP，上下文传播还能工作吗？需要怎么做？
4. Jaeger All-in-One 使用内存存储。如果 Jaeger Pod 重启了，追踪数据会怎样？生产环境应该使用什么存储后端？

---

**下一节：** [05-dashboard-grafana - Grafana 可视化](../05-dashboard-grafana/)
