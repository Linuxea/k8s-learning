# 10.4 渐进式交付：安全地推出变更

## 什么是渐进式交付？

渐进式交付（Progressive Delivery）是持续交付的演进——不是一次性将新版本部署给所有用户，而是 **逐步扩大新版本的曝光范围**，在过程中持续验证，发现问题立即回滚。

```
传统部署：所有用户 ──────────────────────────────── 全部切换到新版本
                  │（如果有问题，所有用户都受影响）

渐进式交付：所有用户 ──▶ 5% 用户 ──▶ 25% 用户 ──▶ 50% 用户 ──▶ 100%
                    │         │           │           │
                   验证       验证         验证       验证
                    │         │           │
                  回滚?     回滚?       回滚?
```

> **为什么需要渐进式交付？**
>
> 即使有完善的 CI 流水线（单元测试、集成测试），仍无法覆盖所有生产环境中的问题。渐进式交付将"生产环境测试"融入到发布过程中，用真实的流量和指标来验证新版本。

## 部署策略对比

### 1. 滚动更新（Rolling Update）

Kubernetes Deployment 的默认策略：

```
v1 Pod: [A] [B] [C]     副本数: 3
                │
                ▼ 逐步替换
v1 Pod: [A] [B]         v2 Pod: [D]     期间总共有 3+ 个 Pod
v1 Pod: [A]             v2 Pod: [D] [E]  旧 Pod 逐步被新 Pod 替换
v2 Pod: [D] [E] [F]    最终全部替换完成
```

| 优点 | 缺点 |
|------|------|
| 简单、K8s 内建 | 无法精确控制流量比例 |
| 无需额外工具 | 回滚较慢（需要重新滚动） |
| 零停机 | 无法做金丝雀测试 |

### 2. 金丝雀发布（Canary）

先让一小部分流量流向新版本，逐步增加：

```
阶段 1: v1 → 95% 流量,  v2 → 5% 流量    (观察 5 分钟)
阶段 2: v1 → 80% 流量,  v2 → 20% 流量   (观察 5 分钟)
阶段 3: v1 → 50% 流量,  v2 → 50% 流量   (观察 5 分钟)
阶段 4: v2 → 100% 流量                   (完成发布)
```

如果任何阶段发现问题，立即将 100% 流量切回 v1。

| 优点 | 缺点 |
|------|------|
| 精确控制曝光范围 | 需要流量分割能力（Service Mesh 或特殊网络配置） |
| 快速回滚 | 实现较复杂 |
| 真实流量验证 | 需要额外的工具 |

### 3. 蓝绿部署（Blue/Green）

同时运行两套完全相同的环境，切换流量：

```
初始状态:
  Blue 环境 (v1): [A] [B] [C]  ◀─── 100% 流量
  Green 环境 (v2): (不存在)

部署新版本:
  Blue 环境 (v1): [A] [B] [C]  ◀─── 100% 流量
  Green 环境 (v2): [D] [E] [F]  (待切换)

切换流量:
  Blue 环境 (v1): [A] [B] [C]
  Green 环境 (v2): [D] [E] [F]  ◀─── 100% 流量

确认无误后删除旧环境:
  Green 环境 (v2): [D] [E] [F]  ◀─── 100% 流量
```

| 优点 | 缺点 |
|------|------|
| 切换瞬间完成 | 需要双倍资源 |
| 回滚极快（切回旧环境） | 资源浪费 |
| 完整环境测试 | 数据库迁移需要特别处理 |

### 4. A/B 测试

不是按比例分配流量，而是按用户特征分配：

```
用户群体 A（30 岁以下）→ v2 版本（新 UI）
用户群体 B（30 岁以上）→ v1 版本（旧 UI）

目的不是"安全发布"，而是"对比效果"
通过转化率、点击率等指标决定哪个版本更好
```

### 策略选择指南

| 场景 | 推荐策略 |
|------|----------|
| 简单应用、低风险变更 | 滚动更新 |
| 高风险变更、需要验证 | 金丝雀 |
| 关键业务、要求零回滚时间 | 蓝绿 |
| 商业决策、用户行为研究 | A/B 测试 |

## 工具生态

| 工具 | 策略 | 流量分割方式 | 集成 |
|------|------|-------------|------|
| **Argo Rollouts** | 金丝雀、蓝绿 | Nginx/ALB/SM | ArgoCD |
| **Flagger** | 金丝雀、A/B、蓝绿 | Istio/Linkerd/SM | Flux |
| **Istio** | 流量分割（底层） | Service Mesh | 通用 |

## Argo Rollouts 详解

Argo Rollouts 是 ArgoCD 生态的渐进式交付工具，使用 `Rollout` CRD 替代标准 `Deployment`：

### Rollout vs Deployment

```
# 标准 Deployment：Kubernetes 原生的滚动更新
apiVersion: apps/v1
kind: Deployment
# ... 只支持 RollingUpdate 和 Recreate 策略

# Argo Rollouts Rollout：增强版的 Deployment
apiVersion: argoproj.io/v1alpha1
kind: Rollout
# ... 支持金丝雀、蓝绿策略
# ... 支持自动分析和回滚
```

| Rollout 优势 | 说明 |
|-------------|------|
| 精确流量控制 | 20% → 40% → 60% → 100% |
| 自动分析 | 基于 Prometheus 等指标自动判断健康状态 |
| 自动回滚 | 分析失败时自动回滚到旧版本 |
| 暂停/继续 | 在任意步骤暂停，手动确认后继续 |
| 兼容性 | 与 Service、HPA 等标准 K8s 资源兼容 |

### 金丝雀策略工作流程

```
1. 创建 Rollout（spec.template 指向新版本镜像）
2. Argo Rollouts 创建新 ReplicaSet（金丝雀）
3. 根据策略逐步增加金丝雀流量：
   ├── 20% 流量 → 暂停 → 等待 AnalysisTemplate 结果
   │   ├── 分析通过 → 继续
   │   └── 分析失败 → 自动回滚
   ├── 40% 流量 → 暂停 → 等待分析
   │   ├── 分析通过 → 继续
   │   └── 分析失败 → 自动回滚
   └── 100% 流量 → 金丝雀成为新稳定版本
4. 删除旧 ReplicaSet
```

## 动手实践：使用 Argo Rollouts

### 第一步：安装 Argo Rollouts

```bash
# 创建命名空间
kubectl create namespace argo-rollouts

# 安装 Argo Rollouts 控制器
kubectl apply -n argo-rollouts -f https://raw.githubusercontent.com/argoproj/argo-rollouts/stable/install/install.yaml

# 等待控制器就绪
kubectl get pods -n argo-rollouts -w
# 预期输出：
# NAME                             READY   STATUS
# argo-rollouts-xxxxxxxxxx-xxxxx   1/1     Running

# 安装 kubectl argo-rollouts 插件
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x ./kubectl-argo-rollouts-linux-amd64
sudo mv ./kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
```

### 第二步：创建 Rollout

参见 `rollout.yaml`。这是一个使用金丝雀策略的 Rollout：

```bash
# 创建 Rollout 和 Service
kubectl apply -f rollout.yaml
kubectl apply -f rollout-service.yaml

# 查看 Rollout 状态
kubectl argo rollouts get rollout myapp-rollout

# 预期输出类似：
# Name:            myapp-rollout
# Namespace:       default
# Status:          ✔ Healthy
# Strategy:        Canary
#  Step:          5/5
#  SetWeight:     100
#  ActualWeight:  100
# Images:          nginx:1.25-alpine (stable)
```

### 第三步：触发更新

```bash
# 修改镜像版本，触发金丝雀更新
kubectl argo rollouts set image myapp-rollout myapp=nginx:1.26-alpine

# 观察金丝雀更新过程
kubectl argo rollouts get rollout myapp-rollout --watch

# 你会看到以下过程：
# Step 1/5: SetWeight 20% → 20% 流量到新版本
# Step 2/5: Pause 30s   → 等待 30 秒观察
# Step 3/5: SetWeight 40% → 40% 流量到新版本
# Step 4/5: Pause 30s   → 等待 30 秒观察
# Step 5/5: SetWeight 100% → 全部流量到新版本（升级完成）
```

### 第四步：手动控制金丝雀

```bash
# 暂停当前步骤（停止自动推进）
kubectl argo rollouts pause myapp-rollout

# 查看当前状态
kubectl argo rollouts get rollout myapp-rollout

# 手动推进到下一步（在有 pause 的步骤上需要手动 promote）
kubectl argo rollouts promote myapp-rollout

# 完全跳过所有剩余步骤，直接切换到 100%
kubectl argo rollouts promote myapp-rollout --full
```

### 第五步：中止和回滚

```bash
# 中止当前金丝雀更新，回滚到旧版本
kubectl argo rollouts abort myapp-rollout

# 查看回滚状态
kubectl argo rollouts get rollout myapp-rollout
# Status 应变为 Degraded，然后自动回滚到旧 ReplicaSet

# 查看历史版本
kubectl argo rollouts list rollouts
```

### 第六步：使用 AnalysisTemplate 自动分析

参见 `analysis-template.yaml`。这定义了在金丝雀过程中自动运行的指标检查：

```bash
# 创建 AnalysisTemplate
kubectl apply -f analysis-template.yaml

# 修改 Rollout，在步骤中引用 AnalysisTemplate
# （需要在 Rollout 的 steps 中添加 analysis 步骤）

# 当 AnalysisTemplate 检查失败时，Argo Rollouts 会自动中止金丝雀并回滚
```

## 金丝雀流量分割的底层原理

```
┌─────────────────────────────────────────┐
│            Service (selector: app=myapp) │
│                   │                      │
│          ┌────────┴────────┐            │
│          ▼                 ▼             │
│  ┌──────────────┐ ┌──────────────┐      │
│  │ Stable RS    │ │ Canary RS    │      │
│  │ v1 (3 Pods)  │ │ v2 (1 Pod)   │      │
│  │ 80% 流量     │ │ 20% 流量     │      │
│  └──────────────┘ └──────────────┘      │
│                                         │
│  流量比例 = Pod 数量比例                  │
│  20% 金丝雀 = 1 canary / (3 stable + 1)  │
└─────────────────────────────────────────┘

更精确的流量分割需要：
  - Nginx Ingress canary annotation
  - Service Mesh（Istio VirtualService）
  - ALB Ingress traffic splitting
```

> **为什么基础的金丝雀只用 Pod 比例？**
>
> 标准 Kubernetes Service 使用 round-robin 负载均衡，流量比例取决于 Pod 数量比例。如果 stable 有 4 个 Pod，canary 有 1 个 Pod，那么大约 20% 的流量会到 canary。这不够精确，但对大多数场景足够。如果需要精确到 1% 级别的流量控制，需要 Service Mesh 或特殊 Ingress。

## 思考题

1. 金丝雀发布和蓝绿部署的本质区别是什么？什么场景下蓝绿比金丝雀更合适？
2. AnalysisTemplate 检查 Prometheus 的错误率指标。如果 Prometheus 本身暂时不可用，Argo Rollouts 应该怎么处理？是继续推进还是回滚？
3. 如果金丝雀发布进行到 50% 时发现新版本有一个数据迁移 bug（不影响请求但会导致数据不一致），你应该如何处理？
4. Argo Rollouts 使用 Pod 数量比例来控制流量。如果 stable 有 2 个 Pod，canary 需要精确 10% 的流量，这在技术上如何实现？

---

**下一节：** [10.5 灾难恢复](../05-disaster-recovery/README.md)
