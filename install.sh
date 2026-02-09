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
SOURCE_LIST_FILE="${WORK_DIR}/custom_sources.txt"
LOG_FILE="/var/log/traffic_balancer.log"
SERVICE_FILE="/etc/systemd/system/traffic_balancer.service"

# === 默认配置 ===
DEFAULT_RATIO=1.2
DEFAULT_CHECK_INTERVAL=10
DEFAULT_MAX_SPEED_MBPS=100

# 国内源 (CN)
DEFAULT_URLS_CN=(
    "https://balancer.inim.im/d/down/Android20Studio202025.rar?sign=RIdltmoIedI7VXSu-hZ3inZpj2w3Lir1mSCRSPAniwk=:0"
)

# 国际源 (Global)
DEFAULT_URLS_GLOBAL=(
    "https://balancer.inim.im/d/down/Android20Studio202025.rar?sign=RIdltmoIedI7VXSu-hZ3inZpj2w3Lir1mSCRSPAniwk=:0"
)

# === 工具函数 ===

calc_div() { awk -v a="$1" -v b="$2" 'BEGIN {if(b==0) print 0; else printf "%.2f", a/b}'; }
calc_mul() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%.2f", a*b}'; }
calc_sub() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%.2f", a-b}'; }
calc_gt() { awk -v a="$1" -v b="$2" 'BEGIN {if (a>b) print 1; else print 0}'; }

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
        REGION="GLOBAL"
        ACTIVE_URL_MODE="DEFAULT" # DEFAULT or CUSTOM
        CUSTOM_URL_VAL=""
    fi
    [ -z "$MAX_SPEED_MBPS" ] && MAX_SPEED_MBPS=100
    [ -z "$ACTIVE_URL_MODE" ] && ACTIVE_URL_MODE="DEFAULT"
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# === 核心逻辑 ===

download_noise() {
    local NEED_MB=$1; local CURRENT_REGION=$2; local SPEED_LIMIT_MBPS=$3
    
    local RATE_LIMIT_MB=$(awk -v bw="$SPEED_LIMIT_MBPS" 'BEGIN {printf "%.2f", bw/8}')
    local RATE_LIMIT_BYTES=$(awk -v mb="$RATE_LIMIT_MB" 'BEGIN {printf "%.0f", mb*1048576}')
    
    local url=""
    
    if [ "$ACTIVE_URL_MODE" == "CUSTOM" ] && [ ! -z "$CUSTOM_URL_VAL" ]; then
        url="$CUSTOM_URL_VAL"
        if [[ ! $url =~ ^http ]]; then
            log "[警告] 自定义URL无效，回退到内置源"
            url=""
        fi
    fi

    if [ -z "$url" ]; then
        local target_urls
        if [ "$CURRENT_REGION" == "CN" ]; then
            target_urls=("${DEFAULT_URLS_CN[@]}")
        else
            target_urls=("${DEFAULT_URLS_GLOBAL[@]}")
        fi
        local rand_idx=$(($RANDOM % ${#target_urls[@]}))
        url=${target_urls[$rand_idx]}
    fi
    
    log "[执行] 缺口:${NEED_MB}MB | 限速:${SPEED_LIMIT_MBPS}Mbps | 目标:$(echo $url | awk -F/ '{print $3}')"
    
    curl -L -k -4 -s -o /dev/null \
    --limit-rate "$RATE_LIMIT_BYTES" \
    --max-time 600 \
    --retry 3 \
    "$url"
}

run_worker() {
    load_config
    # 首次运行如果没有配置Region，自动探测并写入
    if [ -z "$REGION" ]; then 
        REGION=$(detect_region)
        echo "REGION=$REGION" >> "$CONF_FILE"
    fi
    
    log "[启动] 模式:限速下载 | 目标 1:$TARGET_RATIO | 限速 ${MAX_SPEED_MBPS}Mbps | 区域:$REGION"
    
    while true; do
        if [ -f "$CONF_FILE" ]; then source "$CONF_FILE"; fi
        [ -z "$MAX_SPEED_MBPS" ] && MAX_SPEED_MBPS=100
        
        local RX_TOTAL=$(get_bytes rx); local TX_TOTAL=$(get_bytes tx)
        local TX_MB=$(calc_div $TX_TOTAL 1048576); local RX_MB=$(calc_div $RX_TOTAL 1048576)
        local TARGET_RX_MB=$(calc_mul $TX_MB $TARGET_RATIO)
        local MISSING=$(calc_sub $TARGET_RX_MB $RX_MB)
        
        if [ $(calc_gt $MISSING 50) -eq 1 ]; then
            log "[监控] 缺口:${MISSING}MB -> 启动下载"
            download_noise $MISSING $REGION $MAX_SPEED_MBPS
        else
            sleep 10
        fi
        sleep 2
    done
}

# === 界面与交互 ===

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
    tail -n 50 "$LOG_FILE"
    echo ""
    echo -e "${BLUE}======================${PLAIN}"
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

ensure_script_file() {
    if [ -f "$TARGET_PATH" ]; then return 0; fi
    # 简单的自我复制逻辑，如果是在安装
    cp "$0" "$TARGET_PATH"; chmod +x "$TARGET_PATH"
}

# === 源管理模块 ===

save_config_var() {
    local key=$1
    local val=$2
    if grep -q "^${key}=" "$CONF_FILE"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$CONF_FILE"
    else
        echo "${key}=${val}" >> "$CONF_FILE"
    fi
}

menu_source_manager() {
    while true; do
        load_config
        clear
        echo -e "${BLUE}╔════════════════════════════════════════╗${PLAIN}"
        echo -e "${BLUE}║             下载源管理系统             ║${PLAIN}"
        echo -e "${BLUE}╚════════════════════════════════════════╝${PLAIN}"
        echo -e ""
        
        local current_display="内置默认源池 (自动轮询)"
        if [ "$ACTIVE_URL_MODE" == "CUSTOM" ]; then
            current_display="${GREEN}自定义源${PLAIN}: ${CUSTOM_URL_VAL:0:40}..."
        else
            current_display="${YELLOW}默认源池${PLAIN}"
        fi
        
        echo -e " 当前策略: $current_display"
        echo -e ""
        echo -e " 1. 查看/切换 使用源"
        echo -e " 2. 添加 自定义源"
        echo -e " 3. 删除 自定义源"
        echo -e " 0. 返回主菜单"
        echo -e ""
        read -p " 请输入选项: " s_choice
        
        case $s_choice in
            1)
                echo -e "\n请选择要使用的源："
                echo -e " 0) ${YELLOW}恢复默认 (内置源池)${PLAIN}"
                
                # 读取列表
                local i=1
                local urls=()
                if [ -f "$SOURCE_LIST_FILE" ]; then
                    while IFS= read -r line; do
                        [ -z "$line" ] && continue
                        urls+=("$line")
                        echo -e " $i) $line"
                        ((i++))
                    done < "$SOURCE_LIST_FILE"
                fi
                
                echo ""
                read -p " 请输入序号: " pick
                if [ "$pick" == "0" ]; then
                    save_config_var "ACTIVE_URL_MODE" "DEFAULT"
                    echo -e "${GREEN}已切换为默认源池。${PLAIN}"
                elif [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -le "${#urls[@]}" ] && [ "$pick" -gt 0 ]; then
                    local selected="${urls[$((pick-1))]}"
                    save_config_var "ACTIVE_URL_MODE" "CUSTOM"
                    save_config_var "CUSTOM_URL_VAL" "$selected"
                    echo -e "${GREEN}已切换为: $selected${PLAIN}"
                else
                    echo -e "${RED}输入无效${PLAIN}"
                fi
                systemctl restart traffic_balancer
                read -p " 按回车继续..."
                ;;
            2)
                echo -e "\n请输入新的下载链接 (http/https):"
                read -p " URL: " new_url
                if [[ "$new_url" =~ ^http ]]; then
                    echo "$new_url" >> "$SOURCE_LIST_FILE"
                    echo -e "${GREEN}添加成功！${PLAIN}"
                    read -p " 是否立即使用该源? (y/n): " use_now
                    if [[ "$use_now" == "y" ]]; then
                        save_config_var "ACTIVE_URL_MODE" "CUSTOM"
                        save_config_var "CUSTOM_URL_VAL" "$new_url"
                        systemctl restart traffic_balancer
                    fi
                else
                    echo -e "${RED}URL 格式错误${PLAIN}"
                fi
                ;;
            3)
                if [ ! -f "$SOURCE_LIST_FILE" ] || [ ! -s "$SOURCE_LIST_FILE" ]; then
                    echo -e "${RED}没有已保存的自定义源。${PLAIN}"
                else
                    echo -e "\n删除模式："
                    local i=1
                    while IFS= read -r line; do
                        echo -e " $i) $line"
                        ((i++))
                    done < "$SOURCE_LIST_FILE"
                    read -p " 请输入要删除的序号: " del_idx
                    if [[ "$del_idx" =~ ^[0-9]+$ ]]; then
                        sed -i "${del_idx}d" "$SOURCE_LIST_FILE"
                        echo -e "${GREEN}删除成功${PLAIN}"
                        # 如果删除的是当前正在用的，回退到默认
                        load_config
                        if [ "$ACTIVE_URL_MODE" == "CUSTOM" ]; then
                            # 简单处理：重置为默认，防止指向空
                            save_config_var "ACTIVE_URL_MODE" "DEFAULT"
                            echo -e "${YELLOW}当前使用的源已被删除，已自动重置为默认源池。${PLAIN}"
                            systemctl restart traffic_balancer
                        fi
                    fi
                fi
                read -p " 按回车继续..."
                ;;
            0) break ;;
            *) ;;
        esac
    done
}

install_service() {
    check_dependencies; mkdir -p "$WORK_DIR"; touch "$LOG_FILE"; touch "$SOURCE_LIST_FILE"
    ensure_script_file
    
    # === 初始化配置逻辑 ===
    echo "TARGET_RATIO=$DEFAULT_RATIO" > "$CONF_FILE"
    echo "MAX_SPEED_MBPS=$DEFAULT_MAX_SPEED_MBPS" >> "$CONF_FILE"
    
    echo -e "${YELLOW}正在探测网络环境...${PLAIN}"
    local detected=$(detect_region)
    echo -e " 检测到区域: ${BOLD}$detected${PLAIN}"
    
    echo -e " 请选择服务器所在区域 (决定默认下载源):"
    echo -e "  1. 国内 (CN)"
    echo -e "  2. 国际 (Global)"
    read -p " 请输入 [默认 $detected]: " region_choice

    local final_region=$detected
    if [ "$region_choice" == "1" ]; then final_region="CN"; 
    elif [ "$region_choice" == "2" ]; then final_region="GLOBAL"; fi
    
    echo "REGION=$final_region" >> "$CONF_FILE"
    
    echo -e ""
    echo -e "${YELLOW}请设置下载文件地址 (可选)${PLAIN}"
    echo -e " 说明：请输入一个用于消耗流量的大文件直链。"
    echo -e " 留空 = 使用脚本内置的 ${final_region} 源池。"
    read -p " URL: " custom_url_input
    
    if [ ! -z "$custom_url_input" ]; then
        echo "$custom_url_input" >> "$SOURCE_LIST_FILE"
        echo "ACTIVE_URL_MODE=CUSTOM" >> "$CONF_FILE"
        echo "CUSTOM_URL_VAL=$custom_url_input" >> "$CONF_FILE"
        echo -e "${GREEN}已配置自定义源。${PLAIN}"
    else
        echo "ACTIVE_URL_MODE=DEFAULT" >> "$CONF_FILE"
        echo "CUSTOM_URL_VAL=" >> "$CONF_FILE"
        echo -e "${GREEN}已配置为内置默认源。${PLAIN}"
    fi

    # 生成服务文件
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
    if [ -f "$TARGET_PATH" ]; then
        rm -f /usr/bin/tb
        ln -sf "$TARGET_PATH" /usr/bin/tb
        chmod +x /usr/bin/tb
    fi
    echo -e "${GREEN}安装完成！请输入 tb 打开菜单${PLAIN}"
    read -p "按回车继续..."
}

set_parameters() {
    load_config; clear
    echo -e "${BLUE}╔════════════════════════════════════════╗${PLAIN}"
    echo -e "${BLUE}║            参数配置向导                ║${PLAIN}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${PLAIN}"
    echo -e " 当前状态: 比例 1:${TARGET_RATIO} | 限速 ${MAX_SPEED_MBPS} Mbps"
    echo -e ""
    echo -e "${YELLOW}1. 设置下行比例${PLAIN} (如 1.5)"
    read -p "   请输入 (留空跳过): " input_ratio
    echo -e ""
    echo -e "${YELLOW}2. 设置速度限制${PLAIN} (如 100M, 1G)"
    read -p "   请输入 (留空跳过): " input_speed
    
    if [[ ! -z "$input_ratio" ]]; then
        local clean_val=$(echo "$input_ratio" | sed 's/^1://')
        if [[ "$clean_val" =~ ^[0-9]+([.][0-9]+)?$ ]]; then save_config_var "TARGET_RATIO" "$clean_val"; fi
    fi
    if [[ ! -z "$input_speed" ]]; then
        local converted=$(convert_to_mb "$input_speed")
        if [[ "$converted" =~ ^[0-9]+$ ]]; then save_config_var "MAX_SPEED_MBPS" "$converted"; fi
    fi
    
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
    systemctl stop traffic_balancer
    systemctl disable traffic_balancer
    pkill -f "balancer.sh"
    rm -f "$SERVICE_FILE" "$LOG_FILE"
    rm -rf "$WORK_DIR"
    rm -f "$TARGET_PATH" 
    rm -f "/usr/bin/tb" 
    systemctl daemon-reload
    echo -e "${GREEN}已清理卸载完成。${PLAIN}"
    exit 0
}

show_menu() {
    while true; do
        load_config
        
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
             local source_status="内置默认"
             [ "$ACTIVE_URL_MODE" == "CUSTOM" ] && source_status="自定义源"
             echo -e " 当前策略:"
             echo -e "   目标比例 : ${BOLD}1 : ${TARGET_RATIO}${PLAIN}"
             echo -e "   速度限制 : ${BOLD}${MAX_SPEED_MBPS} Mbps${PLAIN}"
             echo -e "   当前源   : ${BOLD}${source_status}${PLAIN}"
             echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        fi

        echo -e " 1. 安装并启动服务"
        echo -e " 2. 修改策略 (比例 / 速度)"
        echo -e " 3. 实时监控面板"
        echo -e " 4. ${YELLOW}下载源管理${PLAIN}"
        echo -e " 5. 查看运行日志"
        echo -e " 6. 重启服务"
        echo -e " 7. 停止服务"
        echo -e " 8. 卸载并清理"
        echo -e " 0. 退出"
        echo -e ""
        read -p " 请输入选项 [0-8]: " choice
        
        case $choice in
            1) install_service ;;
            2) require_install && set_parameters ;;
            3) require_install && monitor_dashboard ;;
            4) require_install && menu_source_manager ;;
            5) view_logs ;;
            6) require_install && systemctl restart traffic_balancer && echo "已重启" && sleep 1 ;;
            7) require_install && systemctl stop traffic_balancer && echo "已停止" && sleep 1 ;;
            8) uninstall_clean ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

if [[ "$1" == "--worker" ]]; then run_worker; else
    if [[ $EUID -ne 0 ]]; then echo "请使用root运行"; exit 1; fi
    show_menu
fi
