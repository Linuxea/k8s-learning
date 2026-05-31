# 08-03 Kubernetes 告警管理

## 为什么需要告警

监控让你"看到"系统的状态，告警让你"知道"什么时候需要介入。

没有告警的监控就像一个没有闹钟的时钟——数据都在，但没人在意。告警的价值在于：

- **主动发现问题**：在用户投诉之前知道系统出了问题
- **减少 MTTR**（Mean Time To Recovery）：快速定位和响应问题
- **量化 SLA**：基于告警数据衡量服务可用性
- **减少 on-call 痛苦**：合理的告警减少无效告警打扰

> **警告：** 告警不是越多越好。过多的告警会导致"告警疲劳"——人们开始忽略所有告警，真正重要的问题反而被淹没。好的告警系统应该是：**该告的告，不该告的不告。**

## 告警架构

### 告警流水线

```
┌───────────────────────────────────────────────────────────┐
│                     告警生命周期                            │
│                                                           │
│  ┌─────────┐    ┌─────────┐    ┌──────────┐    ┌───────┐ │
│  │Prometheus│    │Prometheus│    │Alert-    │    │接收者  │ │
│  │评估规则  │───→│发送告警  │───→│manager   │───→│       │ │
│  │(每15s)   │    │          │    │路由/分组  │    │Email  │ │
│  └─────────┘    └─────────┘    │静默/抑制  │    │Slack  │ │
│                                └──────────┘    │Webhook│ │
│                                                └───────┘ │
└───────────────────────────────────────────────────────────┘
```

1. **Prometheus** 每隔 `evaluation_interval`（默认 15s）评估告警规则
2. 如果规则条件满足，告警进入 **Pending** 状态
3. 持续满足 `for` 时长后，告警进入 **Firing** 状态，发送到 Alertmanager
4. **Alertmanager** 根据配置进行分组、路由、抑制、静默后发送通知

### 为什么需要 Alertmanager

你可能问：为什么 Prometheus 不能直接发通知？

- **分组（Grouping）**：将相关告警合并成一条通知。如某个节点故障引发 50 个告警，合并为一条
- **抑制（Inhibition）**：高级别告警抑制低级别。如"集群不可用"告警触发后，抑制该集群下所有"节点不可用"告警
- **静默（Silencing）**：计划维护期间静默相关告警，不发送通知
- **路由（Routing）**：不同告警发送到不同接收者。如数据库告警发 DBA 团队，网络告警发运维团队

### 告警状态

| 状态 | 说明 | 可视化 |
|------|------|--------|
| **Inactive** | 规则条件不满足，一切正常 | 灰色/无色 |
| **Pending** | 条件满足，但未达到 `for` 时长 | 黄色 |
| **Firing** | 条件满足且达到 `for` 时长，已发送到 Alertmanager | 红色 |

> **`for` 字段的意义：** 避免瞬时波动触发告警。如 CPU 突然飙高 5 秒又降下来，不应该触发告警。`for: 5m` 表示条件必须持续 5 分钟才告警。

## PrometheusRule

在 kube-prometheus-stack 中，告警规则通过 `PrometheusRule` CRD 定义：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  labels:
    prometheus: k8s  # Prometheus Operator 通过此标签选择规则
spec:
  groups:
    - name: my-alerts
      rules:
        - alert: HighMemoryUsage
          expr: |
            (container_memory_working_set_bytes / container_spec_memory_limit_bytes) > 0.8
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ $labels.pod }} 内存使用超过 80%"
            description: "Pod {{ $labels.pod }} 当前内存使用率为 {{ $value | humanizePercentage }}"
```

### PrometheusRule 关键字段

| 字段 | 说明 | 示例 |
|------|------|------|
| `alert` | 告警名称（需简洁、有意义） | `HighMemoryUsage` |
| `expr` | PromQL 表达式，返回值为真时触发 | `(memory_used / memory_limit) > 0.8` |
| `for` | 条件持续多久才触发告警 | `5m` |
| `labels` | 附加标签（用于路由和分类） | `severity: warning` |
| `annotations` | 附加描述信息（用于通知内容） | `summary: "..."` |

### severity 级别约定

| 级别 | 说明 | 响应时间 |
|------|------|---------|
| `critical` | 严重影响用户，需要立即响应 | 5-15 分钟 |
| `warning` | 潜在问题，需要关注但不需要立即行动 | 1-4 小时 |
| `info` | 信息性告警，仅做记录 | 下一工作日 |

## Alertmanager 配置

Alertmanager 的配置通常包含以下几个部分：

### 接收者（Receivers）

定义通知发送的目标：

```yaml
receivers:
  - name: 'slack-notifications'
    slack_configs:
      - channel: '#alerts'
        send_resolved: true    # 告警恢复时也发送通知
```

### 路由（Route）

定义告警如何匹配到接收者：

```yaml
route:
  receiver: 'default'           # 默认接收者
  group_by: ['alertname', 'cluster']  # 按 alertname 和 cluster 分组
  group_wait: 30s               # 新建告警组等待多久发送第一条通知
  group_interval: 5m            # 同组新告警的等待时间
  repeat_interval: 4h           # 重复通知间隔
  routes:
    - match:
        severity: critical
      receiver: 'on-call'       # critical 级别发给 on-call
      repeat_interval: 15m
```

### 抑制（Inhibit）

定义告警之间的抑制关系：

```yaml
inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'namespace']  # 相同 alertname 和 namespace 的 warning 被 critical 抑制
```

## AlertmanagerConfig CRD

在 kube-prometheus-stack 中，可以通过 `AlertmanagerConfig` CRD 来配置 Alertmanager，而不需要直接修改 Alertmanager 的 secret 配置：

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: default
  labels:
    alertmanagerConfig: default  # 被 Alertmanager 选择
spec:
  route:
    groupBy: ['alertname', 'namespace']
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 4h
    receiver: 'webhook'
  receivers:
    - name: 'webhook'
      webhookConfigs:
        - url: 'http://alertmanager-webhook:8080/alerts'
```

## 实战演练

### 前提条件

确保你已经按照 [上一节](../02-monitoring-prometheus/) 安装了 kube-prometheus-stack。

### Step 1：定义告警规则

```bash
# 部署内存告警规则
kubectl apply -f memory-alert-rule.yaml

# 验证规则已被 Prometheus 加载
# 打开 Prometheus UI → Alerts 页面查看
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```

### Step 2：配置 Alertmanager

```bash
# 部署 Alertmanager 配置
kubectl apply -f alertmanager-config.yaml

# 访问 Alertmanager UI
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
```

### Step 3：触发告警

```bash
# 创建一个内存压力 Pod 来触发告警
# 这将尝试消耗内存，使内存使用率超过 80% 阈值
kubectl run memory-stress --image=busybox:1.36 --restart=Never -- \
  sh -c "while true; do dd if=/dev/zero bs=1M count=50 2>/dev/null; sleep 1; done"

# 观察 Pod 内存使用增长
kubectl top pod memory-stress

# 在 Prometheus UI Alerts 页面观察告警状态变化
# Inactive → Pending → Firing（大约需要 5 分钟）
```

### Step 4：在 Alertmanager 中查看告警

```bash
# 在 Alertmanager UI 中可以看到：
# 1. 触发的告警
# 2. 告警的分组情况
# 3. 告警的路由目标
```

### Step 5：清理

```bash
# 删除压力测试 Pod
kubectl delete pod memory-stress --force

# 观察告警自动恢复
# Alertmanager 会发送恢复通知（如果配置了 send_resolved: true）
```

## 告警设计最佳实践

1. **告警应该是可操作的**：收到告警后应该知道该做什么。如果不需要人工介入，就不应该告警
2. **使用 `for` 字段避免抖动**：给条件一个持续时间要求，避免瞬时波动触发告警
3. **合理设置 severity**：不是所有问题都是 critical。过度使用 critical 会导致"狼来了"效应
4. **告警信息要完整**：在 `annotations` 中包含足够的信息，让人不看监控系统就知道发生了什么
5. **配置告警恢复通知**：`send_resolved: true` 让人知道问题已解决
6. **定期审查告警规则**：删除从未触发的告警（说明阈值或条件有问题），优化频繁误报的告警

## 思考题

1. 告警的 `for: 5m` 表示条件需要持续 5 分钟。如果 Prometheus 在这 5 分钟内重启了，计时器会重置吗？这对告警设计有什么影响？
2. Alertmanager 的 `group_by` 和 `group_wait` 分别控制什么？如果一个集群同时产生 100 个不同的告警，你会如何配置分组策略？
3. 什么是"告警疲劳"？你会在 Alertmanager 中使用哪些功能来缓解这个问题？
4. `severity: warning` 和 `severity: critical` 的告警应该分别用什么策略通知？（邮件？电话？Slack？）为什么？

---

**下一节：** [04-tracing - 分布式追踪](../04-tracing/)
