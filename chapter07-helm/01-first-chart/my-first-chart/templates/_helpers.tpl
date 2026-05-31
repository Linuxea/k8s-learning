{{/*
--------------------------
命名模板（Named Templates）
以 _ 开头的模板文件不会被渲染成 K8s 资源，
仅用于定义可复用的模板片段（define 块）
--------------------------
*/}}

{{/*
生成完整的 Release 名称
如果 fullnameOverride 被设置了，就用它；
否则用 release name + chart name（截断到 63 字符，K8s 名称长度限制）
*/}}
{{- define "my-first-chart.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name }}
{{- end }}
{{- end }}

{{/*
生成通用标签（Labels）
这些标签遵循 K8s 推荐的标签规范：
  app.kubernetes.io/name       - 应用名
  app.kubernetes.io/instance   - Release 实例名
  app.kubernetes.io/version    - 应用版本
  app.kubernetes.io/managed-by - 管理工具（helm）
*/}}
{{- define "my-first-chart.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "my-first-chart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
生成 Selector 标签
这些标签用于 Service/Deployment 的 selector 匹配，
一旦部署后就不应该修改（会导致 selector 不匹配）
*/}}
{{- define "my-first-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
