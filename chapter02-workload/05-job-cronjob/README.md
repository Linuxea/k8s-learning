# 05 - Job & CronJob

## 为什么需要 Job

前面学的 Deployment、StatefulSet、DaemonSet 都是管理**长期运行**的服务。它们的 Pod 期望永远运行下去，挂了就重启。

但有些任务**生来就是为了结束的**：

- 数据库迁移（`rails db:migrate`）
- 批量数据处理（每天凌晨处理前一天的数据）
- 数据备份（`pg_dump > backup.sql`）
- 发送邮件/通知（一批用户的通知推送）
- 计算任务（机器学习训练、科学计算）

这些任务的特点：**运行 → 完成 → 退出**。用 Deployment 来管理它们是不合适的，因为 Deployment 的控制器会认为 Pod 退出是异常，会不断重启。

**Job** 就是 K8s 为这类"运行到完成"的任务设计的资源。

## Job

### 核心概念

Job 会创建一个或多个 Pod，并确保它们**成功完成**（exit code 0）。如果 Pod 失败了（exit code 非 0），Job 可以根据策略重试。

```
Job
  ├── Pod 1 → 成功（exit 0）✅
  ├── Pod 2 → 失败（exit 1）❌ → 重试 → 成功 ✅
  └── Pod 3 → 成功（exit 0）✅
  
  当所有 Pod 都成功完成后，Job 状态变为 Complete
```

### 关键字段

| 字段 | 含义 | 默认值 |
|------|------|--------|
| `spec.completions` | 需要成功完成的 Pod 总数 | 1 |
| `spec.parallelism` | 同时运行的 Pod 数量上限 | 1 |
| `spec.backoffLimit` | 最大重试次数（超过则标记为 Failed） | 6 |
| `spec.activeDeadlineSeconds` | Job 的最长运行时间（超时则终止所有 Pod） | — |
| `spec.ttlSecondsAfterFinished` | Job 完成后自动清理的等待时间 | — |
| `spec.restartPolicy` | Pod 的重启策略（Job 只能设 `Never` 或 `OnFailure`） | — |
| `spec.completionMode` | 完成模式：`NonIndexed`（默认）或 `Indexed` | `NonIndexed` |

### restartPolicy 的两种选择

| 策略 | 失败后的行为 |
|------|------------|
| `Never` | 不重启失败的 Pod，创建一个新的 Pod 来重试。旧的失败 Pod 保留（方便排查） |
| `OnFailure` | 在同一个 Pod 内重启容器（不创建新 Pod）。失败 Pod 数量不会增加 |

> 推荐用 `Never` — 保留失败 Pod 的日志和状态，方便排查问题。

### Job 的三种模式

根据 `completions` 和 `parallelism` 的组合：

| 模式 | completions | parallelism | 行为 |
|------|------------|-------------|------|
| **单次任务** | 1（默认） | 1（默认） | 创建 1 个 Pod，运行到完成 |
| **固定完成数** | N | M | 总共需要 N 个 Pod 成功完成，最多 M 个同时运行 |
| **工作队列** | 1 | M | 所有 M 个 Pod 并行运行，任意 1 个成功就算完成 |

#### 单次任务

```yaml
# 最简单的 Job：一个 Pod，运行到完成
spec:
  template:
    spec:
      containers:
        - name: task
          image: busybox
          command: ["echo", "Hello, World!"]
      restartPolicy: Never
```

#### 固定完成数

```yaml
# 需要 5 个 Pod 都成功完成，最多 2 个并行
spec:
  completions: 5
  parallelism: 2
  template:
    spec:
      restartPolicy: Never
```

运行过程：

```
Round 1: Pod-1 ✅ Pod-2 ✅     （2 个并行）
Round 2: Pod-3 ✅ Pod-4 ❌     （Pod-4 失败，重试）
Round 2: Pod-5 ✅ Pod-4-retry ✅ （全部完成）
```

#### 工作队列

```yaml
# 所有 Pod 并行运行，任意一个成功就算 Job 完成
spec:
  completions: 1       # 只需要 1 个成功
  parallelism: 5       # 5 个同时跑
  template:
    spec:
      restartPolicy: Never
```

> 这种模式适用于"谁先完成就算"的场景，比如分布式任务的竞争执行。

## CronJob

如果说 Job 是"运行一次"，那么 **CronJob** 就是"定时运行"。

CronJob 在 Job 之上加了一层调度器：按照 cron 表达式的时间表，自动创建 Job。

### Cron 表达式

```
# 格式
┌───────────── 分钟 (0-59)
│ ┌───────────── 小时 (0-23)
│ │ ┌───────────── 日 (1-31)
│ │ │ ┌───────────── 月 (1-12)
│ │ │ │ ┌───────────── 星期 (0-6, 0=周日)
│ │ │ │ │
* * * * *
```

| 表达式 | 含义 |
|--------|------|
| `*/1 * * * *` | 每 1 分钟 |
| `0 * * * *` | 每小时整点 |
| `0 2 * * *` | 每天凌晨 2 点 |
| `0 0 * * 1` | 每周一零点 |
| `0 0 1 * *` | 每月 1 号零点 |
| `*/15 * * * *` | 每 15 分钟 |

> K8s 的 cron 格式和 Linux 的 crontab 一样。如果你嫌手写麻烦，可以用 [crontab.guru](https://crontab.guru) 来生成和验证。

### 关键字段

| 字段 | 含义 |
|------|------|
| `spec.schedule` | Cron 表达式，决定何时创建 Job |
| `spec.jobTemplate` | Job 模板，每次触发生成的 Job 的规格 |
| `spec.concurrencyPolicy` | 并发策略 |
| `spec.startingDeadlineSeconds` | 启动截止时间 |
| `spec.successfulJobsHistoryLimit` | 保留多少个成功完成的 Job 记录 | 3 |
| `spec.failedJobsHistoryLimit` | 保留多少个失败的 Job 记录 | 1 |
| `spec.suspend` | 设为 `true` 可暂停 CronJob，不再创建新 Job |

### 并发策略（concurrencyPolicy）

| 策略 | 行为 |
|------|------|
| `Allow`（默认） | 允许同时存在多个 Job。即使上一个 Job 还没完成，到时间了就创建新的 |
| `Forbid` | 如果上一个 Job 还没完成，跳过本次调度。**不创建新 Job** |
| `Replace` | 如果上一个 Job 还没完成，**终止旧的，创建新的** |

> `Forbid` 是最安全的选择 — 防止任务堆积。适用于"数据处理"这类不应该并发执行的任务。

### startingDeadlineSeconds

如果 CronJob 控制器因为某种原因（比如控制器崩溃）错过了调度时间，这个字段指定了"错过多少秒内仍然可以启动"。

```yaml
startingDeadlineSeconds: 200
# 如果本该在 10:00 运行但错过了，在 10:03:20 之前仍然可以启动
```

> 如果不设置，错过就错过了，不会补运行。

## Step by Step 操作

### Step 1: 创建单次 Job

```bash
kubectl apply -f pi-job.yaml

# 查看 Job 状态
kubectl get jobs
# NAME       COMPLETIONS   DURATION   AGE
# pi-calc    1/1           12s        15s

# 查看 Pod（Job 创建的 Pod 名字带 hash 后缀）
kubectl get pods -l job-name=pi-calc
# NAME             READY   STATUS      RESTARTS   AGE
# pi-calc-abc12    0/1     Completed   0          20s

# 查看计算结果
kubectl logs job/pi-calc
# 3.14159265358979323846264338327950288419716939937510...
```

注意 Pod 的状态是 `Completed` 而不是 `Running` — 任务已经完成了。

### Step 2: 查看已完成的 Job

```bash
kubectl describe job pi-calc
# 重点关注 Events 和 Pod Status 部分

# Events:
#   Normal  SuccessfulCreate  30s   job-controller  Created pod: pi-calc-abc12
#   Normal  Completed         18s   job-controller  Job completed
```

### Step 3: 创建批量 Job

```bash
kubectl apply -f batch-job.yaml

# 观察 Pod 的创建过程
kubectl get pods -l job-name=batch-demo -w
# 你会看到 Pod 陆续被创建（parallelism: 2，最多 2 个同时运行）
# 完成一个后创建下一个，直到完成 5 个（completions: 5）

# Ctrl+C 退出 watch

# 查看 Job 状态
kubectl get job batch-demo
# NAME         COMPLETIONS   DURATION   AGE
# batch-demo   5/5           45s        50s
```

### Step 4: 模拟 Job 失败

```bash
# 创建一个注定失败的 Job
kubectl create job fail-demo --image=busybox:1.36 -- exit 1

# 查看 Pod 状态
kubectl get pods -l job-name=fail-demo
# NAME             READY   STATUS   RESTARTS   AGE
# fail-demo-abc12  0/1     Error    0          10s

# 如果 restartPolicy: Never，Job 控制器会创建新 Pod 重试
# 等一会儿再看
kubectl get pods -l job-name=fail-demo
# NAME             READY   STATUS   RESTARTS   AGE
# fail-demo-abc12  0/1     Error    0          30s
# fail-demo-def34  0/1     Error    0          15s  ← 重试的 Pod
# ... 最多重试 6 次（backoffLimit 默认值）

# 查看 Job 状态
kubectl get job fail-demo
# NAME        COMPLETIONS   DURATION   AGE
# fail-demo   0/1           60s        60s

# 查看 Job 事件
kubectl describe job fail-demo
# Events:
#   Warning  Failed  ...  Error: exit status 1
#   ...
```

### Step 5: 清理失败的 Job

```bash
kubectl delete job fail-demo
```

### Step 6: 创建 CronJob

```bash
kubectl apply -f hello-cronjob.yaml

# 查看 CronJob
kubectl get cronjob
# NAME              SCHEDULE      SUSPEND   ACTIVE   LAST SCHEDULE   AGE
# hello-cronjob     */1 * * * *   False     0        <none>          5s

# 等一分钟，让 CronJob 触发一次
# 你可以用 -w 来 watch
kubectl get jobs -w
# 等一分钟后你会看到：
# NAME                        COMPLETIONS   DURATION   AGE
# hello-cronjob-28476312      1/1           2s         10s
```

### Step 7: 查看定时 Job 的输出

```bash
# 找到最近创建的 Job 对应的 Pod
kubectl get pods --sort-by=.metadata.creationTimestamp -l app=hello-cronjob

# 查看日志
kubectl logs -l app=hello-cronjob --tail=3
# Mon Jan 15 10:30:00 UTC 2024
# Hello from CronJob!
```

### Step 8: 查看定时历史

```bash
# 等几分钟，让 CronJob 多运行几次
kubectl get jobs -l app=hello-cronjob
# NAME                    COMPLETIONS   DURATION   AGE
# hello-cronjob-28476312  1/1           2s         5m
# hello-cronjob-28476313  1/1           2s         4m
# hello-cronjob-28476314  1/1           2s         3m
# hello-cronjob-28476315  1/1           2s         2m
# hello-cronjob-28476316  1/1           2s         1m

# CronJob 自动清理旧的 Job（successfulJobsHistoryLimit: 3）
# 超过 3 个的会被自动删除
```

### Step 9: 暂停和恢复 CronJob

```bash
# 暂停（不再创建新 Job）
kubectl patch cronjob hello-cronjob -p '{"spec":{"suspend":true}}'

# 查看
kubectl get cronjob
# SUSPEND = True

# 恢复
kubectl patch cronjob hello-cronjob -p '{"spec":{"suspend":false}}'
```

### Step 10: 手动触发 CronJob

```bash
# 不等 schedule，手动创建一个 Job
kubectl create job --from=cronjob/hello-cronjob manual-run

# 查看手动创建的 Job
kubectl get job manual-run
# NAME         COMPLETIONS   DURATION   AGE
# manual-run   1/1           3s         10s
```

### Step 11: 清理

```bash
kubectl delete -f pi-job.yaml
kubectl delete -f batch-job.yaml
kubectl delete -f hello-cronjob.yaml

# 删除手动创建的 Job
kubectl delete job manual-run 2>/dev/null
```

## Job 的 Pod 终止行为

Job 中的 Pod 有一个特殊的生命周期：

| 状态 | 含义 |
|------|------|
| `Completed` | Pod 中的容器以 exit code 0 退出。Job 成功 |
| `Error` | Pod 中的容器以非 0 exit code 退出。Job 会根据 `backoffLimit` 决定是否重试 |
| `OOMKilled` | 容器内存超限被杀。检查 `resources.limits.memory` 是否太小 |
| `ImagePullBackOff` | 镜像拉取失败。检查镜像名和仓库访问权限 |

> `Completed` 状态的 Pod **不会消失**，它们会一直保留，直到 Job 被删除或 `ttlSecondsAfterFinished` 生效。这是为了让你能查看日志和状态。

## 最佳实践

1. **总是设置 `backoffLimit`** — 防止失败任务无限重试
2. **总是设置 `activeDeadlineSeconds`** — 防止任务永远跑不完
3. **使用 `ttlSecondsAfterFinished`** — 自动清理已完成的 Job，避免 Job 堆积
4. **CronJob 用 `Forbid` 并发策略** — 防止任务堆积
5. **设置合理的 `resources`** — Job 也要限制资源，防止一个任务吃光节点资源

```yaml
# 推荐的 Job 配置
spec:
  backoffLimit: 3
  activeDeadlineSeconds: 300    # 最多运行 5 分钟
  ttlSecondsAfterFinished: 3600 # 完成后 1 小时自动清理
  template:
    spec:
      restartPolicy: Never
```

## 思考题

1. Job 的 `parallelism` 设为 0 会发生什么？这个配置有实际用途吗？
2. 如果 CronJob 的 `concurrencyPolicy` 设为 `Allow`，而上一次调度的 Job 一直没有完成（比如卡住了），会发生什么？怎样防止这种情况？
3. `ttlSecondsAfterFinished` 和手动 `kubectl delete job` 相比有什么优势？什么情况下你不应该用自动清理？
4. 你能想到什么场景下，一个 CronJob 的 `startingDeadlineSeconds` 设得太小会有问题？

---

[返回目录](../../)
