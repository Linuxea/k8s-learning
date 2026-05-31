#!/usr/bin/env bash
# ============================================================
# setup-local.sh — 配置本地 kubectl 远程连接 Lightsail 上的集群
#
# 用法:
#   ./scripts/setup-local.sh <公网IP> <SSH密钥路径> [区域]
#   ./scripts/setup-local.sh 12.34.56.78 ~/.ssh/lightsail_ap-northeast-1.pem
#
# 前置: setup-server.sh 已在服务器上执行完成
# ============================================================

set -euo pipefail

PUBLIC_IP="${1:?用法: $0 <公网IP> <SSH密钥路径> [区域]}"
SSH_KEY="${2:?用法: $0 <公网IP> <SSH密钥路径> [区域]}"
REGION="${3:-ap-northeast-1}"
CLUSTER_NAME="k8s-learning"
KUBECONFIG_FILE="$HOME/.kube/k8s-learning-config"

echo "========================================="
echo "  配置本地 kubectl 远程连接"
echo "  Server: ${PUBLIC_IP}"
echo "========================================="

# ---------- 1. 从服务器获取 kubeconfig ----------
echo ""
echo ">>> [1/3] 从服务器获取 kubeconfig..."
mkdir -p "$HOME/.kube"

ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new ubuntu@"${PUBLIC_IP}" \
    "kind get kubeconfig --name ${CLUSTER_NAME}" \
    > "${KUBECONFIG_FILE}"

echo "  ✅ kubeconfig 已下载到 ${KUBECONFIG_FILE}"

# ---------- 2. 替换 127.0.0.1 为公网 IP ----------
echo ""
echo ">>> [2/3] 替换 server 地址为公网 IP..."

# kind 的 kubeconfig 里 server 地址是 127.0.0.1:PORT
# 需要改成 Lightsail 公网 IP:PORT 才能从本机访问
sed -i "s/127\.0\.0\.1/${PUBLIC_IP}/g" "${KUBECONFIG_FILE}"

SERVER=$(grep 'server:' "${KUBECONFIG_FILE}" | head -1 | awk '{print $2}')
echo "  Server 地址: ${SERVER}"

# 提取端口，提示用户确认防火墙
PORT=$(echo "${SERVER}" | sed 's|.*:||')
echo "  端口: ${PORT}"
echo "  ⚠️  确保 Lightsail 防火墙已放行此端口（${PORT}/tcp）"

# ---------- 3. 验证连接 ----------
echo ""
echo ">>> [3/3] 验证连接..."
export KUBECONFIG="${KUBECONFIG_FILE}"

if kubectl get nodes &>/dev/null; then
    echo "  ✅ 连接成功!"
    echo ""
    kubectl get nodes
else
    echo "  ❌ 连接失败"
    echo ""
    echo "  排查:"
    echo "    1. 防火墙是否放行了端口 ${PORT}/tcp"
    echo "    2. 测试连通: curl -k ${SERVER}/livez"
    echo "    3. 检查 IP: grep server ${KUBECONFIG_FILE}"
    exit 1
fi

# ---------- 使用提示 ----------
echo ""
echo "========================================="
echo "  ✅ 配置完成!"
echo "========================================="
echo ""
echo "  使用方式:"
echo "    # 方式一: 设置环境变量"
echo "    export KUBECONFIG=${KUBECONFIG_FILE}"
echo "    kubectl get nodes"
echo ""
echo "    # 方式二: 每次指定"
echo "    kubectl --kubeconfig ${KUBECONFIG_FILE} get nodes"
echo ""
echo "    # 方式三: 合并到默认 kubeconfig"
echo "    KUBECONFIG=~/.kube/config:${KUBECONFIG_FILE} kubectl config view --flatten > ~/.kube/config.merged"
echo "    mv ~/.kube/config.merged ~/.kube/config"
