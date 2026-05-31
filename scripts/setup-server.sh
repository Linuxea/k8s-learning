#!/usr/bin/env bash
# ============================================================
# setup-server.sh — 在 Lightsail 上一键搭建 K8s 学习环境
#
# 这个脚本设计为通过 SSH 管道执行:
#   ssh -i <key.pem> ubuntu@<IP> 'bash -s' < scripts/setup-server.sh
#
# 或者先 scp 上去再执行:
#   scp -i <key.pem> scripts/setup-server.sh ubuntu@<IP>:~
#   ssh -i <key.pem> ubuntu@<IP> 'bash setup-server.sh'
#
# 包含: Docker + kind + kubectl + 创建集群 + Ingress Controller
# 重复运行安全（已安装的会跳过）
# ============================================================

set -euo pipefail

CLUSTER_NAME="k8s-learning"
KIND_VERSION="v0.24.0"
K8S_VERSION="v1.31.0"

echo "========================================="
echo "  K8s Learning Env Setup"
echo "  Cluster: ${CLUSTER_NAME}"
echo "  Kind:    ${KIND_VERSION}"
echo "  K8s:     ${K8S_VERSION}"
echo "========================================="

# ---------- 1. 系统更新 ----------
echo ""
echo ">>> [1/7] 系统更新..."
sudo apt-get update -qq && sudo apt-get upgrade -y -qq

# ---------- 2. 安装 Docker ----------
echo ""
echo ">>> [2/7] 安装 Docker..."
if command -v docker &>/dev/null; then
    echo "  Docker 已安装: $(docker --version)"
else
    sudo apt-get install -y -qq docker.io
    sudo systemctl enable docker
    sudo systemctl start docker
    sudo usermod -aG docker ubuntu
    echo "  ✅ Docker 安装完成"
    echo "  ⚠️  需要重新登录 SSH 让 docker 组权限生效"
    echo "  正在通过 newgrp 刷新组权限..."
    sg docker -c "echo '  docker 组权限已刷新'"
fi

# ---------- 3. 安装 kind ----------
echo ""
echo ">>> [3/7] 安装 kind..."
if command -v kind &>/dev/null; then
    echo "  kind 已安装: $(kind version)"
else
    curl -sLo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/
    echo "  ✅ kind ${KIND_VERSION} 安装完成"
fi

# ---------- 4. 安装 kubectl ----------
echo ""
echo ">>> [4/7] 安装 kubectl..."
if command -v kubectl &>/dev/null; then
    echo "  kubectl 已安装: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
else
    curl -sLO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    echo "  ✅ kubectl ${K8S_VERSION} 安装完成"
fi

# ---------- 5. 创建 kind 集群 ----------
echo ""
echo ">>> [5/7] 创建 kind 集群..."

# 检查集群是否已存在
if kind get clusters 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
    echo "  集群 ${CLUSTER_NAME} 已存在，跳过创建"
else
    # 写入集群配置文件
    cat > ~/kind-cluster.yaml << 'KINDEOF'
# kind 集群配置 — 3 节点（1 control-plane + 2 worker）
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
  - role: worker
  - role: worker
KINDEOF

    echo "  正在创建集群（需要几分钟拉取镜像）..."
    kind create cluster \
        --name "${CLUSTER_NAME}" \
        --image "kindest/node:${K8S_VERSION}" \
        --config ~/kind-cluster.yaml \
        --wait 300s
    echo "  ✅ 集群创建完成"
fi

# ---------- 6. 验证集群 ----------
echo ""
echo ">>> [6/7] 验证集群..."
kubectl get nodes
echo ""

# ---------- 7. 安装 Ingress Controller ----------
echo ""
echo ">>> [7/7] 安装 NGINX Ingress Controller..."

# 检查是否已安装
if kubectl get namespace ingress-nginx &>/dev/null 2>&1; then
    echo "  Ingress 已存在，跳过安装"
else
    echo "  正在安装（需要拉取镜像）..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

    echo "  等待 Ingress Controller 就绪..."
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=180s
    echo "  ✅ Ingress Controller 就绪"
fi

# ---------- 完成 ----------
echo ""
echo "========================================="
echo "  ✅ 全部完成!"
echo "========================================="
echo ""
echo "  集群节点:"
kubectl get nodes -o wide
echo ""
echo "  下一步: 在本机运行以下命令连接集群"
echo "    ./scripts/setup-local.sh < Lightsail 公网 IP>"
echo ""
