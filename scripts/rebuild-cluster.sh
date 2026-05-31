#!/usr/bin/env bash
# ============================================================
# rebuild-cluster.sh — 销毁并重建 kind 集群（保留 Docker/kind/kubectl）
#
# 用法（通过 SSH 管道执行）:
#   ssh -i <key.pem> ubuntu@<IP> 'bash -s' < scripts/rebuild-cluster.sh
#
# 适用场景:
#   - 学完一小节想重置集群
#   - 集群状态乱了想重来
#   - 保留服务器上的工具，只重建集群
# ============================================================

set -euo pipefail

CLUSTER_NAME="k8s-learning"
K8S_VERSION="v1.31.0"

echo "========================================="
echo "  重建 kind 集群: ${CLUSTER_NAME}"
echo "========================================="

# ---------- 1. 销毁旧集群 ----------
echo ""
echo ">>> [1/3] 销毁旧集群..."
if kind get clusters 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
    kind delete cluster --name "${CLUSTER_NAME}"
    echo "  ✅ 旧集群已销毁"
else
    echo "  无旧集群，跳过"
fi

# ---------- 2. 创建新集群 ----------
echo ""
echo ">>> [2/3] 创建新集群..."

cat > ~/kind-cluster.yaml << 'KINDEOF'
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

kind create cluster \
    --name "${CLUSTER_NAME}" \
    --image "kindest/node:${K8S_VERSION}" \
    --config ~/kind-cluster.yaml \
    --wait 300s
echo "  ✅ 新集群创建完成"

# ---------- 3. 安装 Ingress ----------
echo ""
echo ">>> [3/3] 安装 Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=180s
echo "  ✅ Ingress Controller 就绪"

# ---------- 完成 ----------
echo ""
echo "========================================="
echo "  ✅ 集群重建完成!"
echo "========================================="
kubectl get nodes
echo ""
echo "⚠️  如果使用了 setup-local.sh，需重新运行以获取新的 kubeconfig"
echo "   （kind 重建后证书和端口会变）"
