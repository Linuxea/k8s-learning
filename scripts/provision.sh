#!/usr/bin/env bash
# ============================================================
# provision.sh — 用 tccli 创建腾讯云 CVM 竞价实例
#
# 用法:
#   ./scripts/provision.sh create              # 创建竞价实例（交互式）
#   ./scripts/provision.sh create --yes        # 创建（跳过确认）
#   ./scripts/provision.sh info                # 查看实例信息（获取 IP）
#
# 销毁直接用 tccli 或控制台:
#   tccli cvm TerminateInstances --InstanceIds '["ins-xxx"]'
#
# 前置: tccli 已安装并配置好密钥 (tccli configure)
# ============================================================

set -euo pipefail

# ---------- 配置 ----------
REGION="ap-guangzhou"
ZONE="ap-guangzhou-3"
INSTANCE_NAME="k8s-learning"
INSTANCE_TYPE="S5.MEDIUM4"        # 2 vCPU / 4GB RAM
SYSTEM_DISK_SIZE=50
SYSTEM_DISK_TYPE="CLOUD_SSD"
MAX_PRICE="0.5"                   # 竞价最高出价（元/小时）
BANDWIDTH=10                      # 公网带宽上限 (Mbps)

# ---------- 辅助函数 ----------

get_instance_id() {
    tccli cvm DescribeInstances --region "${REGION}" \
        --Filters '[{"Name":"instance-name","Values":["'"${INSTANCE_NAME}"'"]}]' \
        --query 'InstanceSet[0].InstanceId' \
        --output text 2>/dev/null
}

get_instance_ip() {
    tccli cvm DescribeInstances --region "${REGION}" \
        --Filters '[{"Name":"instance-name","Values":["'"${INSTANCE_NAME}"'"]}]' \
        --query 'InstanceSet[0].PublicIpAddresses[0]' \
        --output text 2>/dev/null
}

get_instance_status() {
    tccli cvm DescribeInstances --region "${REGION}" \
        --Filters '[{"Name":"instance-name","Values":["'"${INSTANCE_NAME}"'"]}]' \
        --query 'InstanceSet[0].InstanceState' \
        --output text 2>/dev/null
}

# ---------- 子命令: info ----------

cmd_info() {
    echo "========================================="
    echo "  实例信息: ${INSTANCE_NAME}"
    echo "========================================="

    local instance_id
    instance_id=$(get_instance_id)

    if [[ -z "${instance_id}" || "${instance_id}" == "None" ]]; then
        echo "  ❌ 实例不存在"
        exit 0
    fi

    local ip status
    ip=$(get_instance_ip)
    status=$(get_instance_status)

    echo "  实例 ID:  ${instance_id}"
    echo "  公网 IP:  ${ip}"
    echo "  状态:     ${status}"
    echo ""
    echo "  SSH 连接:"
    echo "    ssh ubuntu@${ip}"
}

# ---------- 子命令: create ----------

cmd_create() {
    echo "========================================="
    echo "  创建 CVM 竞价实例"
    echo "========================================="
    echo "  区域:       ${REGION} (${ZONE})"
    echo "  实例名:     ${INSTANCE_NAME}"
    echo "  规格:       ${INSTANCE_TYPE} (2C4G)"
    echo "  系统盘:     ${SYSTEM_DISK_SIZE}GB ${SYSTEM_DISK_TYPE}"
    echo "  最高出价:   ${MAX_PRICE} 元/小时"
    echo "  带宽:       ${BANDWIDTH} Mbps"
    echo "========================================="

    # 检查是否已存在
    local existing_id
    existing_id=$(get_instance_id)
    if [[ -n "${existing_id}" && "${existing_id}" != "None" ]]; then
        echo ""
        echo "❌ 实例 ${INSTANCE_NAME} 已存在 (ID: ${existing_id})"
        echo "   如需重建，先运行: ./scripts/provision.sh destroy"
        exit 1
    fi

    # 确认
    if [[ "${1:-}" != "--yes" ]]; then
        echo ""
        read -p "确认创建？(y/N) " confirm
        if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
            echo "已取消"
            exit 0
        fi
    fi

    # 查询 Ubuntu 24.04 镜像 ID
    echo ""
    echo ">>> 查询 Ubuntu 24.04 镜像..."
    local image_id
    image_id=$(tccli cvm DescribeImages --region "${REGION}" \
        --Filters '[{"Name":"image-name","Values":["Ubuntu 24.04"]},{"Name":"image-type","Values":["PUBLIC_IMAGE"]}]' \
        --query 'ImageSet[0].ImageId' \
        --output text 2>/dev/null)

    if [[ -z "${image_id}" || "${image_id}" == "None" ]]; then
        echo "❌ 未找到 Ubuntu 24.04 镜像，请手动指定 --ImageId"
        echo "   可用以下命令查询:"
        echo "   tccli cvm DescribeImages --region ${REGION} --Filters '[{\"Name\":\"image-name\",\"Values\":[\"Ubuntu 24\"]}]'"
        exit 1
    fi
    echo "  镜像 ID: ${image_id}"

    # 查询默认安全组
    echo ">>> 查询安全组..."
    local sg_id
    sg_id=$(tccli vpc DescribeSecurityGroups --region "${REGION}" \
        --Filters '[{"Name":"is-default","Values":["true"]}]' \
        --query 'SecurityGroupSet[0].SecurityGroupId' \
        --output text 2>/dev/null)

    if [[ -n "${sg_id}" && "${sg_id}" != "None" ]]; then
        echo "  默认安全组: ${sg_id}"
    else
        echo "  ⚠️  未找到默认安全组，将不指定安全组（使用默认放通）"
        sg_id=""
    fi

    # 查询 SSH 密钥
    echo ">>> 查询 SSH 密钥..."
    local key_id
    key_id=$(tccli cvm DescribeKeyPairs --region "${REGION}" \
        --query 'KeySet[0].KeyId' \
        --output text 2>/dev/null)

    if [[ -n "${key_id}" && "${key_id}" != "None" ]]; then
        echo "  SSH 密钥: ${key_id}"
    else
        echo "  ⚠️  未找到 SSH 密钥，将使用密码登录"
        key_id=""
    fi

    # 构建创建参数
    echo ""
    echo ">>> 创建竞价实例..."

    local login_settings
    local run_args=(
        --InstanceChargeType SPOTPAID
        --InstanceMarketOptions "{\"MarketType\":\"spot\",\"SpotOptions\":{\"MaxPrice\":\"${MAX_PRICE}\",\"SpotInstanceType\":\"one-time\"}}"
        --Placement "{\"Zone\":\"${ZONE}\"}"
        --InstanceType "${INSTANCE_TYPE}"
        --ImageId "${image_id}"
        --SystemDisk "{\"DiskType\":\"${SYSTEM_DISK_TYPE}\",\"DiskSize\":${SYSTEM_DISK_SIZE}}"
        --InternetAccessible "{\"InternetChargeType\":\"TRAFFIC_POSTPAID_BY_HOUR\",\"InternetMaxBandwidthOut\":${BANDWIDTH},\"PublicIpAssigned\":true}"
        --InstanceCount 1
        --InstanceName "${INSTANCE_NAME}"
        --HostName "k8s-learning"
    )

    if [[ -n "${key_id}" && "${key_id}" != "None" ]]; then
        run_args+=(--LoginSettings "{\"KeyIds\":[\"${key_id}\"]}")
    fi

    if [[ -n "${sg_id}" && "${sg_id}" != "None" ]]; then
        run_args+=(--SecurityGroupIds "[\"${sg_id}\"]")
    fi

    local result
    result=$(tccli cvm RunInstances --region "${REGION}" "${run_args[@]}" 2>&1) || {
        echo "❌ 创建失败:"
        echo "${result}"
        exit 1
    }

    local instance_id
    instance_id=$(echo "${result}" | python3 -c "import sys,json; print(json.load(sys.stdin)['InstanceIdSet'][0])" 2>/dev/null || echo "")

    if [[ -z "${instance_id}" ]]; then
        echo "❌ 创建可能失败，请检查控制台"
        echo "${result}"
        exit 1
    fi

    echo "  实例 ID: ${instance_id}"

    # 等待实例就绪
    echo ""
    echo ">>> 等待实例 running..."
    for i in $(seq 1 30); do
        local status
        status=$(get_instance_status)
        if [[ "${status}" == "RUNNING" ]]; then
            echo "  ✅ 实例已 running!"
            break
        fi
        echo "  (${i}/30) 状态: ${status}..."
        sleep 10
    done

    local public_ip
    public_ip=$(get_instance_ip)

    echo ""
    echo "========================================="
    echo "  ✅ 实例创建成功!"
    echo "========================================="
    echo "  实例 ID:  ${instance_id}"
    echo "  公网 IP:  ${public_ip}"
    echo "========================================="
    echo ""
    echo "下一步:"
    echo "  1. 确保安全组已放行: 22, 80, 443"
    echo "  2. 在服务器上搭建集群:"
    echo "     ssh ubuntu@${public_ip} 'bash -s' < scripts/setup-server.sh"
    echo ""
    echo "  3. 本地连接集群:"
    echo "     ./scripts/setup-local.sh ${public_ip} <SSH密钥路径>"
    echo ""
    echo "销毁实例:"
    echo "  tccli cvm TerminateInstances --region ${REGION} --InstanceIds '[\"<实例ID>\"]'"
    echo "  或在腾讯云控制台操作"
}

# ---------- 主入口 ----------

case "${1:-help}" in
    create)
        cmd_create "${2:-}"
        ;;
    info)
        cmd_info
        ;;
    *)
        echo "用法: $0 {create|info}"
        echo ""
        echo "  create   创建竞价实例"
        echo "  info     查看实例信息（获取 IP）"
        ;;
esac
