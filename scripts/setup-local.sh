#!/usr/bin/env bash
# ============================================================
# setup-local.sh — 配置本地 kubectl 远程连接 CVM 上的集群
#
# 用法:
#   ./scripts/setup-local.sh <公网IP> <SSH密钥路径>
#   ./scripts/setup-local.sh 12.34.56.78 ~/.ssh/id_rsa
#
# 前置: setup-server.sh 已在服务器上执行完成
# ============================================================

set -euo pipefail

PUBLIC_IP="${1:?用法: $0 <公网IP> <SSH密钥路径> [区域]}"
SSH_KEY="${2:?用法: $0 <公网IP> <SSH密钥路径>}"
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

# sudo kind 创建的集群，kubeconfig 在 /root/.kube/config
# 需要用 sudo kind get kubeconfig 或直接读 /root/.kube/config
# 这里用 sudo kind get kubeconfig 获取（会把 127.0.0.1 替换为实际绑定地址）
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new ubuntu@"${PUBLIC_IP}" \
    "sudo kind get kubeconfig --name ${CLUSTER_NAME}" \
    > "${KUBECONFIG_FILE}"

echo "  ✅ kubeconfig 已下载到 ${KUBECONFIG_FILE}"

# ---------- 2. 替换 127.0.0.1 为公网 IP ----------
echo ""
echo ">>> [2/3] 替换 server 地址为公网 IP..."

# kind 的 kubeconfig 里 server 地址可能是 0.0.0.0:6443 或 127.0.0.1:6443
# 需要改成 CVM 公网 IP 才能从本机访问
sed -i "s/127\.0\.0\.1/${PUBLIC_IP}/g" "${KUBECONFIG_FILE}"
sed -i "s/0\.0\.0\.0/${PUBLIC_IP}/g" "${KUBECONFIG_FILE}"

SERVER=$(grep 'server:' "${KUBECONFIG_FILE}" | head -1 | awk '{print $2}')
echo "  Server 地址: ${SERVER}"

# kind 生成的 API Server 证书 SAN 里只有 127.0.0.1 和内部 IP，没有公网 IP
# 所以必须跳过 TLS 证书校验（学习环境可以接受，生产环境不要这样做）
KUBECONFIG="${KUBECONFIG_FILE}" kubectl config set-cluster "kind-${CLUSTER_NAME}" --insecure-skip-tls-verify=true 2>/dev/null
echo "  ✅ 已设置 insecure-skip-tls-verify（因为 kind 证书不包含公网 IP）"

# 提取端口，提示用户确认防火墙
PORT=$(echo "${SERVER}" | sed 's|.*:||')
echo "  端口: ${PORT}"
echo "  ⚠️  确保腾讯云安全组已放行此端口（${PORT}/tcp）"

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
    echo "    1. 腾讯云安全组是否放行了端口 ${PORT}/tcp"
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
