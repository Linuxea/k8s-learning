# 08-02 Prometheus 监控体系

## 为什么监控如此重要

> "You can't manage what you can't measure." — Peter Drucker

在 Kubernetes 中，问题可能在任何层级发生：节点故障、Pod 崩溃、网络延迟、磁盘满、内存泄漏……没有监控系统，你只能等用户反馈问题——那时候往往已经晚了。

监控的价值：

- **发现问题**：在用户感知之前发现问题（如内存缓慢增长、磁盘空间不足）
- **定位问题**：快速找到问题的根因（是 CPU 瓶颈还是网络延迟？）
- **容量规划**：基于历史数据预测资源需求
- **SLA 保障**：量化和证明服务的可用性

## Prometheus 简介

[Prometheus](https://prometheus.io/) 是云原生领域的事实标准监控方案，也是 Kubernetes 社区推荐的开源监控系统。

### 核心设计理念

| 特性 | 说明 |
|------|------|
| **Pull 模式** | Prometheus 主动拉取目标的指标数据，而非等待推送 |
| **时序数据库** | 内置高效的时序数据存储（TSDB） |
| **多维数据模型** | 指标通过键值对（labels）标识，支持灵活的聚合查询 |
| **PromQL** | 强大的查询语言，支持聚合、运算、函数 |
| **服务发现** | 自动发现 Kubernetes 中的监控目标 |
| **无分布式依赖** | 单节点即可运行，部署简单 |

### 为什么选择 Pull 而不是 Push

| Pull 模式 | Push 模式 |
|-----------|-----------|
| Prometheus 知道所有目标 | 不清楚有哪些推送源 |
| 目标不可用时立即发现 | 推送失败可能被忽略 |
| 无需在应用中配置推送地址 | 每个应用都要知道推送目标 |
| 方便做健康检查 | 只能依赖数据是否到来 |
| 容易水平扩展（分片拉取） | 推送需要负载均衡器 |

> **Pull 模式的代价：** 不适合短生命周期任务（如批处理 Job），因为 Prometheus 可能还没来得及拉取，任务就结束了。这种场景下可以使用 Pushgateway。

### Prometheus 架构

```
┌──────────────────────────────────────────────────┐
│                  Prometheus Server                │
│  ┌──────────┐  ┌───────────┐  ┌───────────────┐ │
│  │ Retrieval │  │    TSDB   │  │   HTTP API    │ │
│  │ (拉取指标) │→ │ (存储数据) │← │ (PromQL 查询) │ │
│  └─────┬────┘  └───────────┘  └───────┬───────┘ │
│        │                               │         │
└────────┼───────────────────────────────┼─────────┘
         │                               │
    ┌────▼────┐                    ┌─────▼──────┐
    │服务发现   │                    │ Grafana    │
    │K8s API  │                    │ 可视化     │
    └────┬────┘                    └────────────┘
         │
    ┌────▼────────────────────────────────────┐
    │         监控目标 (Targets)               │
    │  ┌─────────┐  ┌─────────┐  ┌─────────┐ │
    │  │Node     │  │App Pod  │  │kube-     │ │
    │  │Exporter │  │/metrics │  │state-    │ │
    │  │         │  │         │  │metrics   │ │
    │  └─────────┘  └─────────┘  └─────────┘ │
    └─────────────────────────────────────────┘
```

## 核心概念

### 指标（Metrics）

Prometheus 中的指标格式如下：

```
http_requests_total{method="GET", path="/api/users", status="200"} 1023
│                      │                                      │    │
│ 指标名称              │ 标签 (Labels)                        │   值 │
```

### 指标类型

| 类型 | 说明 | 示例 |
|------|------|------|
| **Counter** | 只增不减的计数器 | 请求总数 `http_requests_total` |
| **Gauge** | 可增可减的仪表盘 | 当前温度 `node_temperature_celsius` |
| **Histogram** | 对观测值采样并统计分布 | 请求延迟 `http_request_duration_seconds` |
| **Summary** | 类似 Histogram，但客户端计算分位数 | 预计算的请求延迟 P99 |

> **Counter vs Gauge：** Counter 像"汽车里程表"只增不减，Gauge 像"油量表"可增可减。计算 QPS 用 `rate(counter[5m])`，当前值直接看 Gauge。

### 标签（Labels）

标签是实现多维度的关键。同样的指标名，不同的标签组合构成不同的时间序列：

```
http_requests_total{method="GET", status="200"}   1023
http_requests_total{method="GET", status="404"}     15
http_requests_total{method="POST", status="200"}   567
```

你可以用 PromQL 按 method 聚合，也可以按 status 过滤。

### 服务发现与 Scrape

在 Kubernetes 中，Prometheus 通过 K8s API 自动发现监控目标：

1. **Endpoints 发现**：基于 Service 的 Endpoints 发现 Pod
2. **Service 发现**：基于 Service 的标签选择
3. **Pod 发现**：直接发现 Pod

Prometheus 定期（默认 15s）访问目标的 `/metrics` 端点拉取数据。

### Exporter

不是所有系统都原生暴露 Prometheus 格式的指标。**Exporter** 是一个"翻译器"，把系统特有的指标格式转换为 Prometheus 格式：

| Exporter | 监控对象 | 说明 |
|----------|---------|------|
| Node Exporter | 节点 | CPU、内存、磁盘、网络 |
| kube-state-metrics | K8s 对象 | Pod 状态、Deployment 副本数 |
| blackbox-exporter | 网络探测 | HTTP 探测、DNS 探测 |

## kube-prometheus-stack

[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)（原名 prometheus-operator）是一个"全家桶"：

| 组件 | 功能 |
|------|------|
| **Prometheus** | 指标采集和存储 |
| **Grafana** | 可视化仪表盘 |
| **Alertmanager** | 告警路由和通知 |
| **Node Exporter** | 节点硬件指标 |
| **kube-state-metrics** | K8s 对象状态指标 |
| **Prometheus Operator** | 简化 Prometheus 配置管理 |

### Prometheus Operator 与 CRD

Prometheus Operator 引入了几个 CRD（Custom Resource Definition），让你用声明式方式管理监控配置：

| CRD | 用途 |
|-----|------|
| `Prometheus` | 定义 Prometheus 实例 |
| `ServiceMonitor` | 声明式定义如何监控一个 Service |
| `PodMonitor` | 声明式定义如何监控一个 Pod |
| `PrometheusRule` | 定义告警和记录规则 |
| `Alertmanager` | 定义 Alertmanager 实例 |

### ServiceMonitor 详解

ServiceMonitor 是最常用的 CRD，它告诉 Prometheus "应该监控哪些 Service"：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
spec:
  selector:
    matchLabels:
      app: my-app        # 匹配哪些 Service
  endpoints:
    - port: http         # 监控哪个端口
      path: /metrics     # 指标端点路径
      interval: 15s      # 采集间隔
```

ServiceMonitor 的优势：

1. **声明式**：你只需描述"要监控什么"，不需要修改 Prometheus 配置
2. **自动化**：Prometheus Operator 自动生成 scrape 配置
3. **命名空间隔离**：可以控制 ServiceMonitor 的作用范围

## PromQL 基础

PromQL 是 Prometheus 的查询语言，功能强大但语法简洁。

### 常用查询示例

```promql
# 查看所有节点的 CPU 使用率（百分比）
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 查看 Pod 内存使用量
container_memory_working_set_bytes{container!="", container!="POD"}

# 查看某 Deployment 的请求速率（QPS）
sum(rate(http_requests_total{job="my-app"}[5m]))

# 按 status code 分组查看请求速率
sum by (status) (rate(http_requests_total[5m]))

# P99 延迟
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))
```

### PromQL 关键函数

| 函数 | 说明 |
|------|------|
| `rate()` | 计算 Counter 的每秒增长速率 |
| `irate()` | 类似 rate，但只看最后两个点（更敏感） |
| `histogram_quantile()` | 从 Histogram 计算分位数 |
| `sum()` / `avg()` / `max()` | 聚合运算 |
| `by (label)` | 按标签分组聚合 |
| `offset 1h` | 查看一小时前的数据 |
| `predict_linear()` | 线性预测（如预测磁盘何时满） |

## 实战演练

### 前提条件

需要安装 Helm：

```bash
# 安装 Helm（如果还没安装）
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 添加 Prometheus 社区仓库
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### Step 1：安装 kube-prometheus-stack

```bash
# 创建命名空间
kubectl create namespace monitoring

# 使用自定义 values 安装
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f prometheus-values.yaml

# 等待所有 Pod 就绪（这可能需要几分钟）
kubectl get pods -n monitoring -w
```

### Step 2：访问 Prometheus UI

```bash
# 使用 port-forward 访问 Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090

# 在浏览器中打开 http://localhost:9090
```

### Step 3：探索 Prometheus UI

在 Prometheus UI 中尝试以下操作：

1. **查看状态 → Targets**：查看所有监控目标及其状态
2. **查询指标**：在查询框中输入以下 PromQL：

```promql
# 查看节点数
count(up{job="node-exporter"})

# 查看所有 Pod 的 CPU 使用率
sum(rate(container_cpu_usage_seconds_total{container!="", container!="POD"}[5m])) by (pod)

# 查看节点内存使用率
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100
```

### Step 4：部署示例应用并配置监控

```bash
# 部署一个暴露 /metrics 端点的示例应用
kubectl apply -f sample-app-deployment.yaml

# 创建 ServiceMonitor 让 Prometheus 自动发现它
kubectl apply -f sample-app-servicemonitor.yaml

# 等待 Prometheus 发现新目标（可能需要 30-60 秒）
# 在 Prometheus UI → Status → Targets 中查看
```

### Step 5：清理

```bash
kubectl delete -f sample-app-servicemonitor.yaml
kubectl delete -f sample-app-deployment.yaml
# 保留 kube-prometheus-stack，后续章节会用到
```

## 思考题

1. Prometheus 使用 Pull 模式采集指标。如果一个 Pod 只运行几秒钟（如 Kubernetes Job），Prometheus 可能来不及拉取数据。你会如何解决这个问题？
2. `rate()` 和 `irate()` 函数有什么区别？在什么场景下应该选择哪个？
3. ServiceMonitor 通过 label 选择 Service，而不是直接指定 Service 名称。这种设计有什么好处？
4. 如果 Prometheus 的存储空间满了，会发生什么？你会如何规划 Prometheus 的存储容量？

---

**下一节：** [03-alerting - 告警管理](../03-alerting/)
