# 03 - Pod 生命周期

## Pod 的完整生命周期

一个 Pod 从被提交到 K8s，到最终被删除，经历了一系列明确的状态转换。理解这个过程，是排查 Pod 问题的基本功。

```
用户提交 YAML
      │
      ▼
   Pending  ──────── 调度到节点 + 拉取镜像 + 启动容器
      │
      ▼
   Running  ──────── 容器正常运行
      │
      ├──► Succeeded   所有容器正常退出（exit code 0），不会重启
      ├──► Failed      至少一个容器异常退出（exit code ≠ 0）
      └──► Unknown     无法与节点通信（节点故障）
```

### Phase 详解

| Phase | 含义 | 你会看到这个状态的常见原因 |
|-------|------|--------------------------|
| **Pending** | K8s 已接受这个 Pod，但还没开始运行 | 正在调度、正在拉镜像、Init 容器还没跑完 |
| **Running** | Pod 已绑定到节点，至少一个容器还在运行或正在启动 | 正常运行中 |
| **Succeeded** | 所有容器正常退出，且 `restartPolicy` 不要求重启 | 一次性任务（Job、CronJob）正常完成 |
| **Failed** | 至少一个容器异常退出 | 程序崩溃、OOM、被信号杀死 |
| **Unknown** | 无法获取 Pod 状态 | 节点宕机、网络分区、kubelet 挂了 |

> 注意：Phase 是**粗粒度**的状态。一个 `Running` 的 Pod 里面，容器可能有不同的细粒度状态。

## 容器状态（Container States）

每个容器有自己的状态，比 Pod Phase 更细粒度：

### Waiting（等待中）

容器还没开始运行。常见原因：

| 原因 | 说明 |
|------|------|
| `ContainerCreating` | 正在创建容器（拉镜像、挂载 Volume） |
| `CrashLoopBackOff` | 容器启动后崩溃，正在等待重启 |
| `ImagePullBackOff` | 拉取镜像失败（镜像不存在、无权限） |
| `ErrImagePull` | 拉取镜像出错 |

```bash
# 查看 Waiting 状态的原因
kubectl describe pod <name> | grep -A5 "State"
```

### Running（运行中）

容器正在正常运行，`Started At` 字段记录了启动时间。

### Terminated（已终止）

容器已退出。重点关注：

| 字段 | 含义 |
|------|------|
| `Exit Code` | 退出码。0 = 正常，非 0 = 异常 |
| `Reason` | 退出原因（OOMKilled、Error、Completed 等） |
| `Message` | 人类可读的退出信息 |
| `Started At` | 容器启动时间 |
| `Finished At` | 容器退出时间 |

```bash
# 查看容器退出信息
kubectl describe pod <name> | grep -A10 "Last State"
```

> Exit Code 137 = 被 SIGKILL 杀死（通常是 OOM）。Exit Code 1 = 应用错误。Exit Code 0 = 正常退出。

## restartPolicy（重启策略）

当一个容器退出后，K8s 是否要重启它？这取决于 `restartPolicy`：

| 策略 | 行为 | 适用场景 |
|------|------|---------|
| **Always**（默认） | 容器退出后总是重启 | 长期运行的服务（Web 服务器、API 等） |
| **OnFailure** | 仅当容器以非 0 退出码退出时重启 | 一次性任务（数据处理、备份等） |
| **Never** | 永远不重启 | 不允许重试的任务、调试场景 |

> `restartPolicy` 作用于 **Pod 内所有容器**，包括 Init 容器。不能给单个容器设置不同的重启策略。

### 重启的退避机制

K8s 不会无限快速重启。重启间隔会指数增长：10s → 20s → 40s → 80s → 160s → 300s（上限 5 分钟）。这就是 `CrashLoopBackOff` 的来源。

```
容器崩溃 → 等 10s 重启 → 再崩溃 → 等 20s 重启 → 再崩溃 → ...
状态显示: CrashLoopBackOff   RESTARTS: 5
```

## Init Containers（初始化容器）

### Init 容器是什么

Init 容器是在**主容器启动之前**运行的专用容器，用于完成初始化工作。

```
┌─────────────────────────────────────┐
│              Pod                     │
│                                     │
│  ┌─────────────┐                    │
│  │ Init 容器 1  │ ← 最先运行         │
│  └──────┬──────┘                    │
│         │ 成功后                     │
│  ┌──────▼──────┐                    │
│  │ Init 容器 2  │ ← 第二个运行       │
│  └──────┬──────┘                    │
│         │ 全部成功后                  │
│  ┌──────▼──────────────────┐       │
│  │ 主容器 1  │  主容器 2     │ ← 最后启动
│  └─────────────────────────┘       │
└─────────────────────────────────────┘
```

### Init 容器 vs 普通容器

| 特性 | Init 容器 | 普通容器 |
|------|----------|---------|
| 运行时机 | 主容器之前 | 主容器启动后 |
| 运行次数 | 必须成功完成后才停（按顺序） | 持续运行 |
| 失败行为 | 阻塞主容器启动，按 restartPolicy 重试 | 按 restartPolicy 重启 |
| 支持探针 | 不支持 liveness/readiness probe | 支持 |
| 数量 | 可以有多个，按顺序执行 | 可以有多个，同时运行 |

### 为什么需要 Init 容器

真实场景举例：

1. **等待依赖就绪** — 等数据库启动完成再启动应用
2. **下载配置/证书** — 从配置中心或 S3 下载配置文件到共享 Volume
3. **数据库迁移** — 在应用启动前执行 schema 迁移
4. **权限设置** — 修改共享 Volume 的文件权限

> Init 容器和主容器不共享同一个镜像，所以可以用不同的工具。比如主容器用的是精简的 nginx 镜像（没有 curl/wget），但 Init 容器可以用 alpine 来下载文件。

## 容器生命周期钩子（Lifecycle Hooks）

K8s 提供了两个钩子，让你在容器生命周期的关键时刻执行操作：

### postStart

- **时机**：容器创建后**立即**执行（不保证在容器的 ENTRYPOINT 之前）
- **用途**：注册服务、发送通知、初始化配置
- **注意**：如果 postStart 执行失败，容器会被杀死并重启

### preStop

- **时机**：容器被终止前**同步**执行（执行完才发送 SIGTERM）
- **用途**：优雅关闭（通知负载均衡器下线、完成进行中的请求）
- **注意**：preStop 会计入 `terminationGracePeriodSeconds` 的时间

```
容器启动 → postStart 执行 → 容器正常运行 → 收到删除请求
                                              │
                                    preStop 执行 ← 阻塞，直到完成
                                              │
                                    SIGTERM 发送给 PID 1
                                              │
                                    等待 terminationGracePeriodSeconds
                                              │
                                    SIGKILL（如果还没退出）
```

### 钩子的处理器类型

| 类型 | 示例 |
|------|------|
| `exec` | 在容器内执行命令 |
| `httpGet` | 向容器发送 HTTP 请求 |

## terminationGracePeriodSeconds（优雅关闭）

当你删除一个 Pod（或 Deployment 滚动更新时），K8s 不会直接"拔电源"：

```
kubectl delete pod my-app
         │
         ▼
  1. preStop 钩子执行（如果配置了）
         │
         ▼
  2. 发送 SIGTERM 给容器 PID 1 进程
         │
         ▼
  3. 等待 terminationGracePeriodSeconds（默认 30 秒）
         │
         ├── 进程在时间内退出 → 正常删除
         │
         └── 超时 → 发送 SIGKILL 强制杀死
```

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `terminationGracePeriodSeconds` | 30 | 从发送 SIGTERM 到 SIGKILL 的等待时间 |

> **常见坑**：如果你的容器用 shell 脚本启动（`/bin/sh -c "..."`），SIGTERM 会发给 shell 而不是你的应用进程。shell 默认不会转发信号，导致应用收不到 SIGTERM，最终被 SIGKILL 强杀。解决方案：用 `exec` 替换 shell 进程（`exec ./my-app`），或使用 `tini` 等init 系统。

## Step by Step：观察 Init 容器

### Step 1: 创建带 Init 容器的 Pod

```bash
kubectl apply -f init-container-demo.yaml

# Pod 会卡在 Init 状态
kubectl get pods
# NAME                  READY   STATUS     RESTARTS   AGE
# init-demo             0/1     Init:0/1   0          5s
```

`Init:0/1` 表示总共有 1 个 Init 容器，0 个已完成。

### Step 2: 观察 Init 容器

```bash
# 查看 Init 容器的日志
kubectl logs init-demo --init-container

# 查看 Init 容器的状态
kubectl describe pod init-demo | grep -A10 "Init Containers"
```

Init 容器会等待约 15 秒（模拟依赖检查），完成后主容器才会启动。

### Step 3: 等待主容器启动

```bash
# 持续观察状态变化
kubectl get pods -w
# Init:0/1 → Init:0/1 → PodInitializing → Running

# 或等待就绪
kubectl wait --for=condition=Ready pod/init-demo --timeout=60s

# 验证主容器在运行
kubectl exec init-demo -- cat /etc/hosts
```

### Step 4: 清理

```bash
kubectl delete -f init-container-demo.yaml
```

## Step by Step：观察 restartPolicy

### Step 1: 创建 restartPolicy: Never 的 Pod

```bash
kubectl apply -f restart-policy-demo.yaml

# 观察状态变化
kubectl get pods -w
# restart-demo   0/1     ContainerCreating   0          0s
# restart-demo   0/1     Completed           0          5s
```

容器执行 `echo` 后退出（exit code 0），状态变为 `Completed`。

### Step 2: 查看 Pod 详情

```bash
kubectl describe pod restart-demo

# 关注这些信息：
# Status:         Succeeded
# Container Statuses:
#   State:          Terminated
#     Reason:       Completed
#     Exit Code:    0
```

因为 `restartPolicy: Never`，K8s 不会重启这个容器。如果改成 `Always`，它会立即被重启。

### Step 3: 清理

```bash
kubectl delete -f restart-policy-demo.yaml
```

## Step by Step：观察 Lifecycle Hook

### Step 1: 创建带钩子的 Pod

```bash
kubectl apply -f lifecycle-hook-demo.yaml

# 等待就绪
kubectl wait --for=condition=Ready pod/lifecycle-demo --timeout=30s
```

### Step 2: 验证 postStart 执行了

```bash
# postStart 会往 /tmp/lifecycle.log 写入启动消息
kubectl exec lifecycle-demo -- cat /tmp/lifecycle.log
# 输出类似：
# postStart hook executed at: Mon Jun 01 12:00:00 UTC 2026
```

### Step 3: 触发 preStop 并验证

```bash
# 删除 Pod 时 preStop 会执行（但由于 Pod 立刻被删除，不容易看到）
# 更好的方式：先查看日志
kubectl logs lifecycle-demo

# 删除 Pod
kubectl delete -f lifecycle-hook-demo.yaml
```

> preStop 的输出在 Pod 删除后很难捕获，因为 Pod 很快就没了。在生产环境中，preStop 通常调用外部服务（如通知负载均衡器下线），效果更容易观察。

## 关键概念总结

| 概念 | 要点 |
|------|------|
| Pod Phase | Pending → Running → Succeeded/Failed/Unknown |
| 容器状态 | Waiting / Running / Terminated（比 Phase 更细粒度） |
| restartPolicy | Always（默认）/ OnFailure / Never |
| Init 容器 | 按顺序执行，全部成功后主容器才启动 |
| postStart | 容器创建后执行，失败会触发重启 |
| preStop | 容器终止前执行，用于优雅关闭 |
| 优雅关闭 | preStop → SIGTERM → 等待 → SIGKILL |

## 思考题

1. 如果一个 Pod 有 3 个 Init 容器，第二个失败了，第一个会重新执行吗？第三个会执行吗？
2. `CrashLoopBackOff` 和 `Error` 状态有什么区别？分别对应什么 `restartPolicy`？
3. 为什么 `postStart` 不能保证在容器的 `ENTRYPOINT` 之前执行？这会带来什么问题？
4. 一个容器内运行的 Java 应用需要 20 秒来做优雅关闭（完成进行中的请求），`terminationGracePeriodSeconds` 应该设为多少？为什么？

---

下一个 → [04 - 健康检查](../04-health-probe/)
