# 04 - Pod Security Context：容器安全加固

## 为什么需要 Security Context

先看一个事实：**大多数容器镜像默认以 root 用户运行**。

```bash
# 创建一个普通的 nginx Pod
kubectl run default-nginx --image=nginx

# 看看它以什么用户运行
kubectl exec default-nginx -- id
# uid=0(root) gid=0(root) groups=0(root)
```

`uid=0` 就是 root。这意味着如果攻击者找到了容器内的漏洞（比如一个 RCE 漏洞），他们就拥有了 root 权限。虽然容器本身提供了一定的隔离，但以 root 运行仍然显著增加了风险：

| 风险 | 说明 |
|------|------|
| 容器逃逸 | 某些漏洞允许攻击者从容器内突破到宿主机 |
| 挂载卷权限 | 以 root 运行的容器可以读写挂载卷中的任何文件 |
| 特权操作 | root 可以执行 mount、网络配置等特权操作 |
| 容器间影响 | 如果共享了 PID 命名空间，root 可以操作其他容器的进程 |

> 容器不是虚拟机。容器的隔离依赖 Linux 内核的命名空间（namespace）和控制组（cgroup），这些机制并非不可绕过。以 root 运行容器，等于在说"我相信容器的隔离是完美的"——但历史告诉我们，没有任何隔离是完美的。

## Security Context 是什么

Security Context 是 Pod 和容器级别的一组安全配置，它定义了容器**以什么身份、什么权限运行**。

你可以在两个级别设置：

| 级别 | 字段 | 说明 |
|------|------|------|
| **Pod 级别** | `spec.securityContext` | 对 Pod 内所有容器生效 |
| **容器级别** | `spec.containers[].securityContext` | 只对该容器生效，**覆盖** Pod 级别的设置 |

> 容器级别的设置优先级更高。如果 Pod 设了 `runAsUser: 1000`，某个容器设了 `runAsUser: 2000`，该容器以 2000 运行。

## 关键字段详解

### runAsNonRoot 和 runAsUser

| 字段 | 类型 | 说明 |
|------|------|------|
| `runAsNonRoot` | boolean | `true` = 强制以非 root 运行。如果容器镜像以 root（UID 0）为默认用户，Pod 将无法启动 |
| `runAsUser` | integer | 指定运行容器的用户 UID |
| `runAsGroup` | integer | 指定运行容器的主组 GID |

```yaml
securityContext:
  runAsNonRoot: true    # 必须非 root
  runAsUser: 1000       # 以 UID 1000 运行
  runAsGroup: 3000      # 以 GID 3000 运行
```

> `runAsNonRoot: true` 是一个**强制**检查。如果镜像的 Dockerfile 中没有设置 `USER` 指令（默认 root），且你没有设置 `runAsUser`，Kubelet 会拒绝启动这个容器。这是一种"安全失败"（fail-safe）设计。

### fsGroup

| 字段 | 说明 |
|------|------|
| `fsGroup` | Pod 级别设置。挂载的存储卷的所有权会被设置为此 GID |

```yaml
securityContext:
  fsGroup: 2000   # 挂载的 Volume 文件的 GID 会被改为 2000
```

> `fsGroup` 只对挂载的 Volume 生效，不影响容器内部的文件系统。它解决了"容器以非 root 运行，但需要读写挂载卷"的问题。

### readOnlyRootFilesystem

| 字段 | 说明 |
|------|------|
| `readOnlyRootFilesystem` | `true` = 容器的根文件系统变为只读 |

```yaml
securityContext:
  readOnlyRootFilesystem: true
```

为什么需要只读根文件系统？

1. **防止攻击者写入恶意文件** — 如果容器被入侵，攻击者无法在根文件系统上写入后门、修改配置
2. **强制无状态** — 容器必须通过 Volume 来持久化数据，而不是随意写本地文件
3. **防止意外修改** — 避免应用意外修改自己的二进制文件或配置

> 如果设置了 `readOnlyRootFilesystem: true`，但应用需要写临时文件，可以挂载一个 `emptyDir` 到 `/tmp` 或其他需要的目录。

### allowPrivilegeEscalation

| 字段 | 说明 |
|------|------|
| `allowPrivilegeEscalation` | `false` = 禁止进程获取比父进程更多的特权（如通过 setuid） |

```yaml
securityContext:
  allowPrivilegeEscalation: false
```

> 这个字段控制的是 Linux 的 `no_new_privs` 标志。设置为 `false` 后，即使二进制文件有 setuid 位（如 `sudo`），也不会获得额外的权限。

### capabilities（Linux Capabilities）

Linux 把 root 权限拆分成了几十种**能力**（capabilities），每种能力控制一类特权操作：

| 能力 | 说明 |
|------|------|
| `CAP_NET_BIND_SERVICE` | 绑定 1024 以下的端口 |
| `CAP_NET_RAW` | 发送原始网络包（ping 等） |
| `CAP_SYS_ADMIN` | 系统管理（mount、umount 等）—— 几乎等于 root |
| `CAP_CHOWN` | 修改文件所有者 |
| `CAP_KILL` | 发送信号给其他进程 |

Security Context 允许你精确控制保留哪些能力：

```yaml
securityContext:
  capabilities:
    drop:
      - ALL              # 先丢弃所有能力
    add:
      - NET_BIND_SERVICE # 只加回需要的能力
```

> **最佳实践：先 drop ALL，再按需 add。** 大多数应用不需要任何额外的 Linux capabilities。`drop: ["ALL"]` 是安全加固的基本操作。

## Pod 级别 vs 容器级别

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: example
spec:
  securityContext:               # Pod 级别 — 所有容器继承
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000
  containers:
    - name: app
      image: nginx
      securityContext:           # 容器级别 — 可以覆盖 Pod 级别
        runAsUser: 2000          # 这个容器以 2000 运行，不是 1000
        allowPrivilegeEscalation: false
    - name: sidecar
      image: busybox             # 这个容器继承 Pod 的 1000
```

| 设置 | 容器 app | 容器 sidecar |
|------|---------|-------------|
| runAsUser | 2000（覆盖） | 1000（继承 Pod） |
| runAsGroup | 3000（继承 Pod） | 3000（继承 Pod） |
| fsGroup | 2000（继承 Pod） | 2000（继承 Pod） |

## Step by Step：非 root Pod

### Step 1: 创建命名空间

```bash
kubectl create namespace secctx-demo
```

### Step 2: 创建非 root Pod

```bash
kubectl apply -f nonroot-pod.yaml

# 查看 Pod 状态
kubectl get pods -n secctx-demo
# NAME          READY   STATUS    RESTARTS   AGE
# nonroot-pod   1/1     Running   0          10s
```

### Step 3: 验证运行用户

```bash
# 查看运行身份
kubectl exec nonroot-pod -n secctx-demo -- id
# uid=1000 gid=3000 groups=3000,2000

# 不是 root！UID 是 1000
```

### Step 4: 验证无法写入根文件系统

```bash
# 尝试在根目录创建文件（应该失败）
kubectl exec nonroot-pod -n secctx-demo -- touch /test-file 2>&1
# touch: cannot touch '/test-file': Permission denied

# 这是因为 readOnlyRootFilesystem: true
```

### Step 5: 验证可以写入挂载的临时目录

```bash
# /tmp 是通过 emptyDir 挂载的，可以写入
kubectl exec nonroot-pod -n secctx-demo -- touch /tmp/test-file

kubectl exec nonroot-pod -n secctx-demo -- ls -la /tmp/test-file
# -rw-r--r-- 1 1000 2000 0 ... /tmp/test-file

# 文件的所有者是 UID 1000，组是 GID 2000（fsGroup）
```

## Step by Step：全面加固的 Pod

### Step 6: 创建 hardened Pod

```bash
kubectl apply -f hardened-pod.yaml

kubectl get pods -n secctx-demo
# NAME           READY   STATUS    RESTARTS   AGE
# hardened-pod   1/1     Running   0          10s
```

### Step 7: 验证各项安全配置

```bash
# 运行用户
kubectl exec hardened-pod -n secctx-demo -- id
# uid=1000 gid=3000 groups=3000,2000

# 根文件系统是只读的
kubectl exec hardened-pod -n secctx-demo -- touch /test 2>&1
# Permission denied

# 查看进程的 capabilities
kubectl exec hardened-pod -n secctx-demo -- cat /proc/1/status | grep Cap
# CapEff: 00000000aa....  （注意这里不再有完整 root 权限）
```

### Step 8: 清理

```bash
kubectl delete namespace secctx-demo
```

## 什么情况下容器会启动失败

Security Context 配置不当会导致容器无法启动：

| 场景 | 原因 | 解决方法 |
|------|------|---------|
| `runAsNonRoot: true` 但镜像默认 root | Kubelet 拒绝启动 | 同时设置 `runAsUser: 1000` 或在 Dockerfile 中加 `USER 1000` |
| `readOnlyRootFilesystem: true` 但应用需要写 `/var/log` | 应用写入失败 | 挂载 emptyDir 到 `/var/log` |
| `drop: ["ALL"]` 但应用需要绑定 80 端口 | 缺少 `CAP_NET_BIND_SERVICE` | add 回 `NET_BIND_SERVICE`，或使用 8080 等非特权端口 |
| nginx 需要 cache 目录 | 根文件系统只读 | 挂载 emptyDir 到 `/var/cache/nginx` |

> **排错思路**：如果加了 Security Context 后 Pod 启动失败，先用 `kubectl describe pod` 看 Events，再用 `kubectl logs` 看应用日志。错误信息通常会告诉你缺少什么权限。

## 与镜像的配合

Security Context 和 Dockerfile 中的 `USER` 指令是互补的：

```dockerfile
# Dockerfile 中声明以非 root 运行
FROM nginx
RUN chown -R 1000:1000 /var/cache/nginx /var/run
USER 1000:1000
```

| 方式 | 优点 | 缺点 |
|------|------|------|
| Dockerfile `USER` | 镜像自带安全配置，不依赖 K8s | 需要修改镜像 |
| K8s SecurityContext | 运行时配置，不需要改镜像 | 需要了解应用需求 |
| **两者配合** | 镜像安全 + K8s 强制执行 | 最佳方案 |

## 关键概念总结

| 概念 | 要点 |
|------|------|
| 默认风险 | 大部分容器默认以 root 运行 |
| runAsNonRoot | 强制非 root，root 镜像会启动失败 |
| runAsUser/runAsGroup | 指定 UID/GID |
| fsGroup | 挂载卷的组所有权 |
| readOnlyRootFilesystem | 根文件系统只读，防篡改 |
| allowPrivilegeEscalation | 禁止特权提升 |
| capabilities | 精细控制 Linux 能力，先 drop ALL 再按需 add |
| Pod vs 容器级别 | Pod 级别设置被容器级别覆盖 |

> **安全加固的优先级**：`runAsNonRoot` > `readOnlyRootFilesystem` > `drop ALL capabilities` > 其他。先把最重要的做了。

## 思考题

1. 设置了 `readOnlyRootFilesystem: true` 后，nginx 需要写入 `/var/cache/nginx` 缓存目录，你会怎么解决？
2. `runAsNonRoot: true` 和 `runAsUser: 1000` 的区别是什么？只设 `runAsUser: 1000` 不设 `runAsNonRoot: true` 安全吗？
3. 为什么建议 `drop: ["ALL"]` 再 `add` 需要的能力，而不是逐个 `drop` 不需要的能力？
4. 如果一个 Pod 有两个容器，Pod 级别设置了 `runAsUser: 1000`，容器 A 设置了 `runAsUser: 2000`，容器 B 没有设置。最终 A 和 B 分别以什么用户运行？

---

下一个 → [05 - Pod Security Admission](../05-security-policy/)
