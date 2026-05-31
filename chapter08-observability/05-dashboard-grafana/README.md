# 08-05 Grafana 可视化

## 为什么需要 Grafana

Prometheus 提供了数据存储和查询能力，但它的 UI 只是基础的查询界面。Grafana 是一个专门的可视化平台，让监控数据变得直观、易懂：

| 能力 | Prometheus UI | Grafana |
|------|--------------|---------|
| 执行 PromQL | ✅ | ✅ |
| 图表可视化 | 基础 | 丰富（折线图、热力图、仪表盘等） |
| 仪表盘管理 | ❌ | ✅ 模板变量、多面板组合 |
| 数据源聚合 | ❌ | ✅ 同时查 Prometheus + Loki + Jaeger |
| 告警 | 规则定义 | 可视化告警 + 多渠道通知 |
| 分享和协作 | ❌ | ✅ 链接、快照、嵌入 |
| 权限管理 | ❌ | ✅ 组织、团队、角色 |

> **核心理念：** Prometheus 负责数据采集和存储，Grafana 负责数据展示。两者分工明确。

## Grafana 核心概念

### 数据源（Data Source）

Grafana 不存储任何监控数据，它从数据源查询数据：

| 数据源 | 类型 | 用途 |
|--------|------|------|
| Prometheus | 指标 | 时序数据（CPU、内存、QPS 等） |
| Loki | 日志 | 日志搜索和分析 |
| Jaeger / Tempo | 追踪 | 分布式追踪数据 |
| Elasticsearch | 日志/指标 | 全文搜索和日志分析 |
| InfluxDB | 指标 | 时序数据 |
| PostgreSQL | 表格 | 业务数据 |

kube-prometheus-stack 已经自动配置了 Prometheus 作为数据源。

### 仪表盘（Dashboard）

仪表盘是 Grafana 的核心组织单元，由多个面板（Panel）组成：

```
┌─────────────────── Kubernetes 集群监控 ───────────────────┐
│  变量: namespace=[全部]  node=[全部]                       │
│                                                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │ 节点数: 3     │  │ Pod 总数: 45  │  │ CPU 使用率    │    │
│  │   (Stat)     │  │   (Stat)     │  │   42% (Gauge) │    │
│  └──────────────┘  └──────────────┘  └──────────────┘    │
│                                                           │
│  ┌───────────────────────────────────────────────────┐    │
│  │  CPU 使用率趋势（折线图）                            │    │
│  │  ╱╲    ╱╲                                         │    │
│  │ ╱  ╲╱╱  ╲    ← 每个节点一条线                      │    │
│  │╱        ╲╱╲                                      │    │
│  └───────────────────────────────────────────────────┘    │
│                                                           │
│  ┌───────────────────────────────────────────────────┐    │
│  │  内存使用趋势（面积图）                              │    │
│  └───────────────────────────────────────────────────┘    │
│                                                           │
│  ┌───────────────────────────────────────────────────┐    │
│  │  Pod 状态表格（Table）                              │    │
│  │  Pod Name | CPU | Memory | Status | Restarts       │    │
│  └───────────────────────────────────────────────────┘    │
└───────────────────────────────────────────────────────────┘
```

### 面板类型

| 类型 | 说明 | 适用场景 |
|------|------|---------|
| Time Series | 折线图/面积图 | CPU、内存等时序数据 |
| Stat | 大数字展示 | 计数、百分比、当前值 |
| Gauge | 仪表盘 | 使用率百分比 |
| Table | 表格 | Pod 列表、配置对比 |
| Heatmap | 热力图 | 延迟分布 |
| Bar Chart | 柱状图 | 不同服务的请求量对比 |
| Logs | 日志面板 | 展示 Loki 日志查询结果 |
| Trace | 追踪面板 | 展示 Jaeger/Tempo 追踪 |

### 模板变量（Variables）

变量让仪表盘变得动态和可复用：

```yaml
变量:
  - name: namespace
    type: query
    query: label_values(kube_pod_info, namespace)
    # 下拉框动态列出所有命名空间

  - name: pod
    type: query
    query: label_values(kube_pod_info{namespace="$namespace"}, pod)
    # Pod 列表根据选中的 namespace 过滤
```

在 PromQL 中使用变量：

```promql
# $namespace 和 $pod 会被替换为用户选择的值
container_cpu_usage_seconds_total{namespace="$namespace", pod="$pod"}
```

> **提示：** 好的仪表盘应该使用变量，让用户可以在不同命名空间、节点、Pod 之间切换，而不需要创建多个仪表盘。

### 仪表盘导入方式

| 方式 | 说明 |
|------|------|
| 手动创建 | 在 Grafana UI 中一步步添加面板 |
| 导入 JSON | 从文件或 Grafana.com 导入 |
| ConfigMap | 通过 ConfigMap 定义仪表盘，自动同步到 Grafana |
| Helm Values | 在 kube-prometheus-stack 的 values 中配置 |

## kube-prometheus-stack 的 Grafana

kube-prometheus-stack 自带大量预构建仪表盘：

| 仪表盘 | 监控内容 |
|--------|---------|
| Kubernetes / Compute Resources / Cluster | 集群整体资源使用 |
| Kubernetes / Compute Resources / Namespace (Pods) | 按命名空间的 Pod 资源 |
| Kubernetes / Compute Resources / Node (Nodes) | 节点资源详情 |
| Node Exporter / Nodes | 节点硬件指标（CPU、内存、磁盘、网络） |
| Kubernetes / Networking / Cluster | 集群网络流量 |
| Kubernetes / Kubelet | Kubelet 指标 |

这些仪表盘由 Grafana sidecar 自动从 ConfigMap 中发现和加载。

## 实战演练

### 前提条件

确保你已经按照 [02-monitoring-prometheus](../02-monitoring-prometheus/) 安装了 kube-prometheus-stack。

### Step 1：访问 Grafana

```bash
# 使用 port-forward 访问 Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# 浏览器打开 http://localhost:3000
# 默认用户名: admin
# 默认密码: admin（在 prometheus-values.yaml 中配置的）
```

### Step 2：探索预构建仪表盘

1. 登录后点击左侧菜单 **Dashboards**
2. 浏览 **Kubernetes** 文件夹下的仪表盘
3. 打开 "Kubernetes / Compute Resources / Cluster"
4. 观察：
   - 顶部是集群概览（节点数、CPU/内存总量）
   - 中间是时序图（CPU/内存趋势）
   - 下方是表格（各命名空间的资源使用）

### Step 3：创建自定义仪表盘

1. 点击 **Dashboards → New Dashboard → Add Query**
2. 在查询框输入 PromQL：

```promql
# 集群 CPU 使用率
sum(rate(node_cpu_seconds_total{mode!="idle"}[5m])) / sum(rate(node_cpu_seconds_total[5m])) * 100
```

3. 设置面板标题为 "Cluster CPU Usage"
4. 切换面板类型为 **Stat**（大数字显示）
5. 设置单位为 `percent (0-100)`
6. 保存仪表盘为 "My K8s Dashboard"

### Step 4：通过 ConfigMap 部署自定义仪表盘

```bash
# 通过 ConfigMap 部署预定义的仪表盘
# Grafana sidecar 会自动检测并加载
kubectl apply -f custom-dashboard-configmap.yaml

# 等待 30-60 秒让 Grafana 加载新仪表盘
# 在 Grafana UI → Dashboards 中查看 "K8s Quick Overview"
```

### Step 5：导入社区仪表盘

1. 访问 [Grafana Dashboards](https://grafana.com/grafana/dashboards/)
2. 搜索 "kubernetes" 找到你感兴趣的仪表盘
3. 复制仪表盘 ID（如 `15760`）
4. 在 Grafana 中点击 **Dashboards → Import**
5. 粘贴 ID，点击 Load
6. 选择 Prometheus 数据源，点击 Import

### Step 6：自定义 Grafana 配置

```bash
# 如果要修改 Grafana 的默认配置（如插件、数据源、仪表盘）
# 编辑 grafana-values.yaml 后升级 Helm release
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f grafana-values.yaml
```

### Step 7：清理（可选）

```bash
# 删除自定义仪表盘
kubectl delete -f custom-dashboard-configmap.yaml

# 如果要完全卸载 kube-prometheus-stack
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete namespace monitoring
```

## 仪表盘设计最佳实践

1. **从上到下，从宏观到微观**：先展示集群概览，再到命名空间，最后到 Pod
2. **使用变量**：让一个仪表盘通过下拉框切换不同维度
3. **设置合理的刷新间隔**：实时仪表盘 10s，历史分析仪表盘 1m
4. **善用颜色和阈值**：绿色 = 正常，黄色 = 警告，红色 = 危险
5. **避免仪表盘过载**：一个仪表盘 6-12 个面板足够。太多面板会降低性能
6. **版本控制**：用 ConfigMap 或 JSON 文件管理仪表盘，纳入 Git 版本控制

## 思考题

1. Grafana 的模板变量（Variable）是如何实现"一个仪表盘，多种视角"的？试想一个监控 10 个微服务的仪表盘，你会定义哪些变量？
2. 如果 Grafana 和 Prometheus 之间的网络中断，已有的仪表盘会怎样？恢复后数据会自动补全吗？
3. kube-prometheus-stack 通过 ConfigMap 自动同步仪表盘到 Grafana。如果有人在 Grafana UI 上手动修改了这些仪表盘，下次同步时会被覆盖吗？你会如何管理自定义仪表盘？
4. 一个好的 Kubernetes 监控仪表盘应该包含哪些核心面板？如果你只能选择 5 个指标来监控集群健康，你会选哪 5 个？

---

**恭喜你完成了第八章的学习！** 🎉

回顾整个可观测性体系：
- **日志** → 记录"发生了什么"（[01-logging](../01-logging/)）
- **监控** → 量化"现在怎么样"（[02-monitoring-prometheus](../02-monitoring-prometheus/)）
- **告警** → 通知"需要关注什么"（[03-alerting](../03-alerting/)）
- **追踪** → 还原"请求经过了哪里"（[04-tracing](../04-tracing/)）
- **可视化** → 展示"一切一目了然"（[05-dashboard-grafana](../05-dashboard-grafana/)）
