#!/usr/bin/env bash
# ============================================================
# destroy-cluster.sh — 仅删除 kind 集群（保留 Docker/kind/kubectl）
#
# 用法:
#   ssh -i <key.pem> ubuntu@<IP> 'bash -s' < scripts/destroy-cluster.sh
# ============================================================

set -euo pipefail

CLUSTER_NAME="k8s-learning"

echo "🗑️  销毁 kind 集群: ${CLUSTER_NAME}"

if kind get clusters 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
    kind delete cluster --name "${CLUSTER_NAME}"
    echo "✅ 集群已销毁"
else
    echo "集群不存在，无需销毁"
fi

echo ""
echo "Docker/kind/kubectl 仍保留在服务器上"
echo "需要重建时运行: ssh ... 'bash -s' < scripts/rebuild-cluster.sh"
