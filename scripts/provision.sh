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
ZONE="ap-guangzhou-6"
INSTANCE_NAME="k8s-learning"
INSTANCE_TYPE="S5.MEDIUM4"        # 2 vCPU / 4GB RAM
SYSTEM_DISK_SIZE=50
SYSTEM_DISK_TYPE="CLOUD_SSD"
MAX_PRICE="0.5"                   # 竞价最高出价（元/小时）
BANDWIDTH=10                      # 公网带宽上限 (Mbps)

# ---------- 辅助函数 ----------

# tccli 不支持 --query/--output text（那是 AWS CLI 的语法），用 python3 解析 JSON
# 用法: extract_json '<json>' '<python expr>'，如 extract_json "$raw" "d['InstanceSet'][0]['InstanceId']"
extract_json() {
    python3 -c "import sys,json; d=json.loads('''$1'''); print($2)" 2>/dev/null || echo ""
}

get_instance_id() {
    local raw
    raw=$(tccli cvm DescribeInstances --region "${REGION}" \
        --Filters '[{"Name":"instance-name","Values":["'"${INSTANCE_NAME}"'"]}]' 2>/dev/null || echo "{}")
    extract_json "$raw" "d['InstanceSet'][0]['InstanceId]"
}

get_instance_ip() {
    local raw
    raw=$(tccli cvm DescribeInstances --region "${REGION}" \
        --Filters '[{"Name":"instance-name","Values":["'"${INSTANCE_NAME}"'"]}]' 2>/dev/null || echo "{}")
    extract_json "$raw" "d['InstanceSet'][0]['PublicIpAddresses'][0]"
}

get_instance_status() {
    local raw
    raw=$(tccli cvm DescribeInstances --region "${REGION}" \
        --Filters '[{"Name":"instance-name","Values":["'"${INSTANCE_NAME}"'"]}]' 2>/dev/null || echo "{}")
    extract_json "$raw" "d['InstanceSet'][0]['InstanceState']"
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
    local img_raw
    img_raw=$(tccli cvm DescribeImages --region "${REGION}" \
        --Filters '[{"Name":"image-name","Values":["Ubuntu Server 24.04 LTS 64"]},{"Name":"image-type","Values":["PUBLIC_IMAGE"]}]' \
        2>/dev/null || echo "{}")
    image_id=$(extract_json "$img_raw" "d['ImageSet'][0]['ImageId']")

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
    local sg_raw
    sg_raw=$(tccli vpc DescribeSecurityGroups --region "${REGION}" \
        --Filters '[{"Name":"is-default","Values":["true"]}]' \
        2>/dev/null || echo "{}")
    sg_id=$(extract_json "$sg_raw" "d['SecurityGroupSet'][0]['SecurityGroupId']")

    if [[ -n "${sg_id}" && "${sg_id}" != "None" ]]; then
        echo "  默认安全组: ${sg_id}"
    else
        echo "  ⚠️  未找到默认安全组，将不指定安全组（使用默认放通）"
        sg_id=""
    fi

    # 查询 SSH 密钥
    echo ">>> 查询 SSH 密钥..."
    local key_id
    local key_raw
    key_raw=$(tccli cvm DescribeKeyPairs --region "${REGION}" \
        2>/dev/null || echo "{}")
    key_id=$(extract_json "$key_raw" "d['KeySet'][0]['KeyId']")

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

    # ---------- 绑定 SSH 密钥 ----------
    # RunInstances 创建的竞价实例可能没有自动绑定密钥（安全组/密钥查询失败时会跳过）
    # 需要停机 → 绑定 → 开机
    if [[ -n "${key_id}" && "${key_id}" != "None" ]]; then
        echo ""
        echo ">>> 绑定 SSH 密钥..."
        # 先停机
        tccli cvm StopInstances --region "${REGION}" --InstanceIds "[\"${instance_id}\"]" &>/dev/null
        for i in $(seq 1 20); do
            local st
            st=$(get_instance_status)
            if [[ "${st}" == "STOPPED" ]]; then break; fi
            sleep 5
        done
        # 绑定密钥
        tccli cvm AssociateInstancesKeyPairs --region "${REGION}" \
            --InstanceIds "[\"${instance_id}\"]" \
            --KeyIds "[\"${key_id}\"]" &>/dev/null
        sleep 3
        # 开机
        tccli cvm StartInstances --region "${REGION}" --InstanceIds "[\"${instance_id}\"]" &>/dev/null
        for i in $(seq 1 20); do
            local st
            st=$(get_instance_status)
            if [[ "${st}" == "RUNNING" ]]; then
                echo "  ✅ SSH 密钥已绑定"
                break
            fi
            sleep 5
        done
    fi

    # ---------- 配置安全组 ----------
    # 如果没有指定安全组（查询失败），尝试查找或创建一个并配置入站规则
    if [[ -z "${sg_id}" || "${sg_id}" == "None" ]]; then
        echo ""
        echo ">>> 配置安全组..."
        # 查找是否有名为 k8s-learning 的安全组
        local sg_raw2
        sg_raw2=$(tccli vpc DescribeSecurityGroups --region "${REGION}" \
            --Filters '[{"Name":"group-name","Values":["k8s-learning"]}]' \
            2>/dev/null || echo "{}")
        sg_id=$(extract_json "$sg_raw2" "d['SecurityGroupSet'][0]['SecurityGroupId']")

        if [[ -z "${sg_id}" || "${sg_id}" == "None" ]]; then
            # 创建新安全组
            local sg_create
            sg_create=$(tccli vpc CreateSecurityGroup --region "${REGION}" \
                --GroupName "k8s-learning" \
                --GroupDescription "K8s learning environment" \
                2>/dev/null || echo "{}")
            sg_id=$(extract_json "$sg_create" "d['SecurityGroupId']")
        fi

        if [[ -n "${sg_id}" && "${sg_id}" != "None" ]]; then
            echo "  安全组: ${sg_id}"
            # 绑定到实例
            tccli cvm AssociateSecurityGroups --region "${REGION}" \
                --InstanceIds "[\"${instance_id}\"]" \
                --SecurityGroupIds "[\"${sg_id}\"]" &>/dev/null
            # 添加入站规则（SSH / HTTP / HTTPS / K8s API / NodePort）
            tccli vpc CreateSecurityGroupPolicies --region "${REGION}" \
                --SecurityGroupId "${sg_id}" \
                --SecurityGroupPolicySet '{
                    "Ingress": [
                        {"Protocol":"TCP","Port":"22","CidrBlock":"0.0.0.0/0","Action":"ACCEPT","PolicyDescription":"SSH"},
                        {"Protocol":"TCP","Port":"80","CidrBlock":"0.0.0.0/0","Action":"ACCEPT","PolicyDescription":"HTTP"},
                        {"Protocol":"TCP","Port":"443","CidrBlock":"0.0.0.0/0","Action":"ACCEPT","PolicyDescription":"HTTPS"},
                        {"Protocol":"TCP","Port":"6443","CidrBlock":"0.0.0.0/0","Action":"ACCEPT","PolicyDescription":"K8s API Server"},
                        {"Protocol":"TCP","Port":"30000-32767","CidrBlock":"0.0.0.0/0","Action":"ACCEPT","PolicyDescription":"NodePort"}
                    ]
                }' &>/dev/null
            echo "  ✅ 安全组规则已配置（22, 80, 443, 6443, 30000-32767）"
        else
            echo "  ⚠️  安全组创建失败，请手动在控制台配置"
        fi
    fi

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
    echo "  1. 在服务器上搭建集群:"
    echo "     ssh -i ~/.ssh/id_rsa ubuntu@${public_ip} 'bash -s' < scripts/setup-server.sh"
    echo ""
    echo "  2. 本地连接集群:"
    echo "     ./scripts/setup-local.sh ${public_ip} ~/.ssh/id_rsa"
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
