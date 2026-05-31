# 02 - Secret：管理敏感数据

## 为什么需要 Secret

上一节的 ConfigMap 适合存放普通配置，但有些数据不应该明文出现在 yaml 文件或容器环境变量中：

- 数据库密码
- API Token
- TLS 证书和私钥
- Docker 镜像仓库的登录凭证

Secret 和 ConfigMap 结构类似，但有几个关键区别：

| 特性 | ConfigMap | Secret |
|------|-----------|--------|
| 数据存储 | 明文 | Base64 编码 |
| 大小限制 | 1 MiB | 1 MiB |
| etcd 中的存储 | 明文 | Base64 编码（可配置加密） |
| 访问控制 | 普通资源 | 建议配合 RBAC 严格限制 |
| 类型约束 | 无 | 有多种预定义类型 |

## Secret 的类型

| 类型 | 用途 |
|------|------|
| `Opaque` | 通用类型，存放任意键值对（最常用） |
| `kubernetes.io/tls` | TLS 证书，用于 Ingress 等 |
| `kubernetes.io/basic-auth` | 基本认证的用户名密码 |
| `kubernetes.io/dockerconfigjson` | Docker 镜像仓库登录凭证 |
| `kubernetes.io/ssh-auth` | SSH 认证密钥 |
| `kubernetes.io/service-account-token` | ServiceAccount 令牌 |

## ⚠️ Base64 ≠ 加密

这是最常见的误解。Secret 的数据只是 base64 编码，**不是加密**。任何人都可以解码：

```bash
# 编码
echo -n 'my-super-password' | base64
# bXktc3VwZXItcGFzc3dvcmQ=

# 解码——就这么简单
echo 'bXktc3VwZXItcGFzc3dvcmQ=' | base64 -d
# my-super-password
```

那 Secret 还有什么意义？

1. **控制平面层面** — 可以通过 RBAC 控制谁能读取 Secret，而 ConfigMap 通常所有人可见
2. **etcd 加密** — 可以配置 etcd 在磁盘上加密存储 Secret 数据（EncryptionConfiguration）
3. **审计追踪** — 对 Secret 的访问会被记录在审计日志中
4. **传输安全** — kubelet 通过 TLS 获取 Secret，不会在网络上明文传输

### 配置 etcd 加密（了解即可）

在生产集群中，你可以配置 API Server 对 Secret 进行加密存储：

```yaml
# /etc/kubernetes/encryption-config.yaml（示意）
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <base64-encoded-32-byte-key>
      - identity: {}   # 兜底：未加密的数据仍可读取
```

这样 Secret 在 etcd 中就是真正加密的，即使有人拿到 etcd 的数据文件也无法直接读取。

> kind 集群默认不开启 etcd 加密。生产环境建议务必开启。

## RBAC 与 Secret 安全

即使 Secret 只是 base64 编码，Kubernetes 的 RBAC 机制仍然可以限制谁有权访问：

```yaml
# 只允许特定 ServiceAccount 读取特定 Secret
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-reader
  namespace: default
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["db-secret"]   # 限制到特定的 Secret
    verbs: ["get"]
```

最佳实践：
- 最小权限原则：只授予必要的 Secret 访问权限
- 不要把 Secret 提交到 Git 仓库
- 考虑使用外部 Secret 管理工具（如 HashiCorp Vault、Sealed Secrets）

## 动手实践

### Step 1: 创建 Secret

```bash
# 用 yaml 文件创建
kubectl apply -f db-secret.yaml

# 查看 Secret 列表
kubectl get secrets
# NAME        TYPE     DATA   AGE
# db-secret   Opaque   2      5s

# 查看详情——注意 data 部分显示的是 base64 编码
kubectl describe secret db-secret
# 你会看到 username 和 password，但值是 base64 编码的

# 解码查看（仅用于调试，不要在生产环境这样做！）
kubectl get secret db-secret -o jsonpath='{.data.password}' | base64 -d
# my-super-password
```

也可以用命令行创建：

```bash
# 从字面量创建
kubectl create secret generic db-secret-cli \
  --from-literal=username=admin \
  --from-literal=password='P@ssw0rd!'

# 从文件创建
kubectl create secret generic file-secret \
  --from-file=ssh-key=~/.ssh/id_rsa
```

> 注意 `generic` 和 `Opaque` 的关系：命令行用 `generic`，yaml 文件里写 `Opaque`，它们是同一个意思。

### Step 2: 以环境变量方式消费

```bash
kubectl apply -f pod-secret-env.yaml

# 等待 Pod 就绪
kubectl wait --for=condition=Ready pod/secret-env-demo --timeout=30s

# 查看日志，确认环境变量已被正确注入
kubectl logs secret-env-demo
# DB_USER=admin DB_PASS=my-super-password

# 清理
kubectl delete -f pod-secret-env.yaml
```

> 你会发现环境变量中显示的是明文密码。这说明：在容器内部，Secret 的值是解码后的明文。Secret 保护的是存储和传输过程，而不是运行时。

### Step 3: 以 Volume 挂载方式消费

```bash
kubectl apply -f pod-secret-volume.yaml

# 等待 Pod 就绪
kubectl wait --for=condition=Ready pod/secret-volume-demo --timeout=30s

# 查看日志
kubectl logs secret-volume-demo
# admin
# ---
# my-super-password

# 也可以直接查看挂载的文件
kubectl exec secret-volume-demo -- ls -la /etc/db-credentials/
# 你会看到两个文件：username 和 password
# 权限是 0644（默认值）

# 查看文件内容
kubectl exec secret-volume-demo -- cat /etc/db-credentials/password
# my-super-password
```

### Step 4: Secret 更新行为

和 ConfigMap 类似，Volume 挂载的 Secret 也会自动更新（kubelet 同步周期内）。但有一个关键区别：

> **Secret 的自动更新在生产环境中要格外小心。** 如果数据库密码在 Secret 中被更新，应用获取到新密码后需要重新建立连接。如果应用不支持平滑切换，可能导致服务中断。

```bash
# 清理
kubectl delete -f pod-secret-volume.yaml
```

## Secret vs ConfigMap：怎么选？

| 场景 | 用什么 |
|------|--------|
| 应用日志级别 | ConfigMap |
| 功能开关 | ConfigMap |
| nginx 配置文件 | ConfigMap |
| 数据库密码 | Secret |
| API Token | Secret |
| TLS 证书 | Secret |
| 镜像仓库凭证 | Secret（`docker-registry` 类型） |

简单原则：**如果泄露会造成安全风险，就用 Secret。**

## 思考题

1. 如果 Secret 被删除了，正在使用该 Secret 的 Pod 会怎样？Volume 挂载方式的环境变量方式的行为是否相同？
2. Base64 编码不是加密，那 Secret 的安全价值到底在哪里？如果你是集群管理员，你会采取哪些额外措施来保护 Secret？
3. 为什么 Secret 的大小限制也是 1MiB？如果你需要存储一个很大的私钥文件（比如超过 1MiB），该怎么办？
4. 查看 Pod 定义时（`kubectl get pod -o yaml`），你能看到 Secret 的明文值吗？这对安全有什么影响？

---

下一个 → [03 - Volume 与 emptyDir](../03-volume-emptydir/)
