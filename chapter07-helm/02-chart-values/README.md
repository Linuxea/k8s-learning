# 07-02 Chart Values 与模板化

## 为什么需要模板化？

上一节我们创建了第一个 Chart，但模板只是简单地引用了 `values.yaml` 中的值。实际上 Helm 的 Go template 引擎非常强大——**它让一个 Chart 适配无数种部署场景**：

- 开发环境：1 副本、最低资源
- 测试环境：2 副本、中等资源
- 生产环境：3+ 副本、高配资源 + 亲和性 + 容忍度

所有这些只需不同的 `values.yaml` 覆盖，**Chart 代码零修改**。

## values.yaml：Chart 的灵魂

`values.yaml` 定义了 Chart 的所有可配置参数。模板通过 `{{ .Values.xxx }}` 引用它们：

```yaml
# values.yaml
replicaCount: 1
image:
  repository: nginx
  tag: ""
```

在模板中引用：

```yaml
# templates/deployment.yaml
replicas: {{ .Values.replicaCount }}
image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
```

### 覆盖 values 的三种方式（优先级从低到高）

| 方式 | 命令 | 说明 |
|------|------|------|
| Chart 默认值 | （values.yaml 本身） | 最低优先级 |
| 自定义 values 文件 | `helm install -f custom.yaml` | 覆盖默认值 |
| `--set` 参数 | `helm install --set replicaCount=3` | 最高优先级 |

> **优先级**：`--set` > `-f custom.yaml` > `values.yaml`。多个 `-f` 文件时，后面的覆盖前面的。

## 内置对象（Built-in Objects）

Helm 模板中可以直接访问以下内置对象，无需在 values.yaml 中定义：

| 对象 | 说明 | 常用字段 |
|------|------|---------|
| `{{ .Release.Name }}` | Release 名称 | Name, Namespace, IsUpgrade, IsInstall |
| `{{ .Chart.Name }}` | Chart.yaml 中的元数据 | Name, Version, AppVersion, Description |
| `{{ .Values }}` | values.yaml 中的所有值 | 按层级访问 .Values.xxx |
| `{{ .Files }}` | 访问 Chart 中的非模板文件 | Get, Glob, Lines |
| `{{ .Capabilities }}` | 集群的能力信息 | APIVersions.Has, KubeVersion |
| `{{ .Template }}` | 当前模板的信息 | Name, BasePath |

### 内置对象使用示例

```yaml
# 引用 Release 信息
namespace: {{ .Release.Namespace }}

# 条件判断：是全新安装还是升级
{{- if .Release.IsInstall }}
# 首次安装时执行的特殊逻辑
{{- end }}

# 检查集群是否支持某个 API 版本
{{- if .Capabilities.APIVersions.Has "networking.k8s.io/v1/Ingress" }}
# 集群支持 Ingress v1 时才渲染
{{- end }}
```

## 管道与函数（Pipeline & Functions）

Go template 的管道（`|`）将左侧的值传给右侧的函数处理，类似 Linux shell 的管道。

### 常用函数

| 函数 | 作用 | 示例 |
|------|------|------|
| `default` | 提供默认值 | `{{ .Values.tag \| default "latest" }}` |
| `quote` | 给字符串加双引号 | `{{ .Values.name \| quote }}` → `"nginx"` |
| `upper` | 转大写 | `{{ "hello" \| upper }}` → `HELLO` |
| `lower` | 转小写 | `{{ "HELLO" \| lower }}` → `hello` |
| `repeat` | 重复 N 次 | `{{ "ha" \| repeat 3 }}` → `hahaha` |
| `indent` | 缩进 N 个空格（不换行） | `{{ toYaml .Values \| indent 4 }}` |
| `nindent` | 缩进 N 个空格（先换行） | `{{ toYaml .Values \| nindent 4 }}` |
| `toYaml` | 转成 YAML 字符串 | 处理 map/list 类型时必需 |
| `trunc` | 截断到 N 字符 | `{{ .Release.Name \| trunc 63 }}` |
| `trimSuffix` | 去掉后缀 | `{{ "v1.0-" \| trimSuffix "-" }}` → `v1.0` |
| `replace` | 替换字符串 | `{{ "1.0+build" \| replace "+" "_" }}` → `1.0_build` |
| `b64enc` / `b64dec` | Base64 编码/解码 | 用于 Secret 的值 |
| `lookup` | 查询集群中已有资源 | `lookup "v1" "ConfigMap" "default" "my-cm"` |

> **`indent` vs `nindent`**：这是最容易混淆的一对。`indent 4` 在每行前加 4 空格但**不换行**；`nindent 4` 先**换行**再加缩进。在 YAML 中通常需要 `nindent` 来保证格式正确。

### 管道链式调用

```yaml
# 多个函数可以链式调用
image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
# 先取 .Values.image.tag，如果为空则 fallback 到 .Chart.AppVersion

# 复杂管道
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
# 输出: app.kubernetes.io/version: "1.27.0"
```

## 流程控制

### if / else：条件渲染

```yaml
{{- if eq .Values.service.type "ClusterIP" }}
# 只有 service.type 为 ClusterIP 时才渲染这段
clusterIP: {{ .Values.service.clusterIP }}
{{- else if eq .Values.service.type "NodePort" }}
nodePort: {{ .Values.service.nodePort }}
{{- else }}
type: LoadBalancer
{{- end }}
```

**注意事项**：Go template 中的 `if` 判断"假值"包括：
- 布尔 `false`
- 数字 `0`
- 空字符串 `""`
- 空对象 `nil`
- 空集合（空 map、空 slice、空数组）

> **陷阱**：`if .Values.affinity` 当 affinity 为 `{}` 时返回 `false`（空 map），所以 `with` 和 `if` 经常配合使用来跳过空配置。

### with：修改作用域

```yaml
{{- with .Values.resources }}
resources:
  limits:
    cpu: {{ .limits.cpu }}
    memory: {{ .limits.memory }}
  requests:
    cpu: {{ .requests.cpu }}
    memory: {{ .requests.memory }}
{{- end }}
```

`with` 将 `.`（点）重新绑定为 `with` 的值，这样就不需要反复写 `.Values.resources`。

> **注意**：在 `with` 块内部，`.` 被覆盖了，无法直接访问 `.Values` 或 `.Release`。如果需要，可以提前用 `$` 变量保存：`{{ $values := .Values }}`，然后在 with 内用 `$values`。

### range：遍历列表/字典

**遍历列表**：

```yaml
# 假设 values.yaml 中:
# extraEnv:
#   - name: FOO
#     value: bar
#   - name: BAZ
#     value: qux
env:
{{- range .Values.extraEnv }}
  - name: {{ .name }}
    value: {{ .value | quote }}
{{- end }}
```

**遍历字典**：

```yaml
# 假设 values.yaml 中:
# labels:
#   team: platform
#   env: production
{{- range $key, $value := .Values.labels }}
{{ $key }}: {{ $value | quote }}
{{- end }}
```

## 实战：创建参数化 Chart

### 第一步：查看示例 Chart

本节提供了 `config-demo-chart/`，它是一个高度参数化的 Chart，演示了所有模板特性：

```bash
# 查看目录结构
tree config-demo-chart/
```

### 第二步：使用默认值安装

```bash
# 先用 --dry-run 检查渲染结果
helm template my-app ./config-demo-chart

# 正式安装
helm install my-app ./config-demo-chart

# 查看 ConfigMap 的内容
kubectl get configmap -l app.kubernetes.io/instance=my-app -o yaml
```

### 第三步：使用自定义 values 安装

```bash
# 使用 custom-values.yaml 覆盖默认配置
helm install my-app-prod ./config-demo-chart -f custom-values.yaml

# 对比两个 Release 的差异
helm get values my-app          # 默认值
helm get values my-app-prod     # 自定义值

# 查看 Pod 副本数
kubectl get deployment -l app.kubernetes.io/instance=my-app-prod
```

### 第四步：使用 --set 覆盖

```bash
# 单个值覆盖
helm upgrade my-app ./config-demo-chart --set replicaCount=5

# 多个值覆盖（用逗号分隔）
helm upgrade my-app ./config-demo-chart \
  --set replicaCount=3 \
  --set image.tag=alpine \
  --set resources.limits.cpu=200m

# --set 的特殊语法
# 设置列表元素: --set extraEnv[0].name=FOO --set extraEnv[0].value=bar
```

### 第五步：观察差异

```bash
# 查看渲染差异（对比两个 release 的 values）
diff <(helm get values my-app) <(helm get values my-app-prod)

# 查看 template 渲染差异
diff <(helm template my-app ./config-demo-chart) \
     <(helm template my-app ./config-demo-chart -f custom-values.yaml)
```

## 模板调试技巧

```bash
# 1. helm template：本地渲染，不连接集群
helm template my-app ./config-demo-chart

# 2. helm template --show-only：只看某个模板的渲染结果
helm template my-app ./config-demo-chart --show-only templates/configmap.yaml

# 3. helm install --dry-run --debug：连接集群渲染（可以获取 .Capabilities 等集群信息）
helm install my-app ./config-demo-chart --dry-run --debug

# 4. helm get manifest：查看已安装 Release 的实际渲染结果
helm get manifest my-app
```

## 思考题

1. 如果在 `values.yaml` 中定义了一个嵌套结构 `image: { repository: nginx, tag: "" }`，用 `--set image.tag=alpine` 覆盖后，`image.repository` 的值会丢失吗？为什么？
2. `nindent` 和 `indent` 的区别在什么场景下最关键？（提示：YAML 的 `|` 块标量和 map 的缩进）
3. 在 `with` 块内如何访问 `.Release.Name`？（提示：预定义变量 `$`）
4. 如果 `values.yaml` 中 `affinity: {}`，模板中 `{{- if .Values.affinity }}` 的结果是什么？如何正确判断用户是否设置了亲和性？

---

[下一节：03-Chart Dependency 依赖管理 →](../03-chart-dependency/README.md)
