# 07-04 Helm Hook 生命周期钩子

## 什么是 Helm Hook？

Helm 的模板文件默认行为是：**渲染成 K8s 资源 → 创建到集群中 → 成为 Release 的一部分**。

但有些场景你需要在特定时机执行一次性任务，比如：
- **数据库迁移**：在升级应用之前，先执行 SQL 迁移脚本
- **初始化配置**：安装应用之前，先创建必要的配置或密钥
- **冒烟测试**：安装完成后，验证服务是否正常工作
- **清理工作**：卸载之前，备份或清理资源

**Hook 就是让模板在 Release 生命周期的特定时刻执行**，执行完后不会成为 Release 的一部分。

> **核心区别**：普通模板 = 持久存在的资源（Deployment、Service）；Hook 模板 = 临时执行的任务（Job），执行完可以选择保留或删除。

## Hook 类型

| Hook 类型 | 触发时机 | 典型用途 |
|-----------|---------|---------|
| `pre-install` | `helm install` 执行**之前**（资源还未创建） | 创建密钥、初始化配置 |
| `post-install` | `helm install` 执行**之后**（资源已创建） | 通知、注册、冒烟测试 |
| `pre-upgrade` | `helm upgrade` 执行**之前** | 数据库迁移、备份 |
| `post-upgrade` | `helm upgrade` 执行**之后** | 验证升级结果、清理旧资源 |
| `pre-delete` | `helm uninstall` 执行**之前** | 数据备份、优雅关闭通知 |
| `post-delete` | `helm uninstall` 执行**之后** | 清理外部资源 |
| `pre-rollback` | `helm rollback` 执行**之前** | 准备回滚环境 |
| `post-rollback` | `helm rollback` 执行**之后** | 验证回滚结果 |
| `test` | `helm test` 执行时 | 集成测试、冒烟测试 |

### Hook 执行顺序

```
helm install
  ├── 1. pre-install hooks（按 weight 排序执行）
  ├── 2. 普通 templates 渲染并创建
  └── 3. post-install hooks（按 weight 排序执行）

helm upgrade
  ├── 1. pre-upgrade hooks
  ├── 2. 普通 templates 渲染并更新
  └── 3. post-upgrade hooks
```

## Hook 注解（Annotations）

Hook 通过 K8s 资源的注解来声明，共三个：

### 1. `helm.sh/hook`（必须）

声明这是一个 Hook，以及触发的时机：

```yaml
annotations:
  "helm.sh/hook": pre-install
```

可以指定多个时机（用逗号分隔）：

```yaml
annotations:
  "helm.sh/hook": pre-install,pre-upgrade
```

### 2. `helm.sh/hook-weight`（可选）

当同一个时机有多个 Hook 时，按 weight 数值从小到大执行：

```yaml
annotations:
  "helm.sh/hook-weight": "-5"
  # 负数也可以，数字越小越先执行
```

> 默认 weight 为 0。相同 weight 的 Hook 执行顺序不确定。

### 3. `helm.sh/hook-delete-policy`（可选）

控制 Hook 资源在执行后的处理方式：

| 策略 | 说明 |
|------|------|
| `hook-succeeded` | Hook 成功执行后自动删除 |
| `hook-failed` | Hook 执行失败后自动删除 |
| `before-hook-creation` | 下一次 Hook 执行前删除上一次的资源（默认行为） |

```yaml
annotations:
  "helm.sh/hook-delete-policy": hook-succeeded,hook-failed
  # 无论成功失败都自动删除，保持集群干净
```

> **如果不指定 delete-policy**，Helm 默认使用 `before-hook-creation`——即下次执行 Hook 前删除旧的 Hook 资源。这意味着第一次执行后 Hook 资源会留在集群中，直到下次执行前才清理。

## Hook 的限制

1. **Hook 资源不在 Release 管理范围内**：`helm uninstall` 不会删除 Hook 创建的资源（除非 Hook 本身是 pre-delete/post-delete）
2. **Hook 失败会中断操作**：如果 pre-install Hook 失败，整个 `helm install` 会被中止
3. **不支持所有资源类型**：Hook 通常使用 Job 或 Pod，不支持 Deployment 等持续运行资源

## 实战：添加 Hook

### 第一步：查看 hook-demo-chart

```bash
tree hook-demo-chart/
```

### 第二步：安装并观察 pre-install Hook

```bash
# 安装 Chart
helm install hook-demo ./hook-demo-chart

# 观察：pre-install Job 会先执行
# 你会看到类似输出：
# NAME                                     READY   STATUS      RESTARTS
# hook-demo-pre-install                    0/1     Completed   0

# 查看 Hook Job 的日志
kubectl logs job/hook-demo-{{ .Release.Name }}-pre-install
# 注意：如果 hook-delete-policy 包含 hook-succeeded，Job 可能已被删除

# 查看 post-install Hook 的输出
helm status hook-demo
```

### 第三步：运行 helm test

```bash
# helm test 会执行所有类型为 "test" 的 Hook
helm test hook-demo

# 输出类似：
# NAME: hook-demo
# LAST DEPLOYED: ...
# Phase: Succeeded
```

`helm test` 做了什么：
1. 查找 Chart 中所有 `helm.sh/hook: test` 的模板
2. 渲染并创建这些资源（通常是 Pod 或 Job）
3. 等待它们执行完成
4. 报告成功/失败
5. 根据 `hook-delete-policy` 清理

### 第四步：升级并观察 pre-upgrade Hook

```bash
# 修改 values 后升级
helm upgrade hook-demo ./hook-demo-chart --set replicaCount=2

# 观察 pre-upgrade Hook 执行
kubectl get jobs
```

### 第五步：卸载并观察 pre-delete Hook

```bash
# 卸载
helm uninstall hook-demo

# pre-delete Hook 会在资源删除前执行
# 查看是否执行了清理操作
```

### 第六步：调试 Hook

```bash
# 如果 Hook 失败了，可以这样排查：

# 1. 查看 Hook Job 的状态
kubectl get jobs

# 2. 查看 Job 的 Pod 日志
kubectl logs job/<hook-job-name>

# 3. 查看 Events
kubectl describe job <hook-job-name>

# 4. 用 --dry-run 查看 Hook 渲染结果
helm install hook-demo ./hook-demo-chart --dry-run --debug
```

## Hook 的常见使用模式

### 数据库迁移（pre-upgrade）

```yaml
annotations:
  "helm.sh/hook": pre-upgrade
  "helm.sh/hook-weight": "-5"
  "helm.sh/hook-delete-policy": hook-succeeded
```

### 健康检查（test）

```yaml
annotations:
  "helm.sh/hook": test
  "helm.sh/hook-delete-policy": hook-succeeded
```

> **CI/CD 集成**：在流水线中加入 `helm test` 步骤，可以在部署后自动验证服务是否正常，失败则自动回滚。

## 思考题

1. 如果 `pre-install` Hook 执行失败，已经创建的普通模板资源会怎样？Helm 如何保证一致性？
2. `helm.sh/hook-delete-policy` 不设置任何值时的默认行为是什么？这会导致什么潜在问题？
3. 为什么 Hook 通常使用 Job 而不是 Deployment？如果用 Deployment 做 Hook 会出现什么问题？
4. 如何在 CI/CD 流水线中利用 `helm test` 实现自动化的部署验证？请描述一个完整的流程。

---

[下一节：05-Chart Registry 仓库与发布 →](../05-chart-registry/README.md)
