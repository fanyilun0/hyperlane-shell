#!/bin/bash

LOG_FILE="/var/log/hyperlane_setup.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' 

# 生成随机字符串的函数
generate_random_suffix() {
    # 生成6位随机字符串
    cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 6 | head -n 1
}

# 显示logo
curl -s https://raw.githubusercontent.com/ziqing888/logo.sh/main/logo.sh | bash

# 日志函数
log() {
    echo -e "$1"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') $1" >> $LOG_FILE
}

# 错误处理函数
error_exit() {
    log "${RED}Error: $1${NC}"
    exit 1
}

# 权限检查
if [ "$EUID" -ne 0 ]; then
    log "${RED}请以 root 权限运行此脚本！${NC}"
    exit 1
fi

# 检查日志路径
if [ ! -w "$(dirname "$LOG_FILE")" ]; then
    error_exit "日志路径不可写，请检查权限或调整路径：$(dirname "$LOG_FILE")"
fi

# 设置全局变量
DB_DIR="/opt/hyperlane_db"

# 创建主数据库目录
if [ ! -d "$DB_DIR" ]; then
    mkdir -p "$DB_DIR" && chmod -R 777 "$DB_DIR" || error_exit "创建数据库目录失败: $DB_DIR"
    log "${GREEN}数据库目录已创建: $DB_DIR${NC}"
else
    log "${GREEN}数据库目录已存在: $DB_DIR${NC}"
fi

# 检查系统要求
check_requirements() {
    log "${YELLOW}检查系统环境...${NC}"
    CPU=$(grep -c ^processor /proc/cpuinfo)
    RAM=$(free -m | awk '/Mem:/ { print $2 }')
    DISK=$(df -h / | awk '/\// { print $4 }' | sed 's/G//g')

    log "CPU核心数: $CPU"
    log "可用内存: ${RAM}MB"
    log "可用磁盘空间: ${DISK}GB"

    if [ "$CPU" -lt 2 ]; then
        error_exit "CPU核心数不足 (至少需要2核心)"
    fi

    if [ "$RAM" -lt 2000 ]; then
        error_exit "内存不足 (至少需要2GB)"
    fi

    if [ "${DISK%.*}" -lt 20 ]; then
        error_exit "磁盘空间不足 (至少需要20GB)"
    fi

    log "${GREEN}系统环境满足最低要求。${NC}"
}

# 安装 Docker
install_docker() {
    if ! command -v docker &> /dev/null; then
        log "${YELLOW}安装 Docker...${NC}"
        sudo apt-get update
        sudo apt-get install -y docker.io || error_exit "安装 Docker 失败"
        sudo systemctl start docker || error_exit "启动 Docker 服务失败"
        sudo systemctl enable docker || error_exit "设置 Docker 开机自启失败"
        log "${GREEN}Docker 已成功安装并启动！${NC}"
    else
        log "${GREEN}Docker 已安装，跳过此步骤。${NC}"
    fi
}

# 安装 Node.js 和 NVM
install_nvm_and_node() {
    if ! command -v nvm &> /dev/null; then
        log "${YELLOW}安装 NVM...${NC}"
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash || error_exit "安装 NVM 失败"
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        log "${GREEN}NVM 已成功安装！${NC}"
    else
        log "${GREEN}NVM 已安装，跳过此步骤。${NC}"
    fi

    if ! command -v node &> /dev/null; then
        log "${YELLOW}安装 Node.js v20...${NC}"
        nvm install 20 || error_exit "安装 Node.js 失败"
        log "${GREEN}Node.js 已成功安装！${NC}"
    else
        log "${GREEN}Node.js 已安装，跳过此步骤。${NC}"
    fi
}

# 安装 Foundry
install_foundry() {
    if ! command -v foundryup &> /dev/null; then
        log "${YELLOW}安装 Foundry...${NC}"
        curl -L https://foundry.paradigm.xyz | bash || error_exit "安装 Foundry 失败"
        
        # 重新加载环境变量
        source ~/.bashrc
        
        # 使用新的shell执行foundryup
        exec bash -c '
            source ~/.bashrc
            foundryup || exit 1
        ' || error_exit "初始化 Foundry 失败"
        
        log "${GREEN}Foundry 已成功安装！${NC}"
    else
        log "${GREEN}Foundry 已安装，跳过此步骤。${NC}"
    fi
}

# 安装 Hyperlane
install_hyperlane() {
    if ! command -v hyperlane &> /dev/null; then
        log "${YELLOW}安装 Hyperlane CLI...${NC}"
        npm install -g @hyperlane-xyz/cli || error_exit "安装 Hyperlane CLI 失败"
        log "${GREEN}Hyperlane CLI 已成功安装！${NC}"
    else
        log "${GREEN}Hyperlane CLI 已安装，跳过此步骤。${NC}"
    fi

    if ! docker images | grep -q 'gcr.io/abacus-labs-dev/hyperlane-agent'; then
        log "${YELLOW}拉取 Hyperlane 镜像...${NC}"
        docker pull --platform linux/amd64 gcr.io/abacus-labs-dev/hyperlane-agent:agents-v1.0.0 || error_exit "拉取 Hyperlane 镜像失败"
        log "${GREEN}Hyperlane 镜像已成功拉取！${NC}"
    else
        log "${GREEN}Hyperlane 镜像已存在，跳过此步骤。${NC}"
    fi
}

# 配置并启动单个 Validator
configure_single_validator() {
    local index=$1
    local validator_name=$2
    local private_key=$3
    local rpc_url=$4
    
    # 生成随机后缀
    local suffix=$(generate_random_suffix)
    local container_name="hyperlane_validator_${index}_${suffix}"
    local db_dir="${DB_DIR}/validator${index}_${suffix}"
    local checkpoint_path="/hyperlane_db_base/validator${index}_${suffix}/checkpoints"
    
    # 创建独立的数据库目录
    mkdir -p "$db_dir" && chmod -R 777 "$db_dir" || error_exit "创建数据库目录失败: $db_dir"
    
    # 检查并删除已存在的容器
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log "${YELLOW}发现已有容器 ${container_name}，正在删除...${NC}"
        docker rm -f "${container_name}" || error_exit "无法删除旧容器 ${container_name}"
    fi

    # print the command before run
    # echo "docker run -d \
    #     -it \
    #     --name "${container_name}" \
    #     --mount type=bind,source="$db_dir",target=/hyperlane_db_base \
    #     gcr.io/abacus-labs-dev/hyperlane-agent:agents-v1.0.0 \
    #     ./validator \
    #     --db /hyperlane_db_base \
    #     --originChainName base \
    #     --reorgPeriod 1 \
    #     --validator.id "${validator_name}_${index}" \
    #     --checkpointSyncer.type localStorage \
    #     --checkpointSyncer.folder base \
    #     --checkpointSyncer.path "$checkpoint_path" \
    #     --validator.key "$private_key" \
    #     --chains.base.signer.key "$private_key" \
    #     --chains.base.customRpcUrls "$rpc_url""
    
    # 启动validator
    docker run -d \
        -it \
        --name "${container_name}" \
        --mount type=bind,source="$db_dir",target=/hyperlane_db_base \
        gcr.io/abacus-labs-dev/hyperlane-agent:agents-v1.0.0 \
        ./validator \
        --db /hyperlane_db_base \
        --originChainName base \
        --reorgPeriod 1 \
        --validator.id "${validator_name}_${index}" \
        --checkpointSyncer.type localStorage \
        --checkpointSyncer.folder base \
        --checkpointSyncer.path "$checkpoint_path" \
        --validator.key "$private_key" \
        --chains.base.signer.key "$private_key" \
        --chains.base.customRpcUrls "$rpc_url" || error_exit "启动 Validator ${index} 失败"
        
    # 等待容器完全启动
    sleep 10
        
    log "${GREEN}Validator ${index} 已配置并启动！容器名称：${container_name}${NC}"
}

# 配置并启动所有 Validators
configure_and_start_validators() {
    read -p "请输入基础 Validator Name (将自动添加序号): " BASE_VALIDATOR_NAME
    
    # 创建数组存储配置
    declare -a private_keys
    declare -a rpc_urls
    
    echo -e "\n${YELLOW}请按以下格式输入配置信息 (每行一组,用空格分隔私钥和RPC URL)${NC}"
    echo "示例:"
    echo "0x1234...abcd https://rpc1.example.com"
    echo "0xabcd...1234 https://rpc2.example.com"
    echo -e "${YELLOW}输入完成后请按两次回车${NC}\n"
    
    # 临时存储输入的行
    local input=""
    local line_count=0
    
    # 读取多行输入
    while IFS= read -r line; do
        # 如果是空行且已有输入,则结束读取
        if [[ -z "$line" && -n "$input" ]]; then
            break
        fi
        # 如果是空行且没有输入,继续读取
        if [[ -z "$line" && -z "$input" ]]; then
            continue
        fi
        
        # 累积输入
        input+="$line"$'\n'
        ((line_count++))
    done
    
    # 处理每行输入
    local error_count=0
    while IFS= read -r line; do
        # 跳过空行
        [[ -z "$line" ]] && continue
        
        # 分割私钥和RPC URL
        read -r private_key rpc_url <<< "$line"
        
        # 验证私钥格式
        if [[ ! $private_key =~ ^0x[0-9a-fA-F]{64}$ ]]; then
            log "${RED}无效的 Private Key 格式: $private_key${NC}"
            ((error_count++))
            continue
        fi
        
        # 检查私钥是否重复
        if [[ " ${private_keys[@]} " =~ " ${private_key} " ]]; then
            log "${RED}重复的 Private Key: $private_key${NC}"
            ((error_count++))
            continue
        fi
        
        # 验证RPC URL
        if [[ -z "$rpc_url" ]]; then
            log "${RED}缺少 RPC URL${NC}"
            ((error_count++))
            continue
        fi
        
        # 添加到数组
        private_keys+=("$private_key")
        rpc_urls+=("$rpc_url")
        
    done <<< "$input"
    
    # 检查是否有有效配置
    if [ ${#private_keys[@]} -eq 0 ]; then
        error_exit "未添加任何有效配置！"
    fi
    
    # 显示配置总结和错误统计
    echo -e "\n${GREEN}配置总结：${NC}"
    echo "成功解析: ${#private_keys[@]} 组配置"
    if [ $error_count -gt 0 ]; then
        echo -e "${RED}解析失败: $error_count 组配置${NC}"
    fi
    
    # 显示成功解析的配置
    echo -e "\n${YELLOW}成功解析的配置:${NC}"
    for i in "${!private_keys[@]}"; do
        echo "组 $((i+1)):"
        echo "Private Key: ${private_keys[$i]}"
        echo "RPC URL: ${rpc_urls[$i]}"
        echo "---"
    done
    
    # 确认启动
    read -p "确认启动以上配置？(y/n): " confirm
    if [[ $confirm != "y" ]]; then
        error_exit "用户取消操作"
    fi
    
    # 启动所有配置
    for i in "${!private_keys[@]}"; do
        local validator_name="${BASE_VALIDATOR_NAME}_${i}"
        log "${YELLOW}启动第 $((i+1)) 组 Validator...${NC}"
        
        configure_single_validator "$((i+1))" "$validator_name" "${private_keys[$i]}" "${rpc_urls[$i]}"
        
        # 添加延迟，避免announce冲突
        if [ $i -lt $((${#private_keys[@]} - 1)) ]; then
            log "${YELLOW}等待10秒后启动下一组...${NC}"
            sleep 10
        fi
    done
    
    log "${GREEN}所有 Validators 已配置并启动！${NC}"
}


# 在view_logs中动态获取容器数量
view_logs() {
    local containers=$(docker ps -a --format '{{.Names}}' | grep "hyperlane_validator_" | sort -V)
    if [ -z "$containers" ]; then
        log "${YELLOW}未发现运行中的验证者容器${NC}"
        return
    fi
    
    log "${YELLOW}请选择要查看的 Validator 日志:${NC}"
    local i=1
    while read -r container; do
        echo "$i) $container"
        ((i++))
    done <<< "$containers"
    echo "0) 返回"
    
    read -p "请选择: " choice
    if [ "$choice" = "0" ]; then
        return
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -le "$((i-1))" ]; then
        local selected=$(echo "$containers" | sed -n "${choice}p")
        docker logs -f "$selected" || error_exit "查看 $selected 日志失败"
    else
        log "${RED}无效选项！${NC}"
    fi
}

# 主菜单
main_menu() {
    while true; do
        echo -e "${YELLOW}"
        echo "================= Hyperlane 安装脚本 ================="
        echo "1) 检查系统环境"
        echo "2) 安装所有依赖 (Docker, Node.js, Foundry)"
        echo "3) 安装 Hyperlane"
        echo "4) 配置并启动 Validators"
        echo "5) 查看运行日志"
        echo "6) 一键完成所有步骤"
        echo "0) 退出"
        echo "====================================================="
        echo -e "${NC}"
        read -p "请输入选项: " choice
        case $choice in
            1) check_requirements ;;
            2) install_docker && install_nvm_and_node && install_foundry ;;
            3) install_hyperlane ;;
            4) configure_and_start_validators ;;
            5) view_logs ;;
            6) 
                check_requirements
                install_docker
                install_nvm_and_node
                install_foundry
                install_hyperlane
                configure_and_start_validators
                view_logs
                ;;
            0) exit 0 ;;
            *) log "${RED}无效选项，请重试！${NC}" ;;
        esac
    done
}

main_menu
