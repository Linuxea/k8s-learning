# 01 - 第一个 Pod

## 概念

### Pod 是什么？

Pod 是 Kubernetes 中**最小的部署与调度单元**。

> "最小单元"不意味着每个节点只能有一个 Pod——一个 worker 可以跑成百上千个 Pod。
> "最小"指的是：你无法绕过 Pod 直接部署容器。K8s 调度器只认 Pod，不认容器。

一个 Pod 可以包含一个或多个容器。最常见的是单容器 Pod（本节），多容器用法下一节讲。

#### 为什么 K8s 不让你直接操作容器？

因为 K8s 不想把自己绑定在某一款容器运行时上（Docker / containerd / CRI-O）。它在容器外面包了一层 Pod，作为统一的：
- **调度单元** — 调度器只看 Pod
- **网络单元** — 同 Pod 内所有容器共享同一个 IP，通过 `localhost` 互访
- **存储单元** — 共享 Volume
- **生命周期单元** — 同生共死，被调度到同一节点

### 常见困惑

在学习过程中，学生会自然遇到以下问题。如果还没碰到，可以先跳过，碰到了再回来看。

#### `kubectl get pods` 和 `kubectl get pod` 是一回事吗？

是的。Pod 的 kubectl 别名：`pods` = `pod` = `po`（三者等价）。
K8s 每种资源都有简称，例如 `services=service=svc`，`nodes=node=no`。

#### `--` 是什么？

```
kubectl exec my-nginx -- curl -s http://localhost
                       ↑
              从这里开始，全部原样传给容器
```

`--` 是 kubectl 和容器命令之间的分隔符。告诉 kubectl："后面的参数不是给你的，别解析，直接传给容器执行。"不加有时也能用，但养成习惯避免歧义。

#### 为什么 `kubectl get pod my-nginx` 可以，但 `kubectl logs pod my-nginx` 不行？

不同子命令解析规则不同：
- `get` 的第二个位置可以是 TYPE 也可以是 NAME，kubectl 会智能推断
- `logs` 不需要 TYPE（日志只能属于 Pod），它把 `pod` 当成了 Pod 名字去找，自然找不到

**建议**：日常操作直接用 NAME（不写类型），K8s 会自动推断资源类型。只有出现歧义时（比如 Deployment 和 Pod 同名），才用 `TYPE/NAME` 格式显式指定。

#### `pod/my-nginx` 里 `pod` 是命名空间吗？

不是。`pod` 是**资源类型**。`TYPE/NAME` 是 kubectl 的一种通用资源引用格式：
```
kubectl get pod/my-nginx         # TYPE/NAME
kubectl get service/my-service   # 同上
```
命名空间用 `-n` 指定：`kubectl get pod my-nginx -n default`。两者完全不同。

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

## 集群层级概览

在你动手之前，先理解你操作的集群长什么样：

```
集群 (kubectl cluster-info)
├── 控制平面节点 (control-plane) — apiserver、etcd、scheduler、controller-manager
│   └── kubelet （也跑在这里，汇报心跳）
├── 工作节点 1   — kubelet（管理容器）+ kube-proxy（网络规则）
│   ├── Pod A（nginx）
│   ├── Pod B（Redis）
│   └── ...（很多 Pod）
└── 工作节点 2
    └── ...（分担负载）
```

> **kubelet 是什么？** 每个节点上都跑着一个 kubelet 进程，相当于节点的"代理人"。它每隔约 10 秒向 control-plane 汇报心跳（我还活着 + 节点剩多少资源 + 上面的 Pod 是否健康）。如果心跳停了约 40 秒，节点会被标记为 NotReady；5 分钟后，上面的 Pod 会被重新调度到其他健康节点。

## Step by Step 操作

> 以下命令在交互式学习中由 AI 逐步给出。这里作为**操作参考**，方便课后回顾。

### Step 1: 查看集群节点

```bash
kubectl get nodes
```

在 kind 集群中你会看到多个节点。`ROLES` 列标明了节点的分工：`control-plane`（控制平面）和普通 worker。**三个节点上都有 kubelet**，control-plane 只是额外多跑了 etcd、apiserver 等控制组件。

### Step 2: 创建 Pod

创建 `nginx-pod.yaml` 文件，写入以下内容，然后 `kubectl apply -f nginx-pod.yaml`。

> **注意理解 `kubectl apply` 的本质**：它是声明式的——你告诉 K8s "我想要的就是这样"，K8s 自己去达成这个目标。Pod 不存在就创建，已存在就更新。你执行 10 次，结果一样。

### Step 3: 查看 Pod 状态

```bash
kubectl get pods          # 基本列表
kubectl get pods -o wide  # 多出 IP、所在节点
```

Pod 状态通常的流转：`Pending` → `ContainerCreating`（拉镜像中）→ `Running`。

- `READY 1/1` = 期望 1 个容器，1 个已就绪
- `RESTARTS` = 容器重启次数。频繁重启说明容器有问题
- kubelet 每隔约 10 秒汇报心跳，control-plane 判断 READY 状态（不是"启动过一次就一直绿"）

### Step 4: 查看 Pod 详情

```bash
kubectl describe pod my-nginx
```

重点关注 **Events** 段落——时间线记录了调度、拉镜像、启动的全过程，是排查问题的第一入口。你还会看到：
- Pod 被 schedule 到了哪个节点（`k8s-learn-worker2`）
- 镜像是否已缓存（`already present on machine`）
- Pod 所属的 namespace（默认 `default`）

### Step 5: 在 Pod 里执行命令

```bash
# 执行单条命令（执行完退出）
kubectl exec my-nginx -- curl -s http://localhost

# 获得交互式 shell（进去自由探索）
kubectl exec -it my-nginx -- /bin/bash
```

> `kubectl exec` 严格来说是"在容器里执行一条命令"，不是"进入容器"。加上 `-it` 才能获得交互终端。

### Step 6: 查看日志

```bash
kubectl logs my-nginx            # 一次性查看
kubectl logs -f my-nginx         # 实时跟踪（Ctrl+C 退出）
kubectl logs my-nginx --tail=5   # 只看最近 5 行
```

### Step 7: 删除 Pod

```bash
kubectl delete pod my-nginx      # 按名字删除
kubectl delete -f nginx-pod.yaml # 按 yaml 文件删除
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

### 资源类型别名

| 资源 | 完整 | 单数 | 短名 |
|------|------|------|------|
| Pod | `pods` | `pod` | `po` |
| Service | `services` | `service` | `svc` |
| Deployment | `deployments` | `deployment` | `deploy` |
| Node | `nodes` | `node` | `no` |
| Namespace | `namespaces` | `namespace` | `ns` |

### 常⽤操作

| 命令 | 作用 |
|------|------|
| `kubectl get pods` | 列出当前 namespace 的 Pod |
| `kubectl get pods -A` | 列出所有 namespace 的 Pod |
| `kubectl get pod <name> -o yaml` | 导出完整 yaml（反向推敲写法时非常实用） |
| `kubectl describe pod <name>` | Pod 详情（重点看 Events） |
| `kubectl logs <name>` | 查看日志 |
| `kubectl logs <name> -c <container>` | 多容器 Pod 中指定容器查看日志 |
| `kubectl logs -f <name>` | 实时跟踪日志 |
| `kubectl exec <name> -- <cmd>` | 在容器内执行一条命令 |
| `kubectl exec -it <name> -- /bin/bash` | 获得交互式终端 |
| `kubectl delete pod <name>` | 删除 Pod |

### 约定

- `--` 分隔 kubectl 参数和容器内命令：`kubectl exec my-nginx -- curl http://localhost`
- 日常操作直接用 NAME（不写类型），K8s 自动推断。只有歧义时才用 `TYPE/NAME`
- 如果没有指定 namespace，默认操作 `default` 命名空间下的资源
- `-A` = `--all-namespaces`

## 思考题

1. 如果一个 Pod 里的容器崩溃了，K8s 会怎么处理？（提示：看看 `restartPolicy`，默认值是什么？）
2. `kubectl get pods -A` 和 `kubectl get pods` 的输出有什么区别？为什么？
3. 如果 Pod 一直卡在 `Pending` 状态，你会怎么排查？
4. 为什么 Kubernetes 不直接操作容器，而是设计了 Pod 这一层抽象？如果只有一个容器，Pod 这层是不是多余的？

---

下一个 → [02 - 多容器 Pod](../02-multi-container-pod/)
