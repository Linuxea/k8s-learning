# Chapter 00 - 搭建 K8s 学习环境

## 本章目标

在腾讯云 CVM 上搭建一个完整的 Kubernetes 学习环境：

- 一台竞价实例 CVM 作为宿主机（2 vCPU / 4GB RAM，按秒计费）
- 用 kind 创建 3 节点 K8s 集群（1 control-plane + 2 worker）
- 支持从本机远程操控集群
- 安装 Ingress Controller，为后续章节做准备

## 架构概览

```
你的本机                          腾讯云 CVM (竞价实例)
┌──────────────┐                 ┌─────────────────────────────────────┐
│              │   SSH           │  kind: k8s-learning                 │
│  kubectl ────┼─────────────────┼─► Docker                            │
│              │   (kubeconfig)  │  ┌─────────────────────────────┐    │
│              │                 │  │ K8s Cluster                 │    │
│              │                 │  │  ┌─ control-plane ──────┐  │    │
│              │                 │  │  │  kube-apiserver      │  │    │
│              │                 │  │  │  etcd                │  │    │
│              │                 │  │  └──────────────────────┘  │    │
│              │                 │  │  ┌─ worker-1 ───────────┐  │    │
│              │                 │  │  │  kubelet, kube-proxy │  │    │
│              │                 │  │  └──────────────────────┘  │    │
│              │                 │  │  ┌─ worker-2 ───────────┐  │    │
│              │                 │  │  │  kubelet, kube-proxy │  │    │
│              │                 │  │  └──────────────────────┘  │    │
│              │                 │  └─────────────────────────────┘    │
└──────────────┘                 └─────────────────────────────────────┘
```

关键点：kind 的每个"节点"其实是一个 Docker 容器，里面跑了完整的 K8s 组件。
这和生产环境用虚拟机/物理机跑 K8s 节点本质一样，只是运行载体不同。

---

## Step 1: 创建腾讯云 CVM 竞价实例

### 1.1 为什么选腾讯云竞价实例

| 方案 | 配置 | 计费 | 大约成本 |
|------|------|------|---------|
| 腾讯云竞价实例 | 2C4G, 50GB SSD | 按秒 | ~¥0.05-0.1/小时，每天学 2 小时约 ¥0.1-0.2 |
| 腾讯云按量计费 | 2C4G, 50GB SSD | 按秒 | ~¥0.4-0.5/小时 |
| AWS Lightsail | 4GB RAM | 固定月费 | $20/月（~¥145） |

竞价实例的优势：
- **极低成本**：按量计费的 3-20%，一个月学下来可能不到 ¥10
- **用完即走**：不用了直接销毁，停止计费
- **国内延迟低**：广州节点，从国内访问延迟 ~10-30ms

竞价实例的劣势：
- **可能被回收**：库存不足时系统会随机回收实例（实际很少发生）
- **不适合跑重要服务**：但学习环境无所谓，被回收了用脚本几分钟重建

> 不用担心被回收——我们准备了自动化脚本，重建整个集群只需要几分钟。

### 1.2 安装 tccli（腾讯云 CLI）

```bash
# 安装
pip install tccli

# 配置密钥（需要先在腾讯云控制台创建 API 密钥）
tccli configure
# 按提示输入 SecretId、SecretKey、区域（ap-guangzhou）、输出格式（json）

# 验证
tccli cvm DescribeRegions
```

> 密钥获取：登录 [腾讯云控制台](https://console.cloud.tencent.com/) → 右上角 → 访问管理 → API 密钥管理 → 新建密钥

### 1.3 导入 SSH 公钥到腾讯云

如果你本地的 SSH 公钥还没有上传到腾讯云，需要先导入，否则创建的实例你连不上：

```bash
# 查看本地已有的公钥（选一个你常用的）
cat ~/.ssh/id_rsa.pub

# 导入到腾讯云（密钥名称只能用字母数字下划线）
tccli cvm ImportKeyPair \
  --region ap-guangzhou \
  --KeyName k8s_learning \
  --ProjectId 0 \
  --PublicKey "$(cat ~/.ssh/id_rsa.pub)"

# 记下返回的 KeyId（如 skey-xxx），后面创建实例时要用
```

> 如果腾讯云已有你本地对应的密钥对，可跳过这步。用 `tccli cvm DescribeKeyPairs --region ap-guangzhou` 查看。

### 1.4 用 tccli 创建竞价实例

> **注意**：tccli 不支持 AWS CLI 的 `--query` / `--output text` 参数，输出只有 JSON 格式。
> 需要从 JSON 中提取字段时，配合 `python3 -c` 或 `jq` 使用。

```bash
# 查看广州可用区（目前只有 5/6/7 区可用）
tccli cvm DescribeZones --region ap-guangzhou | python3 -c "
import sys,json
for z in json.load(sys.stdin)['ZoneSet']:
    print(f\"{z['Zone']:20} {z['ZoneState']:10} {z.get('ZoneName','')}\")
"

# 查询腾讯云官方 Ubuntu 24.04 镜像 ID
# 注意：filter 必须精确匹配官方镜像名，否则会匹配到第三方市场镜像（如 "OpenClaw on Ubuntu 24.04"）
tccli cvm DescribeImages --region ap-guangzhou \
  --Filters '[{"Name":"image-name","Values":["Ubuntu Server 24.04 LTS 64"]},{"Name":"image-type","Values":["PUBLIC_IMAGE"]}]' \
  | python3 -c "import sys,json; imgs=json.load(sys.stdin)['ImageSet']; [print(f\"{i['ImageId']}  {i['ImageName']}\") for i in imgs]"

# 查询默认安全组 ID
tccli vpc DescribeSecurityGroups --region ap-guangzhou \
  --Filters '[{"Name":"is-default","Values":["true"]}]' \
  | python3 -c "import sys,json; sgs=json.load(sys.stdin)['SecurityGroupSet']; print(sgs[0]['SecurityGroupId'] if sgs else 'NONE')"

# 创建竞价实例（注意 Zone 用 ap-guangzhou-6，S5.MEDIUM4 在 6 区有库存）
tccli cvm RunInstances \
  --region ap-guangzhou \
  --InstanceChargeType SPOTPAID \
  --InstanceMarketOptions '{"MarketType":"spot","SpotOptions":{"MaxPrice":"0.5","SpotInstanceType":"one-time"}}' \
  --Placement '{"Zone":"ap-guangzhou-6"}' \
  --InstanceType S5.MEDIUM4 \
  --ImageId <镜像ID> \
  --SystemDisk '{"DiskType":"CLOUD_SSD","DiskSize":50}' \
  --InternetAccessible '{"InternetChargeType":"TRAFFIC_POSTPAID_BY_HOUR","InternetMaxBandwidthOut":10,"PublicIpAssigned":true}' \
  --LoginSettings '{"KeyIds":["<你的SSH密钥ID>"]}' \
  --SecurityGroupIds '["<安全组ID>"]' \
  --InstanceName k8s-learning \
  --HostName k8s-learning

# 等待实例 running 后查看公网 IP
tccli cvm DescribeInstances --region ap-guangzhou \
  --Filters '[{"Name":"instance-name","Values":["k8s-learning"]}]' \
  | python3 -c "import sys,json; ins=json.load(sys.stdin)['InstanceSet']; print(f'IP: {ins[0][\"PublicIpAddresses\"][0]}') if ins else print('NOT FOUND')"
```

> 也可以直接在 [腾讯云 CVM 控制台](https://console.cloud.tencent.com/cvm) 页面手动购买竞价实例，更直观。
> 控制台购买时记得选择你的 SSH 密钥，否则只能用密码登录。

### 1.5 配置安全组（防火墙）

在腾讯云控制台 → 安全组，添加以下入站规则：

| 端口 | 协议 | 来源 | 用途 |
|------|------|------|------|
| 22 | TCP | 0.0.0.0/0 | SSH 登录 |
| 80 | TCP | 0.0.0.0/0 | HTTP (Ingress) |
| 443 | TCP | 0.0.0.0/0 | HTTPS (Ingress) |
| 6443 | TCP | 0.0.0.0/0 | K8s API Server（本地 kubectl 远程连接） |
| 30000-32767 | TCP | 0.0.0.0/0 | NodePort 范围 |

> 也可以用 tccli 操作安全组，但控制台操作更直观。安全组只需配置一次，后续重建实例可以复用同一个安全组。

---

## Step 2: SSH 登录 & 基础配置

### 2.1 连接到服务器

```bash
# SSH 连接（使用密钥）
ssh -i ~/.ssh/<你的密钥>.pem ubuntu@<公网IP>

# 或者使用密码（购买时设置的）
ssh ubuntu@<公网IP>
```

> 公网 IP 在腾讯云控制台 CVM 实例列表可以看到，或者用 `tccli cvm DescribeInstances` 查询。

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

# 配置 Docker 镜像加速器（国内网络必须，否则拉取 docker.io 镜像超时）
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json << 'EOF'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me"
  ]
}
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker

# 验证安装
docker --version
# Docker version 27.x.x, build xxxxxxx

# 使组权限生效（需要重新登录，或在当前 session 用 sg 刷新）
exit
```

**重新登录** SSH 后验证：

```bash
# 不带 sudo 运行 docker，确认组权限生效
docker run --rm hello-world
# 看到Hello from Docker!就说明OK
```

> **为什么需要镜像加速器？** 国内网络访问 docker.io（Docker Hub）经常超时或极慢。
> 配置 `registry-mirrors` 后，Docker 会自动从镜像站拉取，速度大幅提升。
> 如果你的网络能直连 Docker Hub，可以跳过 `daemon.json` 配置。

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
# 下载指定版本（与 kind 集群的 K8s 版本保持一致）
curl -LO "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl"

# 赋予执行权限
chmod +x kubectl

# 移动到 PATH
sudo mv kubectl /usr/local/bin/

# 验证
kubectl version --client
# Client Version: v1.31.0
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

将 `kind-cluster.yaml` 上传到 CVM 服务器（或直接在服务器上创建）：

```bash
cat > ~/kind-cluster.yaml << 'EOF'
# kind 集群配置文件
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  # 控制面节点：运行 K8s 的核心组件
  - role: control-plane
    # 把容器的端口映射到宿主机，让外部可以访问
    extraPortMappings:
      # Ingress 流量
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
      # K8s API Server：本地 kubectl 远程连接需要此端口
      # listenAddress 必须设为 "0.0.0.0"，否则默认只绑 127.0.0.1，外部访问不到
      - containerPort: 6443
        hostPort: 6443
        protocol: TCP
        listenAddress: "0.0.0.0"

  # 工作节点：跑你的应用 Pod
  - role: worker

  # 第二个工作节点：可以练习多节点调度
  - role: worker

# 国内网络必须配置：kind 节点内的 containerd 需要拉取 registry.k8s.io 的镜像
# （如 Ingress Controller、CoreDNS 等），不配置会导致 ImagePullBackOff
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."registry.k8s.io"]
      endpoint = ["https://k8s.m.daocloud.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
      endpoint = ["https://docker.1ms.run"]
EOF
```

> **关键**：`containerdConfigPatches` 是国内环境的"必选项"。
> kind 集群内每个节点跑的是 containerd（不是 Docker），它拉镜像走的不是上面配的 Docker mirror。
> 这个配置让集群内 containerd 也走镜像加速，否则 Ingress Controller 等组件会因 `registry.k8s.io` 超时而无法启动。

### 6.2 创建集群

```bash
# 创建集群（需要几分钟，主要时间花在拉取镜像上）
# 注意：如果通过 SSH 管道执行，建议用 sudo kind 避免 docker 组权限问题
sudo kind create cluster --name k8s-learning --config ~/kind-cluster.yaml

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

# 注意：sudo kind 把 kubeconfig 写入 /root/.kube/config
# 如果需要用 ubuntu 用户执行 kubectl，需要复制过来：
sudo mkdir -p /home/ubuntu/.kube
sudo cp /root/.kube/config /home/ubuntu/.kube/config
sudo chown -R ubuntu:ubuntu /home/ubuntu/.kube
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

这一步让你能在**自己电脑上**直接用 kubectl 操作远程 CVM 上的集群，
这是更贴近真实工作场景的方式。

> **前提**：Step 6 的 kind-cluster.yaml 必须包含 6443 端口映射 + `listenAddress: "0.0.0.0"`，
> 并且安全组已放行 6443 端口。否则本地 kubectl 连不上。

### 8.1 从 CVM 获取 kubeconfig

```bash
# 从远程服务器获取 kubeconfig（sudo kind 的 kubeconfig 在 /root 下）
# 替换 <CVM公网IP> 为你的实际 IP
ssh -i ~/.ssh/id_rsa ubuntu@<CVM公网IP> \
    "sudo kind get kubeconfig --name k8s-learning" \
    > ~/.kube/k8s-learning-config
```

### 8.2 替换 server 地址为公网 IP

kind 生成的 kubeconfig 里 server 地址是 `127.0.0.1:6443` 或 `0.0.0.0:6443`，
需要改成 CVM 的公网 IP 才能从本机访问：

```bash
# 替换 IP 地址
sed -i 's/127\.0\.0\.1/<CVM公网IP>/g' ~/.kube/k8s-learning-config
sed -i 's/0\.0\.0\.0/<CVM公网IP>/g' ~/.kube/k8s-learning-config

# 确认 server 地址已改
grep 'server:' ~/.kube/k8s-learning-config | head -1
# 应该输出：server: https://<CVM公网IP>:6443
```

### 8.3 跳过 TLS 证书校验

kind 生成的 API Server 证书只包含内部 IP（127.0.0.1、172.x.x.x），
不包含你的公网 IP，所以 kubectl 会报 TLS 错误。
需要设置 `insecure-skip-tls-verify` 跳过证书校验：

> 学习环境可以这样做。生产环境绝不能跳过证书校验。

```bash
KUBECONFIG=~/.kube/k8s-learning-config kubectl config set-cluster kind-k8s-learning --insecure-skip-tls-verify=true
```

### 8.4 验证连接

```bash
KUBECONFIG=~/.kube/k8s-learning-config kubectl get nodes
# 应该能看到 3 个节点
```

### 8.5 日常使用

```bash
# 方式一：设置环境变量（推荐，加到 ~/.bashrc 里）
export KUBECONFIG=~/.kube/k8s-learning-config
kubectl get nodes

# 方式二：每次指定
kubectl --kubeconfig ~/.kube/k8s-learning-config get nodes

# 方式三：合并到默认 kubeconfig
KUBECONFIG=~/.kube/config:~/.kube/k8s-learning-config kubectl config view --flatten > ~/.kube/config.tmp
mv ~/.kube/config.tmp ~/.kube/config
```

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
外部请求 → CVM公网IP:80 → Docker映射 → kind control-plane:80 → Ingress Controller → Pod
```

---

## 一键操作（用脚本）

上面的 Step 1-9 已经封装成脚本，可以一键执行：

```bash
# Step 1: 创建 CVM + 自动绑定 SSH 密钥 + 配置安全组
./scripts/provision.sh create --yes

# Step 2: 在 CVM 上搭建集群（通过 SSH 管道执行）
# 脚本会自动安装 Docker/kind/kubectl + 创建集群 + 安装 Ingress
ssh -i ~/.ssh/id_rsa ubuntu@<公网IP> 'bash -s' < scripts/setup-server.sh

# Step 3: 本地连接集群（自动获取 kubeconfig + 替换 IP + 跳过 TLS 校验）
./scripts/setup-local.sh <公网IP> ~/.ssh/id_rsa
```

> 脚本已经处理了以下坑：
> - 自动绑定 SSH 密钥（停机 → 绑定 → 开机）
> - 自动创建/配置安全组（22, 80, 443, 6443, 30000-32767）
> - `DEBIAN_FRONTEND=noninteractive` 避免 apt 交互提示卡住
> - Docker 镜像加速器配置（国内网络必须）
> - kind containerd 镜像加速（国内网络必须）
> - `sudo kind` 解决 SSH session 中 docker 组权限不生效的问题
> - kind-cluster.yaml 中 6443 端口 `listenAddress: "0.0.0.0"` 让外部可访问 API Server
> - `insecure-skip-tls-verify` 解决 kind 证书不包含公网 IP 的问题

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

### CVM 管理

```bash
# 用 tccli 查看实例
tccli cvm DescribeInstances --region ap-guangzhou

# 用 tccli 销毁实例（停止计费）
tccli cvm TerminateInstances --InstanceIds '["ins-xxx"]'

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

### 问题：kind create cluster 报 permission denied (docker socket)

通过 SSH 执行时，当前 session 没有 docker 组权限（`usermod -aG docker` 需要重新登录才生效）。

```bash
# 解决：使用 sudo 运行 kind
sudo kind create cluster --name k8s-learning --config ~/kind-cluster.yaml

# 注意：sudo kind 会把 kubeconfig 写入 /root/.kube/config
# 需要复制到 ubuntu 用户：
sudo mkdir -p /home/ubuntu/.kube
sudo cp /root/.kube/config /home/ubuntu/.kube/config
sudo chown -R ubuntu:ubuntu /home/ubuntu/.kube
```

### 问题：kind create cluster 卡在 pull image / 报 i/o timeout

国内网络拉取 docker.io 镜像超时。需要配置 Docker 镜像加速器：

```bash
# 确认 /etc/docker/daemon.json 已配置
cat /etc/docker/daemon.json
# 应该包含 registry-mirrors

# 如果没有，手动配置：
sudo tee /etc/docker/daemon.json << 'EOF'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me"
  ]
}
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker
```

### 问题：Ingress Controller Pod 报 ImagePullBackOff

集群内 containerd 拉取 `registry.k8s.io` 镜像失败（Docker 镜像加速器不管这个）。

```bash
# 查看 Pod 事件，确认是 registry.k8s.io 超时
kubectl describe pod -n ingress-nginx <pod-name> | grep -A5 Events

# 解决：kind-cluster.yaml 必须包含 containerdConfigPatches（见 Step 6.1）
# 如果已经创建了集群没配，需要删除重建：
kind delete cluster --name k8s-learning
# 用包含 containerdConfigPatches 的配置重新创建
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
# 1. 检查安全组是否放行了 6443 端口
#    在腾讯云控制台 → 安全组 → 入站规则 查看

# 2. 检查 kind 端口绑定（在 CVM 上执行）
ssh ubuntu@<IP> 'sudo ss -tlnp | grep 6443'
# 应该看到 0.0.0.0:6443，如果是 127.0.0.1:6443 说明 kind-cluster.yaml 没有 listenAddress

# 3. 检查 kubeconfig 中的 server 地址
grep 'server:' ~/.kube/k8s-learning-config
# 应该是 https://<公网IP>:6443

# 4. 如果报 TLS/certificate 错误（x509: certificate is valid for ... not <IP>）
#    说明没有设置 insecure-skip-tls-verify：
KUBECONFIG=~/.kube/k8s-learning-config kubectl config set-cluster kind-k8s-learning --insecure-skip-tls-verify=true
```

### 问题：SSH 管道执行 apt 卡在交互提示

```bash
# 如 ssh ... 'bash -s' < setup-server.sh 时卡在 sshd_config 配置选择
# 解决：脚本开头必须加
export DEBIAN_FRONTEND=noninteractive

# 当前 setup-server.sh 已包含此配置
```

### 问题：内存不足，Pod 一直 Pending

```bash
# 查看节点资源使用
kubectl describe nodes | grep -A 5 "Allocated resources"

# 如果确实不够，两个选择：
# 1. 减少节点数（改 kind config 为单节点）
# 2. 换更大规格的 CVM
```

### 问题：竞价实例被回收

```bash
# 竞价实例被系统回收后，数据会丢失
# 处理方法：用脚本重新创建实例 + 重建集群
./scripts/provision.sh                    # 重新创建实例
ssh ubuntu@<新IP> 'bash -s' < scripts/setup-server.sh  # 重建集群
./scripts/setup-local.sh <新IP> <密钥>    # 重新连接
```

---

## 清理（学完要销毁环境时）

```bash
# 在 CVM 上删除 kind 集群
kind delete cluster --name k8s-learning

# 用 tccli 销毁 CVM 实例（停止计费）
tccli cvm TerminateInstances --InstanceIds '["ins-xxx"]'

# 或在腾讯云控制台 → CVM → 选择实例 → 销毁/退还
```

> 竞价实例按秒计费，销毁后立即停止扣费。安全组、SSH 密钥等配置可以保留，下次创建新实例时复用。

---

下一个 → [Chapter 01 - Pod 基础](../chapter01-pod-basics/01-first-pod/)
