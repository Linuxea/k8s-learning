# 01 - 第一个 Pod

## Pod 是什么

Pod 是 Kubernetes 中**最小的部署单元**。你可能会问：为什么不直接部署容器？

因为 Kubernetes 不想把你绑定在某一个容器运行时（Docker、containerd、CRI-O……）上。
它在容器外面又包了一层 —— Pod，作为一个统一的调度、网络、存储单元。

一个 Pod 里可以放一个或多个容器，它们：

- **共享网络命名空间** — 同一个 IP 地址，互相通过 `localhost` 通信
- **共享存储卷** — 可以挂载同一个 Volume
- **共享生命周期** — 同生共死，一起被调度到同一个节点上

> 最常见的情况：一个 Pod 里只有一个容器。多容器 Pod 是更高级的用法，下一节会讲。

## YAML 结构拆解

下面是我们第一个 Pod 的完整定义：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-nginx
  labels:
    app: nginx
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      ports:
        - containerPort: 80
```

逐行理解：

| 字段 | 含义 |
|------|------|
| `apiVersion: v1` | 告诉 K8s 你用的是哪个 API 版本。Pod 属于核心 API 组，用 `v1` |
| `kind: Pod` | 资源类型。K8s 有几十种资源类型（Deployment、Service、ConfigMap……），这里是 Pod |
| `metadata.name` | 这个 Pod 的名字，在同一个命名空间（namespace）内必须唯一 |
| `metadata.labels` | 标签，键值对。之后 Service、Deployment 会通过标签来"选中"Pod，这是 K8s 里非常重要的松耦合机制 |
| `spec.containers` | Pod 里要跑的容器列表 |
| `containers[].name` | 容器名，Pod 内唯一 |
| `containers[].image` | 镜像名，格式是 `仓库地址/镜像名:标签`。没写仓库地址就默认从 Docker Hub 拉取 |
| `containers[].ports` | 声明容器监听的端口。注意：这只是**声明**，不写也能访问，写了也不会自动映射到主机 |

### 为什么 ports 只是"声明"？

这是一个初学者常见的困惑。`containerPort: 80` 的作用是：

1. **文档性质** — 告诉使用者"这个容器用了 80 端口"
2. **被 Service 引用时** — Service 可以按名字引用端口
3. **某些网络策略** — 可以基于端口做过滤

但它**不会**自动把端口映射到宿主机。要让外部能访问 Pod，需要 Service（第三章会讲）。

## Step by Step 操作

### Step 1: 创建集群（kind）

如果集群还没搭建，先创建：

```bash
# 创建一个单节点集群
kind create cluster --name k8s-learning

# 验证集群就绪
kubectl cluster-info
```

### Step 2: 查看当前环境

```bash
# 查看集群中的节点
kubectl get nodes

# 你会看到类似这样的输出：
# NAME                       STATUS   ROLES           AGE   VERSION
# k8s-learning-control-plane Ready    control-plane   1m    v1.31.0
```

### Step 3: 创建 Pod

```bash
# 用 yaml 文件创建
kubectl apply -f nginx-pod.yaml

# 你会看到：
# pod/my-nginx created
```

### Step 4: 查看 Pod 状态

```bash
# 查看 Pod 列表
kubectl get pods

# 输出类似：
# NAME       READY   STATUS    RESTARTS   AGE
# my-nginx   1/1     Running   0          30s

# 查看更详细的信息
kubectl get pods -o wide

# 输出会多出 IP、所在节点等信息：
# NAME       READY   STATUS    RESTARTS   AGE   IP           NODE                       NOMINATED NODE
# my-nginx   1/1     Running   0          30s   10.244.0.5   k8s-learning-control-plane <none>
```

`READY` 列的含义：`1/1` 表示"期望 1 个容器，1 个已就绪"。

### Step 5: 查看 Pod 详情

```bash
kubectl describe pod my-nginx
```

这个命令会输出非常丰富的信息，重点关注这些段落：

| 段落 | 你能看到的 |
|------|-----------|
| **Status** | Pod 当前状态、IP、所在节点 |
| **Containers** | 镜像、端口、环境变量、挂载点 |
| **Events** | 事件时间线 — 调度、拉镜像、启动，如果出错这里能找到线索 |

> Events 是排查问题的第一入口。如果 Pod 启动失败，先看 `kubectl describe pod` 底部的 Events。

### Step 6: 进入 Pod 内部

```bash
# 在 Pod 里执行命令
kubectl exec my-nginx -- curl -s http://localhost

# 你会看到 nginx 的默认欢迎页 HTML

# 如果想获得一个交互式终端
kubectl exec -it my-nginx -- /bin/bash

# 进去之后你就在容器内部了，可以自由探索：
# ps aux          # 看进程
# cat /etc/os-release  # 看系统信息
# exit            # 退出
```

`--` 的作用是分隔 kubectl 参数和容器内命令。虽然很多时候不加也能用，但加上是好习惯，避免歧义。

### Step 7: 查看 Pod 日志

```bash
# 查看日志
kubectl logs my-nginx

# 因为没人访问过，可能没有输出。先访问一下：
kubectl exec my-nginx -- curl -s http://localhost > /dev/null

# 再看日志
kubectl logs my-nginx
# 你会看到一条 GET 请求的访问日志

# 实时跟踪日志（类似 tail -f）
kubectl logs -f my-nginx
# Ctrl+C 退出
```

### Step 8: 删除 Pod

```bash
kubectl delete pod my-nginx

# 验证已删除
kubectl get pods
# No resources found in default namespace.
```

也可以直接用 yaml 文件删除：

```bash
kubectl delete -f nginx-pod.yaml
```

## 创建 Pod 的另一种方式：kubectl run

除了写 yaml 文件，还可以用命令行快速创建：

```bash
# 创建一个 Pod
kubectl run my-nginx --image=nginx:1.27 --port=80

# 这和上面的 yaml 效果一样，但只用一行命令
# 缺点是：无法设置 labels、环境变量等，不适合生产使用
# 适合快速测试
```

如果你已经有了 Pod，想反推出它的 yaml：

```bash
kubectl get pod my-nginx -o yaml
```

这个技巧非常实用——当你不确定 yaml 怎么写时，先用 `kubectl run` 创建，再用 `-o yaml` 导出，在此基础上修改。

## Pod 的状态流转

一个 Pod 从创建到销毁会经历这些状态：

```
Pending → Running → Succeeded
                  → Failed
```

| 状态 | 含义 |
|------|------|
| **Pending** | 已被 K8s 接受，但还没开始运行。常见原因：调度中、拉取镜像中 |
| **Running** | 已绑定到节点，至少一个容器还在运行 |
| **Succeeded** | 所有容器正常退出，且不会重启 |
| **Failed** | 至少一个容器异常退出（非 0 退出码） |
| **Unknown** | 无法获取 Pod 状态，通常是节点通信故障 |

看到 `Pending` 不用慌，多半是在下载镜像，用 `kubectl describe pod` 看 Events 就知道进度了。

## kubectl 常用命令速查

| 命令 | 作用 |
|------|------|
| `kubectl get pods` | 列出 Pod |
| `kubectl get pods -A` | 列出所有命名空间的 Pod |
| `kubectl describe pod <name>` | Pod 详情 |
| `kubectl logs <name>` | 查看日志 |
| `kubectl logs <name> -c <container>` | 多容器 Pod 中指定容器查看日志 |
| `kubectl exec -it <name> -- /bin/bash` | 进入容器 |
| `kubectl delete pod <name>` | 删除 Pod |
| `kubectl get pod <name> -o yaml` | 导出完整 yaml |
| `kubectl get pod <name> -o json` | 导出 JSON 格式 |

## 思考题

1. 如果一个 Pod 里的容器崩溃了，K8s 会怎么处理？（提示：看看 `restartPolicy`，默认值是什么？）
2. `kubectl get pods -A` 和 `kubectl get pods` 的输出有什么区别？为什么？
3. 如果 Pod 一直卡在 `Pending` 状态，你会怎么排查？
4. 为什么 Kubernetes 不直接操作容器，而是设计了 Pod 这一层抽象？如果只有一个容器，Pod 这层是不是多余的？

---

下一个 → [02 - 多容器 Pod](../02-multi-container-pod/)
