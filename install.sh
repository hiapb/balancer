#!/bin/bash

# =========================================================
# Traffic Balancer Ultimate (智能逻辑版)
# Logic: 仅当 (下载 < 上传 * 1.3) 时触发，否则绝对静默
# Author: Gemini
# =========================================================

# --- 样式配置 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'
BOLD='\033[1m'

# --- 基础路径 ---
WORK_DIR="/etc/traffic_balancer"
CONF_FILE="${WORK_DIR}/config.conf"
LOG_FILE="/var/log/traffic_balancer.log"
SERVICE_FILE="/etc/systemd/system/traffic_balancer.service"

# --- 默认配置 ---
DEFAULT_RATIO=1.3
DEFAULT_CHECK_INTERVAL=60
DEFAULT_MIN_UPLOAD=5 

# --- 国内高速白名单源 ---
URLS=(
    "https://mirrors.aliyun.com/centos/7/isos/x86_64/CentOS-7-x86_64-Minimal-2009.iso"
    "https://mirrors.cloud.tencent.com/centos/7/isos/x86_64/CentOS-7-x86_64-Minimal-2009.iso"
    "https://mirrors.huaweicloud.com/centos/7/isos/x86_64/CentOS-7-x86_64-Minimal-2009.iso"
    "https://mirrors.ustc.edu.cn/ubuntu-releases/22.04/ubuntu-22.04.3-desktop-amd64.iso"
)

# =========================================================
# 数学运算核心 (Awk 替代 bc，防止报错)
# =========================================================

calc_div() { awk -v a="$1" -v b="$2" 'BEGIN {if(b==0) print 0; else printf "%.2f", a/b}'; }
calc_mul() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%.2f", a*b}'; }
calc_sub() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%.2f", a-b}'; }
calc_gt() { awk -v a="$1" -v b="$2" 'BEGIN {if (a>b) print 1; else print 0}'; }
calc_lt() { awk -v a="$1" -v b="$2" 'BEGIN {if (a<b) print 1; else print 0}'; }

# =========================================================
# 工具函数库
# =========================================================

format_size() {
    local bytes=$1
    if [ -z "$bytes" ]; then bytes=0; fi
    if [[ $bytes -lt 1024 ]]; then echo "${bytes} B"
    elif [[ $bytes -lt 1048576 ]]; then echo "$(calc_div $bytes 1024) KB"
    elif [[ $bytes -lt 1073741824 ]]; then echo "$(calc_div $bytes 1048576) MB"
    else echo "$(calc_div $bytes 1073741824) GB"
    fi
}

get_interface() { ip route get 8.8.8.8 | awk '{print $5; exit}'; }

get_bytes() {
    local iface=$(get_interface)
    local type=$1
    if [ "$type" == "rx" ]; then grep "$iface:" /proc/net/dev | awk '{print $2}'
    else grep "$iface:" /proc/net/dev | awk '{print $10}'; fi
}

check_dependencies() {
    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}正在安装 curl...${PLAIN}"
        if [ -x "$(command -v apt-get)" ]; then apt-get update && apt-get install -y curl
        elif [ -x "$(command -v yum)" ]; then yum install -y curl; fi
    fi
}

load_config() {
    if [ -f "$CONF_FILE" ]; then source "$CONF_FILE"
    else TARGET_RATIO=$DEFAULT_RATIO; fi
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# =========================================================
# 核心工作逻辑 (Worker)
# =========================================================

download_noise() {
    local NEED_MB=$1
    local MAX_MB=50 
    
    if [ $(calc_gt $NEED_MB $MAX_MB) -eq 1 ]; then NEED_MB=$MAX_MB; fi
    
    local BYTES=$(awk -v mb="$NEED_MB" 'BEGIN {printf "%.0f", mb*1024*1024}')
    local idx=$(($RANDOM % ${#URLS[@]}))
    local url=${URLS[$idx]}
    
    log "[ACTION] Compensating ${NEED_MB} MB..."
    curl -r 0-$BYTES -L -s -o /dev/null --max-time 60 "$url"
}

run_worker() {
    load_config
    local IFACE=$(get_interface)
    log "[SYSTEM] Started. Ratio Target 1:$TARGET_RATIO"
    
    while true; do
        local RX1=$(get_bytes rx)
        local TX1=$(get_bytes tx)
        sleep $DEFAULT_CHECK_INTERVAL
        local RX2=$(get_bytes rx)
        local TX2=$(get_bytes tx)
        
        # 计算区间增量
        local TX_DIFF=$((TX2 - TX1))
        local RX_DIFF=$((RX2 - RX1))
        local TX_MB=$(calc_div $TX_DIFF 1048576)
        local RX_MB=$(calc_div $RX_DIFF 1048576)
        
        if [ -f "$CONF_FILE" ]; then source "$CONF_FILE"; fi

        # 1. 闲置判断 (上传 < 5MB/min 不处理)
        if [ $(calc_lt $TX_MB $DEFAULT_MIN_UPLOAD) -eq 1 ]; then
            # log "[IDLE] Traffic low ($TX_MB MB). Skipping."
            continue
        fi
        
        # 2. 核心判断逻辑
        local REQUIRED_RX=$(calc_mul $TX_MB $TARGET_RATIO)
        
        # 如果 当前下载 > (当前上传 * 1.3)
        if [ $(calc_gt $RX_MB $REQUIRED_RX) -eq 1 ]; then
            # 这里就是你要的逻辑：如果不小于，则不用管
            log "[SAFE] TX:${TX_MB}MB RX:${RX_MB}MB (Ratio OK). Skipping."
        else
            # 只有小于才执行
            local MISSING=$(calc_sub $REQUIRED_RX $RX_MB)
            log "[UNSAFE] TX:${TX_MB}MB RX:${RX_MB}MB -> Missing ${MISSING}MB"
            download_noise $MISSING
        fi
    done
}

# =========================================================
# 界面逻辑
# =========================================================

monitor_dashboard() {
    clear
    echo -e "正在初始化监控..."
    local r1=$(get_bytes rx); local t1=$(get_bytes tx)
    while true; do
        read -t 1 -n 1 key; if [[ $? -eq 0 ]]; then break; fi
        local r2=$(get_bytes rx); local t2=$(get_bytes tx)
        local r_speed=$((r2 - r1)); local t_speed=$((t2 - t1))
        r1=$r2; t1=$t2
        
        clear
        echo -e "${BLUE}========================================${PLAIN}"
        echo -e "${BOLD}   Traffic Balancer - 实时监控   ${PLAIN}"
        echo -e "${BLUE}========================================${PLAIN}"
        echo -e "时间: $(date '+%H:%M:%S') | 网卡: $(get_interface)"
        echo -e "----------------------------------------"
        echo -e "⬇️  下载: ${GREEN}$(format_size $r_speed)/s${PLAIN}"
        echo -e "⬆️  上传: ${YELLOW}$(format_size $t_speed)/s${PLAIN}"
        echo -e "----------------------------------------"
        echo -e "⬇️  总下: $(format_size $r2)"
        echo -e "⬆️  总上: $(format_size $t2)"
        echo -e "----------------------------------------"
        echo -e "${YELLOW}提示: 按下 [任意键] 返回主菜单${PLAIN}"
    done
}

install_service() {
    check_dependencies; mkdir -p "$WORK_DIR"; touch "$LOG_FILE"
    if [ ! -f "$CONF_FILE" ]; then echo "TARGET_RATIO=$DEFAULT_RATIO" > "$CONF_FILE"; fi
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Traffic Balancer Ultimate
After=network.target
[Service]
Type=simple
ExecStart=/bin/bash $(readlink -f "$0") --worker
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable traffic_balancer; systemctl start traffic_balancer
    echo -e "${GREEN}安装并启动成功！${PLAIN}"; read -p "按回车继续..."
}

set_ratio() {
    load_config
    echo -e "${BLUE}=== 设置平衡比例 ===${PLAIN}"
    echo -e "当前: 1 : ${YELLOW}${TARGET_RATIO}${PLAIN}"
    read -p "请输入新比例 (如 1.3): " new_val
    if [[ "$new_val" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "TARGET_RATIO=$new_val" > "$CONF_FILE"
        echo -e "${GREEN}已保存。${PLAIN}"
    else echo -e "${RED}无效输入。${PLAIN}"; fi
    read -p "按回车继续..."
}

show_menu() {
    load_config
    while true; do
        clear
        local iface=$(get_interface); local rx=$(get_bytes rx); local tx=$(get_bytes tx)
        echo -e "${BLUE}=============================================${PLAIN}"
        echo -e "${BOLD}           Traffic Balancer Ultimate         ${PLAIN}"
        echo -e "${BLUE}=============================================${PLAIN}"
        if systemctl is-active --quiet traffic_balancer; then
            echo -e "状态: ${GREEN}● 运行中${PLAIN}"
        else echo -e "状态: ${RED}● 未运行${PLAIN}"; fi
        echo -e "目标: ${YELLOW}1 : ${TARGET_RATIO}${PLAIN}"
        echo -e "网卡: ${BOLD}$iface${PLAIN} | 上行: ${YELLOW}$(format_size $tx)${PLAIN} | 下行: ${GREEN}$(format_size $rx)${PLAIN}"
        echo -e "${BLUE}=============================================${PLAIN}"
        echo -e " 1. 安装/启动"
        echo -e " 2. 设置比例"
        echo -e " 3. 实时面板"
        echo -e " 4. 查看日志"
        echo -e " 5. 重启服务"
        echo -e " 6. 停止服务"
        echo -e " 7. 卸载"
        echo -e " 0. 退出"
        echo -e "---------------------------------------------"
        read -p "选择: " choice
        case $choice in
            1) install_service ;;
            2) set_ratio ;;
            3) monitor_dashboard ;;
            4) tail -f -n 20 "$LOG_FILE" ;;
            5) systemctl restart traffic_balancer; echo "重启中..."; sleep 1 ;;
            6) systemctl stop traffic_balancer; echo "已停止"; sleep 1 ;;
            7) systemctl stop traffic_balancer; systemctl disable traffic_balancer; rm -f "$SERVICE_FILE" "$LOG_FILE"; rm -rf "$WORK_DIR"; echo "已卸载"; read -p "按回车..." ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

if [[ "$1" == "--worker" ]]; then run_worker; else
    if [[ $EUID -ne 0 ]]; then echo "请 root 运行"; exit 1; fi
    show_menu
fi
