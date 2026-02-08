#!/bin/bash


RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PURPLE='\033[35m'
CYAN='\033[96m'
PLAIN='\033[0m'
BOLD='\033[1m'

TARGET_PATH="/root/balancer.sh"
WORK_DIR="/etc/traffic_balancer"
CONF_FILE="${WORK_DIR}/config.conf"
LOG_FILE="/var/log/traffic_balancer.log"
SERVICE_FILE="/etc/systemd/system/traffic_balancer.service"

DEFAULT_RATIO=1.3
DEFAULT_CHECK_INTERVAL=10
DEFAULT_MAX_SPEED_MBPS=100

URLS_CN=(
    "https://mirrors.aliyun.com/centos/7/isos/x86_64/CentOS-7-x86_64-Minimal-2009.iso"
    "https://mirrors.ustc.edu.cn/centos/7/isos/x86_64/CentOS-7-x86_64-Minimal-2009.iso"
    "http://mirrors.163.com/centos/7/isos/x86_64/CentOS-7-x86_64-Minimal-2009.iso"
)

URLS_GLOBAL=(
    "https://speed.cloudflare.com/__down?bytes=5000000000"
    "http://speedtest-sfo3.digitalocean.com/10000mb.test"
    "http://mirror.leaseweb.com/speedtest/10000mb.bin"
    "http://speedtest.tokyo2.linode.com/100MB-tokyo2.bin"
    "http://proof.ovh.net/files/10Gb.dat"
    "http://ipv4.download.thinkbroadband.com/1GB.zip"
)

calc_div() { awk -v a="$1" -v b="$2" 'BEGIN {if(b==0) print 0; else printf "%.2f", a/b}'; }
calc_mul() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%.2f", a*b}'; }
calc_sub() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%.2f", a-b}'; }
calc_gt() { awk -v a="$1" -v b="$2" 'BEGIN {if (a>b) print 1; else print 0}'; }
calc_lt() { awk -v a="$1" -v b="$2" 'BEGIN {if (a<b) print 1; else print 0}'; }

convert_to_mb() {
    local input=$(echo "$1" | tr 'a-z' 'A-Z')
    local val=$(echo "$input" | sed 's/[GM]//g')
    if [[ "$input" == *"G"* ]]; then
        awk -v v="$val" 'BEGIN {printf "%.0f", v*1024}'
    else
        awk -v v="$val" 'BEGIN {printf "%.0f", v}'
    fi
}

format_size() {
    local bytes=$1; [ -z "$bytes" ] && bytes=0
    if [[ $bytes -lt 1024 ]]; then echo "${bytes} B"
    elif [[ $bytes -lt 1048576 ]]; then echo "$(calc_div $bytes 1024) KB"
    elif [[ $bytes -lt 1073741824 ]]; then echo "$(calc_div $bytes 1048576) MB"
    else echo "$(calc_div $bytes 1073741824) GB"; fi
}

get_interface() { ip route get 8.8.8.8 | awk '{print $5; exit}'; }

get_bytes() {
    local iface=$(get_interface); local type=$1
    if [ "$type" == "rx" ]; then grep "$iface:" /proc/net/dev | awk '{print $2}'
    else grep "$iface:" /proc/net/dev | awk '{print $10}'; fi
}

check_dependencies() {
    if ! command -v curl &> /dev/null; then
        if [ -x "$(command -v apt-get)" ]; then apt-get update && apt-get install -y curl; fi
        if [ -x "$(command -v yum)" ]; then yum install -y curl; fi
    fi
}

detect_region() {
    local info=$(curl -s --max-time 5 --retry 2 ipinfo.io || true)
    local country=$(echo "$info" | awk -F'"' '/"country":/ {print $4; exit}')
    [[ "$country" == "CN" ]] && echo "CN" || echo "GLOBAL"
}

load_config() {
    if [ -f "$CONF_FILE" ]; then 
        source "$CONF_FILE"
    else 
        TARGET_RATIO=$DEFAULT_RATIO
        MAX_SPEED_MBPS=$DEFAULT_MAX_SPEED_MBPS
    fi
    [ -z "$MAX_SPEED_MBPS" ] && MAX_SPEED_MBPS=100
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

download_noise() {
    local NEED_MB=$1; local CURRENT_REGION=$2; local SPEED_LIMIT_MBPS=$3
    
    local RATE_LIMIT_MB=$(awk -v bw="$SPEED_LIMIT_MBPS" 'BEGIN {printf "%.2f", bw/8}')
    local RATE_LIMIT_BYTES=$(awk -v mb="$RATE_LIMIT_MB" 'BEGIN {printf "%.0f", mb*1048576}')
    
    local target_urls
    if [ "$CURRENT_REGION" == "CN" ]; then
        target_urls=("${URLS_CN[@]}")
    else
        target_urls=("${URLS_GLOBAL[@]}")
    fi
    
    local rand_idx=$(($RANDOM % ${#target_urls[@]}))
    local url=${target_urls[$rand_idx]}

    log "[执行] 缺口:${NEED_MB}MB | 目标:$(echo $url | awk -F/ '{print $3}') | 限速:${SPEED_LIMIT_MBPS}Mbps"
    
    curl -L -k -4 -s -o /dev/null \
    --limit-rate "$RATE_LIMIT_BYTES" \
    --max-time 600 \
    "$url"
    
    local ret=$?
    if [ $ret -ne 0 ]; then
        log "[警告] 下载中断 (Code: $ret) - 正在切换源重试..."
    else
        log "[完成] 时间片段结束，准备下一轮检查。"
    fi
}

run_worker() {
    load_config
    if [ -z "$REGION" ]; then REGION=$(detect_region); [ -z "$REGION" ] && REGION="GLOBAL"; echo "REGION=$REGION" >> "$CONF_FILE"; fi
    
    log "[启动] 模式:下载版 | 目标 1:$TARGET_RATIO | 限速 ${MAX_SPEED_MBPS}Mbps"
    
    while true; do
        if [ -f "$CONF_FILE" ]; then source "$CONF_FILE"; fi
        [ -z "$MAX_SPEED_MBPS" ] && MAX_SPEED_MBPS=100
        
        local RX_TOTAL=$(get_bytes rx); local TX_TOTAL=$(get_bytes tx)
        local TX_MB=$(calc_div $TX_TOTAL 1048576); local RX_MB=$(calc_div $RX_TOTAL 1048576)
        
        local TARGET_RX_MB=$(calc_mul $TX_MB $TARGET_RATIO)
        local MISSING=$(calc_sub $TARGET_RX_MB $RX_MB)
        
        if [ $(calc_gt $MISSING 10) -eq 1 ]; then
            log "[监控] 缺口:${MISSING}MB -> 开始下载"
            download_noise $MISSING $REGION $MAX_SPEED_MBPS
        else
            sleep 10
        fi
        sleep 2
    done
}

monitor_dashboard() {
    clear; echo "初始化数据..."; local r1=$(get_bytes rx); local t1=$(get_bytes tx)
    while true; do
        read -t 1 -n 1 key; if [[ $? -eq 0 ]]; then break; fi
        local r2=$(get_bytes rx); local t2=$(get_bytes tx)
        local r_speed=$((r2 - r1)); local t_speed=$((t2 - t1))
        r1=$r2; t1=$t2
        clear
        echo -e "${BLUE}╔════════════════════════════════════════╗${PLAIN}"
        echo -e "${BLUE}║          实时流量监控面板              ║${PLAIN}"
        echo -e "${BLUE}╚════════════════════════════════════════╝${PLAIN}"
        echo -e ""
        echo -e "   ${GREEN}⬇️  实时下载速度${PLAIN} :  ${BOLD}$(format_size $r_speed)/s${PLAIN}"
        echo -e "   ${YELLOW}⬆️  实时上传速度${PLAIN} :  ${BOLD}$(format_size $t_speed)/s${PLAIN}"
        echo -e ""
        echo -e "   ${CYAN}📦 累计总下载${PLAIN}   :  $(format_size $r2)"
        echo -e "   ${PURPLE}📦 累计总上传${PLAIN}   :  $(format_size $t2)"
        echo -e ""
        echo -e "${BLUE}══════════════════════════════════════════${PLAIN}"
        echo -e " 按任意键返回主菜单..."
    done
}


view_logs() {
    clear
    echo -e "${BLUE}=== 最近 50 条日志 ===${PLAIN}"
    echo -e "${YELLOW}(日志文件: $LOG_FILE)${PLAIN}"
    echo ""
    tail -n 50 "$LOG_FILE"
    echo ""
    echo -e "${BLUE}======================${PLAIN}"
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

ensure_script_file() {
    if [ -f "$TARGET_PATH" ]; then return 0; fi
    if [ -f "$0" ]; then
        cp "$0" "$TARGET_PATH"; chmod +x "$TARGET_PATH"
        echo -e "${GREEN}已将脚本复制到 $TARGET_PATH${PLAIN}"
    else
        echo -e "${YELLOW}正在从 GitHub 下载完整脚本...${PLAIN}"
        curl -o "$TARGET_PATH" -L https://raw.githubusercontent.com/hiapb/balancer/main/install.sh
        chmod +x "$TARGET_PATH"
        if [ ! -f "$TARGET_PATH" ]; then
            echo -e "${RED}下载失败，请手动执行: curl -o /root/balancer.sh ...${PLAIN}"; return 1
        fi
        echo -e "${GREEN}下载成功！${PLAIN}"
    fi
}

install_service() {
    check_dependencies; mkdir -p "$WORK_DIR"; touch "$LOG_FILE"
    ensure_script_file
    if [ ! -f "$TARGET_PATH" ]; then echo -e "${RED}文件丢失，安装终止。${PLAIN}"; read -p "回车退出..."; return; fi
    
    echo "TARGET_RATIO=$DEFAULT_RATIO" > "$CONF_FILE"
    echo "MAX_SPEED_MBPS=$DEFAULT_MAX_SPEED_MBPS" >> "$CONF_FILE"
    echo -e "${YELLOW}正在探测网络环境...${PLAIN}"
    local detected=$(detect_region)
    local detected_str="国际 (Global)"; [ "$detected" == "CN" ] && detected_str="国内 (CN)"
    
    echo -e " 检测到区域: ${BOLD}$detected_str${PLAIN}"
    echo -e " 请选择下载源区域:"
    echo -e "  1. 国内 (CN)"
    echo -e "  2. 国际 (Global)"
    read -p " 请输入 [默认回车]: " region_choice
    local final_region=$detected
    case $region_choice in 1) final_region="CN" ;; 2) final_region="GLOBAL" ;; esac
    echo "REGION=$final_region" >> "$CONF_FILE"
    
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Traffic Balancer
After=network.target
[Service]
Type=simple
ExecStart=/bin/bash $TARGET_PATH --worker
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable traffic_balancer; systemctl restart traffic_balancer
    echo -e "${GREEN}安装完成！已选区域: $final_region${PLAIN}"
    read -p "按回车继续..."
}

set_parameters() {
    load_config; clear
    echo -e "${BLUE}╔════════════════════════════════════════╗${PLAIN}"
    echo -e "${BLUE}║           参数配置向导                 ║${PLAIN}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${PLAIN}"
    echo -e " 当前状态: 比例 1:${TARGET_RATIO} | 限速 ${MAX_SPEED_MBPS} Mbps"
    echo -e ""
    echo -e "${YELLOW}1. 设置下行比例${PLAIN} (如 1.5)"
    read -p "   请输入 (留空跳过): " input_ratio
    echo -e ""
    echo -e "${YELLOW}2. 设置速度限制${PLAIN} (如 100M, 1G)"
    read -p "   请输入 (留空跳过): " input_speed
    
    local new_ratio=$TARGET_RATIO
    if [[ ! -z "$input_ratio" ]]; then
        local clean_val=$(echo "$input_ratio" | sed 's/^1://')
        if [[ "$clean_val" =~ ^[0-9]+([.][0-9]+)?$ ]]; then new_ratio=$clean_val; fi
    fi
    local new_speed=$MAX_SPEED_MBPS
    if [[ ! -z "$input_speed" ]]; then
        local converted=$(convert_to_mb "$input_speed")
        if [[ "$converted" =~ ^[0-9]+$ ]]; then new_speed=$converted; fi
    fi
    echo "TARGET_RATIO=$new_ratio" > "$CONF_FILE"
    echo "MAX_SPEED_MBPS=$new_speed" >> "$CONF_FILE"
    if ! grep -q "REGION=" "$CONF_FILE"; then echo "REGION=$REGION" >> "$CONF_FILE"; fi
    systemctl restart traffic_balancer
    echo -e "${GREEN}配置已更新！${PLAIN}"; read -p "按回车返回..."
}

is_installed() {
    if [ -f "$CONF_FILE" ] && [ -f "$SERVICE_FILE" ]; then return 0; else return 1; fi
}

require_install() {
    if ! is_installed; then
        echo -e "\n ${RED}⚠️  错误：请先执行 [1] 安装服务！${PLAIN}\n"; read -p " 按回车返回..."; return 1
    fi
    return 0
}

uninstall_clean() {
    echo -e "${YELLOW}正在停止服务...${PLAIN}"
    systemctl stop traffic_balancer
    systemctl disable traffic_balancer
    pkill -f "balancer.sh"
    rm -f "$SERVICE_FILE" "$LOG_FILE"
    rm -rf "$WORK_DIR"
    rm -f "$TARGET_PATH" 
    systemctl daemon-reload
    echo -e "${GREEN}✅ 卸载完成。${PLAIN}"
    exit 0
}

show_menu() {
    while true; do
        if [ -f "$CONF_FILE" ]; then source "$CONF_FILE"; fi
        [ -z "$MAX_SPEED_MBPS" ] && MAX_SPEED_MBPS=100
        
        clear
        local iface=$(get_interface); local rx=$(get_bytes rx); local tx=$(get_bytes tx)
        local status_icon="${RED}● 未安装${PLAIN}"
        if is_installed; then
            if systemctl is-active --quiet traffic_balancer; then status_icon="${GREEN}● 运行中${PLAIN}"; else status_icon="${YELLOW}● 已停止${PLAIN}"; fi
        fi
        
        local region_txt="未配置"
        if [ "$REGION" == "CN" ]; then region_txt="${GREEN}国内 (CN)${PLAIN}"; elif [ "$REGION" == "GLOBAL" ]; then region_txt="${CYAN}国际 (Global)${PLAIN}"; fi

        echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "${BLUE}     Traffic Balancer    ${PLAIN}"
        echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e " 运行状态 : $status_icon"
        echo -e " 所在区域 : $region_txt"
        echo -e " 网卡接口 : $iface"
        echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e " 流量统计:"
        echo -e "   ⬆️  累计上传 : ${YELLOW}$(format_size $tx)${PLAIN}"
        echo -e "   ⬇️  累计下载 : ${GREEN}$(format_size $rx)${PLAIN}"
        echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        if is_installed; then
             echo -e " 当前策略:"
             echo -e "   目标比例 : ${BOLD}1 : ${TARGET_RATIO}${PLAIN}"
             echo -e "   速度限制 : ${BOLD}${MAX_SPEED_MBPS} Mbps${PLAIN}"
             echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        fi

        echo -e " 1. 安装并启动服务"
        echo -e " 2. 修改策略 (比例 / 速度)"
        echo -e " 3. 实时监控面板"
        echo -e " 4. 查看运行日志"
        echo -e " 5. 重启服务"
        echo -e " 6. 停止服务"
        echo -e " 7. 卸载和清理"
        echo -e " 0. 退出"
        echo -e ""
        read -p " 请输入选项 [0-7]: " choice
        
        case $choice in
            1) install_service ;;
            2) require_install && set_parameters ;;
            3) require_install && monitor_dashboard ;;
            4) require_install && view_logs ;;
            5) require_install && systemctl restart traffic_balancer && echo "已重启" && sleep 1 ;;
            6) require_install && systemctl stop traffic_balancer && echo "已停止" && sleep 1 ;;
            7) uninstall_clean ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

if [[ "$1" == "--worker" ]]; then run_worker; else
    if [[ $EUID -ne 0 ]]; then echo "请使用root运行"; exit 1; fi
    show_menu
fi
