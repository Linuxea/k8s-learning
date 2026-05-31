# Chapter 00 - 搭建 K8s 学习环境

## 本章目标

在 AWS Lightsail 上搭建一个完整的 Kubernetes 学习环境：

- 一台 Lightsail VPS 作为宿主机
- 用 kind 创建 3 节点 K8s 集群（1 control-plane + 2 worker）
- 支持从本机远程操控集群
- 安装 Ingress Controller，为后续章节做准备

## 架构概览

```
你的本机                        AWS Lightsail VPS
┌──────────────┐               ┌─────────────────────────────────────┐
│              │   SSH         │  kind: k8s-learning                 │
│  kubectl ────┼───────────────┼─► Docker                            │
│              │   (kubeconfig)│  ┌─────────────────────────────┐    │
│              │               │  │ K8s Cluster                 │    │
│              │               │  │  ┌─ control-plane ──────┐  │    │
│              │               │  │  │  kube-apiserver      │  │    │
│              │               │  │  │  etcd                │  │    │
│              │               │  │  └──────────────────────┘  │    │
│              │               │  │  ┌─ worker-1 ───────────┐  │    │
│              │               │  │  │  kubelet, kube-proxy │  │    │
│              │               │  │  └──────────────────────┘  │    │
│              │               │  │  ┌─ worker-2 ───────────┐  │    │
│              │               │  │  │  kubelet, kube-proxy │  │    │
│              │               │  │  └──────────────────────┘  │    │
│              │               │  └─────────────────────────────┘    │
└──────────────┘               └─────────────────────────────────────┘
```

关键点：kind 的每个"节点"其实是一个 Docker 容器，里面跑了完整的 K8s 组件。
这和生产环境用虚拟机/物理机跑 K8s 节点本质一样，只是运行载体不同。

---

## Step 1: 创建 Lightsail 实例

### 1.1 规格选择

| 方案 | 配置 | 月费 | 评价 |
|------|------|------|------|
| 最低配 | 512MB RAM, 1 vCPU | $5 | **不够用**，kind 集群都启动不了 |
| 基础配 | 2GB RAM, 1 vCPU, 40GB SSD | $10 | 能跑但紧张，3 节点集群会比较卡 |
| 推荐配 | 4GB RAM, 2 vCPU, 80GB SSD | $20 | 余量充足，体验流畅 |

> 为什么需要这么多内存？kind 的每个节点都是一个 Docker 容器，
> control-plane 节点要跑 etcd + apiserver + scheduler + controller-manager，
> 3 个节点加起来就要 ~2GB，再加上宿主机系统本身的开销。

### 1.2 创建步骤

1. 登录 [AWS Lightsail 控制台](https://lightsail.aws.amazon.com/)
2. 点击 **Create instance**
3. 选择区域：
   - 如果你在国内，选 **Asia Pacific (Tokyo)** 或 **Asia Pacific (Singapore)** 延迟较低
   - 如果你在北美，选离你最近的 US 区域
4. 选择 **Linux/Unix** → **OS Only** → **Ubuntu 24.04 LTS**
5. 选择规格（建议 4GB RAM / $20 方案）
6. 下载或选择 SSH 密钥（如果没有，Lightsail 会引导你创建）
7. 给实例起个名字，比如 `k8s-learning`
8. 点击 **Create instance**

### 1.3 配置防火墙

实例创建好后，进入 **Networking** 标签页，添加以下防火墙规则：

| 端口 | 协议 | 用途 | 何时需要 |
|------|------|------|---------|
| 22 | TCP | SSH | 必须，管理服务器 |
| 80 | TCP | HTTP | 第三章 Ingress |
| 443 | TCP | HTTPS | 第三章 Ingress |
| 30000-32767 | TCP | NodePort 范围 | 第三章 Service |

> Lightsail 默认只开了 22 和 80。其他端口需要手动添加。
> 不用一次全加，用到时再加也可以。

---

## Step 2: SSH 登录 & 基础配置

### 2.1 连接到服务器

```bash
# 修改密钥文件权限（如果还没改过）
chmod 400 ~/Downloads/LightsailDefaultKey-<region>.pem

# SSH 连接
ssh -i ~/Downloads/LightsailDefaultKey-<region>.pem ubuntu@<你的公网IP>
```

> `<你的公网IP>` 在 Lightsail 控制台的实例页面可以看到。

也可以用 Lightsail 控制台自带的浏览器 SSH（点击实例旁边的终端图标），但本地终端体验更好。

### 2.2 系统更新

```bash
sudo apt update && sudo apt upgrade -y
```

### 2.3 设置时区（可选）

```bash
sudo timedatectl set-timezone Asia/Shanghai
```

### 2.4 验证系统资源

```bash
# 查看内存
free -h

# 查看磁盘
df -h

# 查看 CPU
nproc
```

确认资源符合预期后再继续。

---

## Step 3: 安装 Docker

kind 依赖 Docker 来运行 K8s 节点容器（每个 K8s 节点 = 一个 Docker 容器）。

```bash
# 安装 Docker
sudo apt install -y docker.io

# 启动并设置开机自启
sudo systemctl enable docker
sudo systemctl start docker

# 把当前用户加入 docker 组，免 sudo
sudo usermod -aG docker ubuntu

# 验证安装
docker --version
# Docker version 27.x.x, build xxxxxxx

# 使组权限生效（需要重新登录）
exit
```

**重新登录** SSH 后验证：

```bash
# 不带 sudo 运行 docker，确认组权限生效
docker run --rm hello-world
# 看到Hello from Docker!就说明OK
```

### 为什么是 Docker 而不是 containerd？

你可能听说过"Kubernetes 已经弃用 Docker"，这句话的意思是：
K8s 的容器运行时接口（CRI）不再直接对接 Docker，而是通过 **containerd**。

但 kind 是特例——它用 Docker 作为"模拟节点的容器运行时"，
K8s 集群内部的容器运行时仍然是 containerd（嵌套在 Docker 容器里）。

简单说：**kind 需要 Docker，但 K8s 本身跑的容器用的是 containerd**。

---

## Step 4: 安装 kind

[kind](https://kind.sigs.k8s.io/) 全称 **Kubernetes IN Docker**，
是一个用 Docker 容器模拟 K8s 节点的工具。

```bash
# 下载 kind（注意版本号，可去 GitHub Releases 页面确认最新版）
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64

# 赋予执行权限
chmod +x ./kind

# 移动到 PATH
sudo mv ./kind /usr/local/bin/

# 验证
kind version
# kind v0.24.0 go1.22.4 linux/amd64
```

> 如果下载慢，可能是网络问题。可以试试配置代理，或者从其他镜像站下载。

---

## Step 5: 安装 kubectl

[kubectl](https://kubernetes.io/docs/reference/kubectl/) 是 K8s 的命令行客户端，
你几乎所有的 K8s 操作都会通过它来完成。

```bash
# 下载最新稳定版
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

# 赋予执行权限
chmod +x kubectl

# 移动到 PATH
sudo mv kubectl /usr/local/bin/

# 验证
kubectl version --client
# Client Version: v1.31.x
```

### kubectl 是怎么找到集群的？

kubectl 每次执行命令时，会按以下顺序查找配置：

1. `--kubeconfig` 参数指定的文件
2. 环境变量 `KUBECONFIG` 指定的文件
3. 默认路径 `~/.kube/config`

这个配置文件就是 **kubeconfig**。kind 创建集群后会自动生成它。

---

## Step 6: 创建 kind 集群

### 6.1 编写集群配置

将 `kind-cluster.yaml` 上传到 Lightsail 服务器（或直接在服务器上创建）：

```bash
cat > ~/kind-cluster.yaml << 'EOF'
# kind 集群配置文件
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  # 控制面节点：运行 K8s 的核心组件
  - role: control-plane
    # 把容器的 80/443 端口映射到宿主机，让 Ingress 可以从外部访问
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP

  # 工作节点：跑你的应用 Pod
  - role: worker

  # 第二个工作节点：可以练习多节点调度
  - role: worker
```

### 6.2 创建集群

```bash
# 创建集群（需要几分钟，主要时间花在拉取镜像上）
kind create cluster --name k8s-learning --config ~/kind-cluster.yaml

# 输出类似：
# Creating cluster "k8s-learning" ...
# ✓ Ensuring node image (kindest/node:v1.31.0) 🖼
# ✓ Preparing nodes 📦 📦 📦
# ✓ Writing configuration 📜
# ✓ Starting control-plane 🕹️
# ✓ Installing CNI 🔌
# ✓ Installing StorageClass 💾
# ✓ Joining worker nodes 🚜
# Set kubectl context to "kind-k8s-learning"
# Cluster creation complete!
```

### 6.3 理解 kind 做了什么

创建完成后，你可以看看 Docker 层面发生了什么：

```bash
# kind 用 Docker 容器模拟了 3 个 K8s 节点
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# 输出类似：
# NAMES                       STATUS          PORTS
# k8s-learning-worker2        Up 5 minutes
# k8s-learning-worker         Up 5 minutes
# k8s-learning-control-plane  Up 5 minutes    0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp
```

这就是 kind 的巧妙之处——每个 Docker 容器就是一个"K8s 节点"，里面跑了：
- **control-plane 容器**：kube-apiserver、etcd、kube-scheduler、kube-controller-manager
- **worker 容器**：kubelet、kube-proxy、containerd

和真实集群的区别仅仅是"节点跑在容器里 vs 跑在虚拟机/物理机上"，K8s 层面的行为完全一致。

### 6.4 验证集群

```bash
# 查看节点
kubectl get nodes

# 期望输出（3 个节点都是 Ready）：
# NAME                         STATUS   ROLES           AGE   VERSION
# k8s-learning-control-plane   Ready    control-plane   2m    v1.31.0
# k8s-learning-worker          Ready    <none>          90s   v1.31.0
# k8s-learning-worker2         Ready    <none>          90s   v1.31.0

# 查看集群信息
kubectl cluster-info

# 查看 kubeconfig 的位置
echo $KUBECONFIG
# kind 默认会写入 ~/.kube/config
```

### 6.5 查看 K8s 核心组件

```bash
# 查看 control-plane 上跑的系统 Pod
kubectl get pods -n kube-system

# 你会看到类似：
# NAME                                                 READY   STATUS    RESTARTS   AGE
# coredns-xxx-xxx                                      1/1     Running   0          5m
# etcd-k8s-learning-control-plane                      1/1     Running   0          5m
# kindnet-xxx                                          1/1     Running   0          5m
# kube-apiserver-k8s-learning-control-plane            1/1     Running   0          5m
# kube-controller-manager-k8s-learning-control-plane   1/1     Running   0          5m
# kube-proxy-xxx                                       1/1     Running   0          5m
# kube-scheduler-k8s-learning-control-plane            1/1     Running   0          5m
```

| 组件 | 作用 |
|------|------|
| **etcd** | 分布式键值存储，保存集群所有数据（"K8s 的数据库"） |
| **kube-apiserver** | K8s 的 API 入口，所有操作（kubectl、Dashboard、其他组件）都通过它 |
| **kube-scheduler** | 决定 Pod 调度到哪个节点（第五章会深入学） |
| **kube-controller-manager** | 运行各种控制器（Deployment Controller、ReplicaSet Controller 等） |
| **kube-proxy** | 每个 node 上运行，负责 Service 的网络转发 |
| **coredns** | 集群内部 DNS 服务，让 Pod 可以通过名字访问 Service |
| **kindnet** | kind 使用的 CNI 网络插件，提供 Pod 间通信 |

> 现在不需要全部记住，后面章节会逐个深入。这里只是让你对"集群里有什么"有个整体印象。

---

## Step 7: 验证集群 — 跑一个测试 Pod

创建一个测试用的 Nginx Pod，验证集群能正常工作：

```bash
kubectl apply -f ~/verify-cluster.yaml

# 查看状态
kubectl get pods -o wide

# 期望：Pod 是 Running 状态，被调度到某个 worker 节点上
```

在 Pod 内部访问 Nginx：

```bash
kubectl exec verify-nginx -- curl -s http://localhost | head -5

# 看到 HTML 输出就说明一切正常
```

验证完成后删除：

```bash
kubectl delete -f ~/verify-cluster.yaml
```

---

## Step 8: 配置本地 kubectl 远程连接

这一步让你能在**自己电脑上**直接用 kubectl 操作远程 Lightsail 上的集群，
这是更贴近真实工作场景的方式。

### 8.1 在 Lightsail 上导出 kubeconfig

```bash
# SSH 到 Lightsail 上执行
kind get kubeconfig --name k8s-learning > ~/k8s-learning-kubeconfig.yaml
```

### 8.2 下载到本机

```bash
# 在本机执行（不是在 Lightsail 上）
scp -i <你的密钥.pem> ubuntu@<Lightsail公网IP>:~/k8s-learning-kubeconfig.yaml ~/.kube/k8s-learning-config
```

### 8.3 修改 server 地址

kubeconfig 里的 server 地址默认是 `127.0.0.1`，需要改成 Lightsail 的公网 IP：

```bash
# 在本机修改
sed -i 's/127\.0\.0\.1/<你的Lightsail公网IP>/g' ~/.kube/k8s-learning-config
```

或者手动编辑 `~/.kube/k8s-learning-config`，把 `server: https://127.0.0.1:XXXXX` 改成 `server: https://<Lightsail公网IP>:XXXXX`。

### 8.4 使用

```bash
# 方式一：设置环境变量
export KUBECONFIG=~/.kube/k8s-learning-config
kubectl get nodes

# 方式二：每次指定
kubectl --kubeconfig ~/.kube/k8s-learning-config get nodes

# 方式三：合并到默认 kubeconfig
# 如果你已经有其他集群的配置，可以合并：
kubectl config view --flatten > ~/.kube/config.tmp
# 然后把新配置追加进去
KUBECONFIG=~/.kube/config.tmp:~/.kube/k8s-learning-config kubectl config view --flatten > ~/.kube/config
rm ~/.kube/config.tmp
```

### 8.5 验证

```bash
kubectl get nodes
# 应该能看到 3 个节点，和 SSH 到 Lightsail 上看到的一样
```

> 如果连不上，检查：
> 1. Lightsail 防火墙是否放行了 kubeconfig 中的端口（通常是 6443 或随机高端口）
> 2. kubeconfig 中的 IP 是否正确
> 3. 用 `curl -k https://<IP>:<PORT>/livez` 测试 API 是否可达

---

## Step 9: 安装 Ingress Controller

Ingress 是 K8s 里管理外部 HTTP/HTTPS 访问的方式（第三章会详细学）。
这里先装好，后面直接用。

```bash
# 安装 NGINX Ingress Controller（专门为 kind 定制的版本）
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# 等待 Ingress Controller 就绪
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

# 验证
kubectl get pods -n ingress-nginx
# 应该看到 1 个 Running 的 controller Pod
```

安装完成后，端口映射链路是这样的：

```
外部请求 → Lightsail公网IP:80 → Docker映射 → kind control-plane:80 → Ingress Controller → Pod
```

---

## 日常管理命令

### kind 集群管理

```bash
# 查看已有集群
kind get clusters

# 删除集群（销毁所有数据）
kind delete cluster --name k8s-learning

# 重建集群（删了重建）
kind delete cluster --name k8s-learning
kind create cluster --name k8s-learning --config ~/kind-cluster.yaml
```

### 常用 kubectl 命令

```bash
# 查看 Pod
kubectl get pods -A              # 所有命名空间
kubectl get pods                 # 当前命名空间（default）

# 查看节点
kubectl get nodes

# 查看 Service
kubectl get svc -A

# 查看所有资源
kubectl get all
```

### Lightsail 管理

```bash
# SSH 连接
ssh -i <密钥.pem> ubuntu@<IP>

# 查看 Docker 状态
sudo systemctl status docker

# 查看磁盘使用
df -h

# 查看内存使用
free -h

# 重启（如果集群出问题）
sudo reboot
```

---

## 故障排查

### 问题：kind create cluster 卡在 pull image

```bash
# 查看 Docker 拉取进度
docker pull kindest/node:v1.31.0

# 如果网络不通，可以配置 Docker 代理
sudo mkdir -p /etc/systemd/system/docker.service.d
cat <<EOF | sudo tee /etc/systemd/system/docker.service.d/proxy.conf
[Service]
Environment="HTTP_PROXY=http://your-proxy:port"
Environment="HTTPS_PROXY=http://your-proxy:port"
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker
```

### 问题：kubectl get nodes 显示 NotReady

```bash
# 查看节点详情
kubectl describe node <node-name>

# 看 Conditions 部分，重点关注：
# - Ready: True/False
# - 原因会写在 Message 字段里

# 常见原因：CNI 插件还没就绪，等一会就好
```

### 问题：本地 kubectl 连不上远程集群

```bash
# 1. 检查网络连通性
curl -k https://<IP>:<PORT>/livez

# 2. 检查 kubeconfig 里的 IP 和端口
cat ~/.kube/k8s-learning-config | grep server

# 3. 检查 Lightsail 防火墙
# 在 Lightsail 控制台 → Networking → 确认对应端口已放行

# 4. 如果端口是随机高端口（如 38xyz），必须在防火墙里手动添加
```

### 问题：内存不足，Pod 一直 Pending

```bash
# 查看节点资源使用
kubectl describe nodes | grep -A 5 "Allocated resources"

# 如果确实不够，两个选择：
# 1. 减少节点数（改 kind config 为单节点）
# 2. 升级 Lightsail 规格
```

---

## 清理（学完要销毁环境时）

```bash
# 在 Lightsail 上删除 kind 集群
kind delete cluster --name k8s-learning

# 在 Lightsail 控制台删除实例（停止计费）
# 或用 AWS CLI：
# aws lightsail delete-instance --instance-name k8s-learning
```

---

下一个 → [Chapter 01 - Pod 基础](../chapter01-pod-basics/01-first-pod/)
