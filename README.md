# Kubernetes Learning Path

从零开始学习 Kubernetes，按章节由浅入深，每节包含可运行的示例和说明。

## 目录结构

| 章节 | 主题 | 内容概要 |
|------|------|---------|
| 01 | Pod 基础 | 第一个 Pod、多容器 Pod、生命周期、健康检查、资源限制 |
| 02 | 工作负载 | Deployment、ReplicaSet、StatefulSet、DaemonSet、Job/CronJob |
| 03 | 服务与网络 | ClusterIP、NodePort、LoadBalancer、Headless Service、Ingress |
| 04 | 配置与存储 | ConfigMap、Secret、Volume、PV/PVC、StorageClass |
| 05 | 调度 | nodeSelector、亲和性、污点容忍、拓扑分布、自定义调度器 |
| 06 | 安全 | RBAC、ServiceAccount、NetworkPolicy、安全上下文、PSA/PSP |
| 07 | Helm | 第一个 Chart、Values 模板、依赖管理、Hook、Chart 仓库 |
| 08 | 可观测性 | 日志、Prometheus 监控、告警、链路追踪、Grafana 仪表盘 |
| 09 | 高级模式 | CRD、Operator 模式、Mutating/Validating Admission、Gateway API |
| 10 | CI/CD 与 GitOps | CI 流水线、ArgoCD、Flux、渐进式发布、灾备恢复 |

## 约定

- 每节目录包含 `README.md`（说明）和 `.yaml` 示例文件
- 示例可直接 `kubectl apply -f` 运行（需有 K8s 集群）
- 建议使用 [kind](https://kind.sigs.k8s.io/) 或 [minikube](https://minikube.sigs.k8s.io/) 作为本地学习集群
