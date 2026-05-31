# 01 - CRD：自定义资源定义

## 为什么需要 CRD

Kubernetes 内置了很多资源类型：Pod、Service、Deployment、ConfigMap……这些资源覆盖了大部分通用场景。但现实世界中的应用千差万别：

- 一个数据库运维团队，想用 K8s 管理 MySQL 主从集群——他们需要一种叫 `MySQLCluster` 的资源
- 一个机器学习平台，想管理训练任务——需要 `TrainingJob` 资源
- 一个 CDN 服务商，想管理边缘节点配置——需要 `EdgeConfig` 资源

如果每种需求都要改 K8s 源码、编译、部署，那 K8s 根本无法扩展。**CRD（CustomResourceDefinition）就是为了解决这个问题而设计的**——它让你可以在不修改 K8s 源码的情况下，定义自己的资源类型。

## CRD 和 CR 的关系

理解 CRD，关键是区分两个概念：

| 概念 | 全称 | 类比 |
|------|------|------|
| **CRD** | CustomResourceDefinition | 数据库的表结构定义（`CREATE TABLE ...`） |
| **CR** | CustomResource | 表中的一行数据（`INSERT INTO ...`） |

举个例子：

- CRD 说："有一种资源叫 Website，它有 image、replicas、host 三个字段"
- CR 说："创建一个 Website，image=nginx:1.27，replicas=3，host=blog.example.com"

CRD 定义**规则**，CR 是**实例**。

## CRD 工作原理

CRD 的运行机制分为三步：

```
1. 定义 Schema
   用户提交 CRD YAML → API Server 注册新的 API 路径

2. API Server 自动服务
   K8s API Server 自动提供 CRUD 接口：
   GET    /apis/example.com/v1alpha1/namespaces/default/websites
   POST   /apis/example.com/v1alpha1/namespaces/default/websites
   PUT    /apis/example.com/v1alpha1/namespaces/default/websites/my-blog
   DELETE /apis/example.com/v1alpha1/namespaces/default/websites/my-blog

3. 创建实例
   用户提交 CR YAML → API Server 校验 schema → 存入 etcd
   kubectl get websites 就像 kubectl get pods 一样工作
```

> 关键点：CRD 注册后，K8s API Server **自动**为你提供完整的 CRUD API。你不需要写任何后端代码。但 CRD 本身只是"数据定义"，不会帮你创建 Pod 或 Deployment——那需要 Operator/Controller（下一节会讲）。

## Schema 校验

CRD 支持 OpenAPI v3 schema 校验。这意味着你可以在 CRD 中定义字段类型、范围、正则约束，API Server 会在创建/更新 CR 时自动校验：

| 约束类型 | 示例 | 作用 |
|----------|------|------|
| `type` | `type: integer` | 字段必须是整数 |
| `minimum/maximum` | `minimum: 1, maximum: 10` | 限制数值范围 |
| `pattern` | `pattern: "^[a-z0-9.-]+$"` | 正则校验字符串格式 |
| `required` | `required: [image, replicas]` | 必填字段 |
| `enum` | `enum: [small, medium, large]` | 枚举值 |

如果不通过校验，kubectl 会直接报错，不会创建资源。

## Step by Step 操作

### Step 1: 确认集群状态

```bash
# 确认 kind 集群运行中
kubectl get nodes

# 期望输出：
# NAME                       STATUS   ROLES           AGE   VERSION
# k8s-learning-control-plane Ready    control-plane   ...
# k8s-learning-worker        Ready    <none>          ...
# k8s-learning-worker2       Ready    <none>          ...
```

### Step 2: 查看内置资源类型

```bash
# 查看所有 K8s 内置资源类型
kubectl api-resources

# 你会看到一长串列表：pods, services, deployments, configmaps...
# 注意 SHORTNAMES 列，比如 po=pods, svc=services, deploy=deployments
```

### Step 3: 创建 CRD

```bash
# 提交 CRD 定义，注册 "Website" 资源类型
kubectl apply -f website-crd.yaml

# 输出：
# customresourcedefinition.apiextensions.k8s.io/websites.example.com created
```

### Step 4: 验证 CRD 已注册

```bash
# 查看 CRD 列表
kubectl get crd

# 输出类似：
# NAME                    CREATED AT
# websites.example.com    2025-01-01T00:00:00Z

# 查看 CRD 详情
kubectl describe crd websites.example.com

# 确认 API 已注册
kubectl api-resources | grep website

# 输出：
# websites   web   example.com/v1alpha1   true   Website
```

现在 K8s 已经认识 `Website` 这种资源了。

### Step 5: 创建 Website 实例（CR）

```bash
kubectl apply -f website-cr.yaml

# 输出：
# website.example.com/my-blog created
```

### Step 6: 查看 CR

```bash
# 基本查看
kubectl get websites

# 输出（additionalPrinterColumns 控制的列）：
# NAME      HOST               REPLICAS   IMAGE        AGE
# my-blog   blog.example.com   3          nginx:1.27   10s

# 使用短名称
kubectl get web

# 查看详情
kubectl describe website my-blog

# 导出 YAML
kubectl get website my-blog -o yaml
```

### Step 7: 测试 Schema 校验

创建一个不合法的 CR，看看校验是否生效：

```bash
# replicas 设为 0（违反 minimum: 1 约束）
cat <<EOF | kubectl apply -f -
apiVersion: example.com/v1alpha1
kind: Website
metadata:
  name: bad-website
spec:
  image: nginx:1.27
  replicas: 0
  host: test.example.com
EOF

# 输出错误：
# The Website "bad-website" is invalid: spec.replicas: Invalid value: 0: spec.replicas in body should be greater than or equal to 1
```

这就是 CRD schema 校验的威力——**在入口处就拦截了无效配置**。

### Step 8: 更新和删除

```bash
# 更新：修改副本数
kubectl patch website my-blog -p '{"spec":{"replicas":5}}' --type=merge

# 验证更新
kubectl get web my-blog

# 删除 CR
kubectl delete website my-blog

# 删除 CRD（会同时删除所有该类型的 CR）
kubectl delete crd websites.example.com
```

> 删除 CRD 前请确认没有重要的 CR 实例。删除 CRD 会级联删除所有关联的 CR。

## CRD YAML 结构详解

回顾 `website-crd.yaml` 中的关键字段：

| 字段 | 含义 |
|------|------|
| `spec.group` | API 组名，用于 API 路径。推荐使用你拥有的域名反写，如 `example.com` |
| `spec.versions` | 支持多版本共存，方便 API 演进 |
| `spec.versions[].served` | 该版本是否对外提供 API |
| `spec.versions[].storage` | etcd 中实际存储的版本（只能有一个为 true） |
| `spec.versions[].schema` | OpenAPI v3 校验规则 |
| `spec.scope` | `Namespaced`（命名空间级）或 `Cluster`（集群级） |
| `spec.names.plural` | 复数名，用于 API URL 路径 |
| `spec.names.singular` | 单数名，用于 CLI |
| `spec.names.shortNames` | 缩写，如 `kubectl get web` |
| `spec.names.kind` | YAML 中 `kind` 的值 |
| `spec.versions[].additionalPrinterColumns` | `kubectl get` 时显示的自定义列 |

## CRD 的局限性

CRD 只定义了"数据长什么样"，它**不会**帮你：

- 创建 Pod 或 Deployment 来运行你的 Website
- 监控 Website 的实际状态
- 处理故障恢复、滚动更新等运维逻辑

这些工作需要 **Controller/Operator** 来完成——这就是下一节的内容。

## 思考题

1. 如果 CRD 的 `scope: Cluster`，创建 CR 时还能指定 `namespace` 吗？为什么？
2. CRD 的 `versions` 列表中可以有多个 `served: true` 的版本吗？这有什么用？
3. 如果删除一个 CRD，对应的 CR 会怎样？这种设计有什么好处和风险？
4. CRD 只定义了数据 schema，没有行为逻辑。为什么 K8s 要把"数据定义"和"行为逻辑"分开设计？

---

下一个 → [02 - Operator 模式](../02-operator-pattern/)
