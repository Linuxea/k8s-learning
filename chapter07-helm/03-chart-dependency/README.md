# 07-03 Chart 依赖管理

## 为什么需要依赖管理？

假设你正在部署一个 Web 应用，它需要一个 Redis 做缓存、一个 PostgreSQL 做持久化存储。如果没有依赖管理：

1. **重复劳动**：你需要为每个应用手写 Redis、PostgreSQL 的 Deployment、Service、ConfigMap……
2. **版本混乱**：不同团队各自维护 Redis 模板，版本不统一
3. **升级困难**：Redis 镜像升级了，要改多少个应用的模板？

**Helm 的依赖机制解决了这个问题**：把 Redis、PostgreSQL 各自封装成独立 Chart，你的应用 Chart 只需声明依赖关系，Helm 自动管理。

这和编程语言中的包管理器（npm、pip、Maven）是一个思路。

## Chart.yaml 的 dependencies 字段

```yaml
# Chart.yaml
dependencies:
  - name: redis
    version: "18.0.1"          # 依赖 Chart 的版本（SemVer 范围）
    repository: "https://charts.bitnami.com/bitnami"
    # Chart 仓库地址
    condition: redis.enabled
    # 可选：当 values.yaml 中 redis.enabled 为 true 时才安装
    tags:
      - cache
      - backend
    # 可选：通过 tags 批量启用/禁用一组依赖
    alias: my-redis
    # 可选：给依赖起别名，同一个 Chart 可以安装多次（不同别名）
```

### 依赖字段说明

| 字段 | 必须 | 说明 |
|------|------|------|
| `name` | 是 | 依赖 Chart 的名称（必须和仓库中的 Chart 名一致） |
| `version` | 是 | SemVer 版本范围（如 `"^1.2.0"`、`">=2.0.0"`） |
| `repository` | 是 | Chart 仓库 URL（必须先 `helm repo add`） |
| `condition` | 否 | 对应 values.yaml 中的布尔字段，控制是否启用 |
| `tags` | 否 | 标签列表，通过 `--set tags.cache=true` 批量控制 |
| `alias` | 否 | 别名，同一 Chart 多实例时区分 |
| `import-values` | 否 | 从子 Chart 导入值到父 Chart |

## helm dependency 命令

| 命令 | 作用 |
|------|------|
| `helm dependency update` | 下载依赖到 `charts/` 目录（同时更新锁文件） |
| `helm dependency build` | 只按 `Chart.lock` 下载（不更新版本） |
| `helm dependency list` | 查看当前 Chart 的依赖状态 |

### charts/ 目录

执行 `helm dependency update` 后，会在 Chart 根目录生成：

```
webapp/
├── Chart.yaml            # 声明了 dependencies
├── Chart.lock            # 锁定依赖的精确版本（类似 package-lock.json）
├── charts/               # 下载的依赖 Chart 存放目录
│   └── redis-18.0.1.tgz  # 打包的依赖 Chart
└── templates/
    └── deployment.yaml
```

> **`Chart.lock` 的作用**：和 `package-lock.json` 类似，锁定依赖的精确版本号和 SHA256 校验和。`helm dependency build` 只按 lock 文件下载，确保团队成员使用完全一致的依赖版本。

## Condition 与 Tags：选择性安装

### Condition（条件安装）

```yaml
# Chart.yaml
dependencies:
  - name: redis
    version: "18.0.1"
    repository: "https://charts.bitnami.com/bitnami"
    condition: redis.enabled
    # 当 values.yaml 中 redis.enabled 为 true 时才安装
```

```yaml
# values.yaml
redis:
  enabled: true    # 设为 false 则跳过 Redis 安装
```

### Tags（标签分组）

```yaml
# Chart.yaml
dependencies:
  - name: redis
    version: "18.0.1"
    repository: "https://charts.bitnami.com/bitnami"
    tags:
      - cache
  - name: postgresql
    version: "14.0.0"
    repository: "https://charts.bitnami.com/bitnami"
    tags:
      - database
```

```bash
# 只安装带 cache 标签的依赖
helm install my-app ./webapp --set tags.cache=true --set tags.database=false
```

> **优先级**：`condition` > `tags`。如果 condition 为 false，即使 tag 匹配也不会安装。

## 子 Chart 的值覆盖

父 Chart 可以通过 `values.yaml` 覆盖子 Chart 的值。规则：

```yaml
# 父 Chart 的 values.yaml
redis:
  # 以子 Chart 名为 key（或 alias），下面的值会覆盖子 Chart 的 values.yaml
  enabled: true
  architecture: standalone
  auth:
    enabled: false
  master:
    persistence:
      enabled: false
```

> **覆盖规则**：父 Chart 的 `values.yaml` 中以子 Chart 名（或 alias）为顶级 key 的值，会**合并覆盖**子 Chart 的 `values.yaml`。但 `--set` 的优先级最高。

### 全局值（Global Values）

```yaml
# values.yaml
global:
  imageRegistry: my-registry.example.com
  # global 值对所有 Chart（父 + 子）都可见
  # 子 Chart 模板中通过 {{ .Values.global.imageRegistry }} 访问
```

> **重要**：`global` 是保留 key，Helm 会自动将其传递给所有子 Chart。自定义 key 不会自动传递。

## 实战：创建带 Redis 依赖的 Web 应用

> **注意**：本节示例使用本地子 Chart 方式（而非从远程仓库下载），因为远程仓库的 Redis Chart 依赖太多，不适合教学。实际项目中建议使用成熟的社区 Chart。

### 第一步：查看 webapp Chart 结构

```bash
tree webapp/
```

### 第二步：安装

```bash
# 先查看渲染结果
helm template my-webapp ./webapp

# 安装（包含 Redis 依赖）
helm install my-webapp ./webapp

# 查看创建的资源
kubectl get all -l app.kubernetes.io/instance=my-webapp
```

### 第三步：安装但跳过 Redis

```bash
# 通过 condition 禁用 Redis
helm install my-webapp-no-redis ./webapp \
  --set redis.enabled=false

# 确认没有 Redis Pod
kubectl get pods -l app.kubernetes.io/instance=my-webapp-no-redis
```

### 第四步：覆盖子 Chart 的值

```bash
# 自定义 Redis 配置
helm upgrade my-webapp ./webapp \
  --set redis.auth.enabled=false \
  --set redis.master.persistence.enabled=false
```

## 依赖管理的最佳实践

1. **用 `condition` 控制可选依赖**：数据库、缓存等不是所有环境都需要
2. **锁定版本**：提交 `Chart.lock` 到版本控制，确保团队使用一致的依赖
3. **最小化依赖**：只引入真正需要的 Chart，避免"依赖爆炸"
4. **使用社区 Chart**：Bitnami 等仓库的 Chart 经过充分测试，比自己写更可靠
5. **注意命名冲突**：多个子 Chart 可能创建同名资源，使用 `fullnameOverride` 区分

## 思考题

1. `helm dependency update` 和 `helm dependency build` 有什么区别？在 CI/CD 流水线中应该用哪个？
2. 如果两个子 Chart 都需要访问同一个全局配置（比如镜像仓库地址），应该怎么传递？子 Chart 之间能否直接共享值？
3. `condition: redis.enabled` 和 `tags: [cache]` 可以同时使用吗？如果 condition 为 false 但 tags 匹配，结果是什么？
4. 为什么建议将 `Chart.lock` 提交到版本控制？如果不提交会有什么问题？

---

[下一节：04-Chart Hook 生命周期钩子 →](../04-chart-hook/README.md)
