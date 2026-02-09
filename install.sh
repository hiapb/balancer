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

UPDATE_URL="https://raw.githubusercontent.com/hiapb/balancer/main/install.sh"

# === 默认配置 ===
DEFAULT_RATIO=1.2
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
        # 默认值
        TARGET_RATIO=$DEFAULT_RATIO
        MAX_SPEED_MBPS=$DEFAULT_MAX_SPEED_MBPS
        REGION="GLOBAL"
        ACTIVE_URL_MODE="DEFAULT"
        CUSTOM_URL_VAL=""
    fi
    [ -z "$MAX_SPEED_MBPS" ] && MAX_SPEED_MBPS=100
    [ -z "$ACTIVE_URL_MODE" ] && ACTIVE_URL_MODE="DEFAULT"
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# === 核心 Worker ===
download_noise() {
    local NEED_MB=$1; local CURRENT_REGION=$2; local SPEED_LIMIT_MBPS=$3
    local RATE_LIMIT_MB=$(awk -v bw="$SPEED_LIMIT_MBPS" 'BEGIN {printf "%.2f", bw/8}')
    local RATE_LIMIT_BYTES=$(awk -v mb="$RATE_LIMIT_MB" 'BEGIN {printf "%.0f", mb*1048576}')
    local url=""
    
    if [ "$ACTIVE_URL_MODE" == "CUSTOM" ] && [ ! -z "$CUSTOM_URL_VAL" ]; then
        url="$CUSTOM_URL_VAL"
        if [[ ! $url =~ ^http ]]; then log "[警告] 自定义URL无效，回退"; url=""; fi
    fi

    if [ -z "$url" ]; then
        local target_urls
        if [ "$CURRENT_REGION" == "CN" ]; then target_urls=("${DEFAULT_URLS_CN[@]}")
        else target_urls=("${DEFAULT_URLS_GLOBAL[@]}"); fi
        local rand_idx=$(($RANDOM % ${#target_urls[@]}))
        url=${target_urls[$rand_idx]}
    fi
    
    log "[执行] 缺口:${NEED_MB}MB | 限速:${SPEED_LIMIT_MBPS}Mbps | 目标:$(echo $url | awk -F/ '{print $3}')"
    curl -L -k -4 -s -o /dev/null --limit-rate "$RATE_LIMIT_BYTES" --max-time 600 --retry 3 "$url"
}

run_worker() {
    load_config
    [ -z "$REGION" ] && echo "REGION=$(detect_region)" >> "$CONF_FILE"
    log "[启动] 模式:限速下载 | 目标 1:$TARGET_RATIO | 限速 ${MAX_SPEED_MBPS}Mbps"
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

monitor_dashboard() {
    clear; echo "初始化数据..."; local r1=$(get_bytes rx); local t1=$(get_bytes tx)
    while true; do
        read -t 1 -n 1 key; if [[ $? -eq 0 ]]; then break; fi
        local r2=$(get_bytes rx); local t2=$(get_bytes tx)
        local r_speed=$((r2 - r1)); local t_speed=$((t2 - t1))
        r1=$r2; t1=$t2
        clear
        echo -e "${BLUE}=== 实时监控 (按任意键返回) ===${PLAIN}"
        echo -e " ⬇️  下载: ${GREEN}$(format_size $r_speed)/s${PLAIN} (总: $(format_size $r2))"
        echo -e " ⬆️  上传: ${YELLOW}$(format_size $t_speed)/s${PLAIN} (总: $(format_size $t2))"
    done
}

view_logs() {
    clear; echo -e "${BLUE}=== 日志 (后50条) ===${PLAIN}"
    [ -f "$LOG_FILE" ] && tail -n 50 "$LOG_FILE" || echo "无日志"
    echo ""; read -n 1 -s -r -p "按任意键返回..."
}

# === 核心逻辑修复 ===
ensure_script_file() {
    
    if [ -f "$0" ]; then
        cp "$0" "$TARGET_PATH"
    else
        echo -e "${YELLOW}检测到一键脚本运行，正在拉取最新版本...${PLAIN}"
        curl -o "$TARGET_PATH" -fsSL "$UPDATE_URL"
        if [ ! -s "$TARGET_PATH" ]; then
            echo -e "${RED}下载失败，请检查网络或 URL。${PLAIN}"
            exit 1
        fi
        echo -e "${GREEN}脚本下载成功。${PLAIN}"
    fi
    chmod +x "$TARGET_PATH"
}

install_service() {
    check_dependencies; mkdir -p "$WORK_DIR"; touch "$LOG_FILE"; touch "$SOURCE_LIST_FILE"
    
    ensure_script_file
    
    echo "TARGET_RATIO=$DEFAULT_RATIO" > "$CONF_FILE"
    echo "MAX_SPEED_MBPS=$DEFAULT_MAX_SPEED_MBPS" >> "$CONF_FILE"
    
    echo -e "${YELLOW}正在探测区域...${PLAIN}"
    local detected=$(detect_region)
    echo -e " 检测到: $detected"
    echo -e " 请选择源区域:"
    echo -e "  1. 国内 (CN)"
    echo -e "  2. 国际 (Global)"
    read -p " 输入 [默认 $detected]: " rc
    local fr=$detected
    [ "$rc" == "1" ] && fr="CN"; [ "$rc" == "2" ] && fr="GLOBAL"
    echo "REGION=$fr" >> "$CONF_FILE"
    
    echo -e " 请输入下载文件直链 (留空使用内置):"
    read -p " URL: " curl_val
    if [ ! -z "$curl_val" ]; then
        echo "ACTIVE_URL_MODE=CUSTOM" >> "$CONF_FILE"
        echo "CUSTOM_URL_VAL=$curl_val" >> "$CONF_FILE"
        echo "$curl_val" >> "$SOURCE_LIST_FILE"
    else
        echo "ACTIVE_URL_MODE=DEFAULT" >> "$CONF_FILE"
    fi

    # 写入服务
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
    rm -f /usr/bin/tb; ln -sf "$TARGET_PATH" /usr/bin/tb; chmod +x /usr/bin/tb
    
    echo -e "${GREEN}安装完成！请输入 tb 管理${PLAIN}"
    read -p "按回车继续..."
}

set_parameters() {
    load_config; clear
    echo -e "${BLUE}=== 参数设置 ===${PLAIN}"
    echo -e "当前: 1:$TARGET_RATIO | ${MAX_SPEED_MBPS}Mbps"
    read -p "设置下行比例 (如 1.5, 留空跳过): " nr
    read -p "设置速度限制 (如 200M, 留空跳过): " ns
    
    if [ ! -z "$nr" ]; then 
        clean_nr=$(echo "$nr" | sed 's/^1://')
        save_config_var "TARGET_RATIO" "$clean_nr"
    fi
    if [ ! -z "$ns" ]; then 
        conv_ns=$(echo "$ns" | tr 'a-z' 'A-Z' | sed 's/[GM]//g')
        [[ "$ns" == *"G"* ]] && conv_ns=$(awk -v v="$conv_ns" 'BEGIN {printf "%.0f", v*1024}')
        save_config_var "MAX_SPEED_MBPS" "$conv_ns"
    fi
    systemctl restart traffic_balancer
    echo "已更新"; read -p "回车返回..."
}

save_config_var() {
    local k=$1; local v=$2
    grep -q "^${k}=" "$CONF_FILE" && sed -i "s|^${k}=.*|${k}=${v}|" "$CONF_FILE" || echo "${k}=${v}" >> "$CONF_FILE"
}

menu_source_manager() {
    while true; do
        load_config; clear
        local st="内置默认"; [ "$ACTIVE_URL_MODE" == "CUSTOM" ] && st="自定义"
        echo -e "${BLUE}=== 源管理 (当前: $st) ===${PLAIN}"
        echo " 1. 切换/选择源"
        echo " 2. 添加源"
        echo " 3. 删除源"
        echo " 0. 返回"
        read -p " 选项: " opt
        case $opt in
            1) 
                echo -e " 0) 恢复默认内置"; local i=1; local urls=()
                while read -r l; do [ -z "$l" ] && continue; urls+=("$l"); echo " $i) $l"; ((i++)); done < "$SOURCE_LIST_FILE"
                read -p " 序号: " p
                if [ "$p" == "0" ]; then save_config_var "ACTIVE_URL_MODE" "DEFAULT"; else
                    idx=$((p-1)); [ ! -z "${urls[$idx]}" ] && { save_config_var "ACTIVE_URL_MODE" "CUSTOM"; save_config_var "CUSTOM_URL_VAL" "${urls[$idx]}"; }
                fi
                systemctl restart traffic_balancer; read -p "回车..." ;;
            2) read -p " URL: " u; [ ! -z "$u" ] && echo "$u" >> "$SOURCE_LIST_FILE" && echo "已添加"; read -p "回车..." ;;
            3) read -p " 删除序号: " d; sed -i "${d}d" "$SOURCE_LIST_FILE" 2>/dev/null; echo "已删除"; read -p "回车..." ;;
            0) break ;;
        esac
    done
}

uninstall_clean() {
    systemctl stop traffic_balancer; systemctl disable traffic_balancer
    rm -f "$SERVICE_FILE" "$LOG_FILE" "$TARGET_PATH" "/usr/bin/tb"; rm -rf "$WORK_DIR"
    systemctl daemon-reload; echo "已卸载"; exit 0
}

show_menu() {
    while true; do
        load_config; clear
        local iface=$(get_interface); local rx=$(get_bytes rx); local tx=$(get_bytes tx)
        local s_icon="${RED}未安装${PLAIN}"; is_installed && s_icon="${GREEN}运行中${PLAIN}"
        ! systemctl is-active --quiet traffic_balancer && [ -f "$CONF_FILE" ] && s_icon="${YELLOW}已停止${PLAIN}"

        echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "${BLUE}     Traffic Balancer Pro     ${PLAIN}"
        echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e " 状态: $s_icon | 区域: ${GREEN}$REGION${PLAIN} | 网卡: $iface"
        echo -e " 流量: ⬆️ ${YELLOW}$(format_size $tx)${PLAIN}  ⬇️ ${GREEN}$(format_size $rx)${PLAIN}"
        if is_installed; then
            echo -e " 策略: 1:$TARGET_RATIO | Limit: ${MAX_SPEED_MBPS}Mbps"
        fi
        echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo " 1. 安装启动服务"
        echo " 2. 修改策略"
        echo " 3. 监控面板"
        echo " 4. 源管理"
        echo " 5. 查看日志"
        echo " 6. 重启服务"
        echo " 7. 停止服务"
        echo " 8. 卸载"
        echo " 0. 退出"
        read -p " 选项: " c
        case $c in
            1) install_service ;;
            2) require_install && set_parameters ;;
            3) require_install && monitor_dashboard ;;
            4) require_install && menu_source_manager ;;
            5) view_logs ;;
            6) require_install && systemctl restart traffic_balancer && echo "OK" && sleep 1 ;;
            7) require_install && systemctl stop traffic_balancer && echo "OK" && sleep 1 ;;
            8) uninstall_clean ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

is_installed() { [ -f "$CONF_FILE" ] && [ -f "$SERVICE_FILE" ]; }
require_install() { if ! is_installed; then echo "请先安装"; read -p "..."; return 1; fi; }

if [[ "$1" == "--worker" ]]; then run_worker; else
    [ $EUID -ne 0 ] && echo "Root required" && exit 1
    show_menu
fi
