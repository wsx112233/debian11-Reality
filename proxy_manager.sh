#!/usr/bin/env bash
set -euo pipefail
readonly SCRIPT_VERSION="1.8.1"
# 完整导入链接默认不打印到终端（防截图）；UUID/端口/path 等正常显示
# 链接明文：菜单确认 / SHOW_LINKS=1 / --show-links
SHOW_LINKS="${SHOW_LINKS:-0}"
# Cloudflare 橙云 HTTPS 回源端口（本脚本 VLESS+WS 固定 SSL=Full，源站必须 TLS）
# https://developers.cloudflare.com/fundamentals/reference/network-ports/
# 优先 8443（443 常被宝塔/nginx 占用）
readonly CF_HTTPS_ORIGIN_PORTS=(8443 2053 2083 2087 2096 443)
# 保留 HTTP 列表仅用于诊断提示（不再作为安装选项）
readonly CF_HTTP_ORIGIN_PORTS=(80 8080 8880 2052 2082 2086 2095)
readonly SANDBOX_ROOT="/etc/vps_proxy_mgr"
readonly BIN_DIR="/usr/local/bin"
readonly XRAY_BIN="${BIN_DIR}/vps_xray"
readonly HY2_BIN="${BIN_DIR}/vps_hysteria"
readonly XRAY_DIR="${SANDBOX_ROOT}/xray"
readonly HY2_DIR="${SANDBOX_ROOT}/hysteria2"
readonly OPT_DIR="${SANDBOX_ROOT}/optimize"
readonly LOG_DIR="${SANDBOX_ROOT}/logs"
readonly CACHE_DIR="${SANDBOX_ROOT}/cache"
readonly SHARE_DIR="${SANDBOX_ROOT}/share"
readonly STATE_FILE="${SANDBOX_ROOT}/state.env"
readonly WARP_DIR="${SANDBOX_ROOT}/warp"
readonly SHARE_LINKS="${SHARE_DIR}/client-links.txt"

# 安装速度相关：缓存 TTL（秒）
readonly IP_CACHE_TTL=600
readonly APT_CACHE_TTL=1800
readonly VER_CACHE_TTL=3600
readonly SNI_PROBE_TIMEOUT=3
readonly SNI_PROBE_PARALLEL=6
# 大文件下载：连接 15s，整体 10 分钟（弱网/镜像慢）
readonly DL_CONNECT_TIMEOUT=15
readonly DL_MAX_TIME=600

readonly XRAY_SVC="xray-custom.service"
readonly HY2_SVC="hy2-custom.service"
readonly SYSCTL_FILE="/etc/sysctl.d/99-vps-proxy-mgr.conf"

readonly XRAY_GITHUB_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly HY2_GITHUB_API="https://api.github.com/repos/apernet/hysteria/releases/latest"

readonly SNI_POOL=(
  "www.apple.com"
  "www.icloud.com"
  "www.google.com"
  "www.cloudflare.com"
  "www.amazon.com"
  "www.yahoo.com"
  "www.fastly.com"
  "gateway.icloud.com"
  "www.swcdn.net"
  "cdnjs.cloudflare.com"
  "www.gstatic.com"
  "dl.google.com"
  "www.nvidia.com"
  "www.amd.com"
  "www.samsung.com"
)

readonly TG_CIDRS=(
  "91.108.4.0/22"
  "91.108.8.0/22"
  "91.108.12.0/22"
  "91.108.16.0/22"
  "91.108.20.0/22"
  "91.108.56.0/22"
  "149.154.160.0/20"
  "149.154.164.0/22"
  "149.154.168.0/22"
  "149.154.172.0/22"
  "2001:67c:4e8::/48"
  "2001:b28:f23c::/48"
  "2001:b28:f23d::/48"
  "2001:b28:f23f::/48"
)

# 颜色 / 样式
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_MAGENTA='\033[0;35m'
readonly C_CYAN='\033[0;36m'
readonly C_WHITE='\033[1;37m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'
readonly C_BG='\033[48;5;236m'

readonly PORT_HIGH_MIN=20000
readonly PORT_HIGH_MAX=60000

#-------------------------------------------------------------------------------
#  日志与 UI（日志一律 stderr，避免污染 ver=$(cmd) 等命令替换）
#-------------------------------------------------------------------------------
log_info()  { echo -e "  ${C_CYAN}●${C_RESET} $*" >&2; }
log_ok()    { echo -e "  ${C_GREEN}✔${C_RESET} $*" >&2; }
log_warn()  { echo -e "  ${C_YELLOW}!${C_RESET} $*" >&2; }
log_err()   { echo -e "  ${C_RED}✘${C_RESET} $*" >&2; }
log_step()  { echo -e "\n  ${C_MAGENTA}▸${C_RESET} ${C_BOLD}$*${C_RESET}" >&2; }
log_tip()   { echo -e "  ${C_DIM}· $*${C_RESET}" >&2; }

die() {
  log_err "$*"
  exit 1
}

hr() {
  echo -e "  ${C_DIM}────────────────────────────${C_RESET}"
}

ui_section() {
  echo
  echo -e "  ${C_BOLD}$1${C_RESET}"
  hr
}

# 紧凑状态徽章（纯文本，兼容无 Unicode 终端）
badge_run()  { echo -e "${C_GREEN}● 运行${C_RESET}"; }
badge_stop() { echo -e "${C_YELLOW}○ 停止${C_RESET}"; }
badge_off()  { echo -e "${C_DIM}· 未装${C_RESET}"; }

pause_return() {
  echo
  _tty_read "$(echo -e "  ${C_DIM}按 Enter 返回主菜单…${C_RESET}")" >/dev/null || true
}

# 安装前轻量预检
preflight() {
  local ok=1
  command -v curl &>/dev/null || { log_warn "缺少 curl"; ok=0; }
  command -v systemctl &>/dev/null || { log_err "需要 systemd"; return 1; }
  local free_kb
  free_kb=$(df -Pk /usr/local 2>/dev/null | awk 'NR==2{print $4}' || echo 999999)
  if [[ "$free_kb" =~ ^[0-9]+$ ]] && (( free_kb < 102400 )); then
    log_warn "磁盘空间偏低（/usr/local 可用 <100MB）"
  fi
  # 预热公网 IP 缓存（后台，不阻塞）
  ( get_public_ipv4 &>/dev/null || true ) &
  ( get_public_ipv6 &>/dev/null || true ) &
  return 0
}

# ---------- 导入链接：终端默认隐藏，其余参数正常显示 ----------
links_visible() {
  [[ "${SHOW_LINKS}" == "1" || "${SHOW_LINKS}" == "true" || "${SHOW_LINKS}" == "yes" ]]
}

mask_link() {
  local link="${1:-}"
  if [[ "$link" =~ ^(vless|hysteria2|hy2)://([^@]+)@([^?/]+) ]]; then
    echo "${BASH_REMATCH[1]}://***@${BASH_REMATCH[3]}  ${C_DIM}(完整链接见文件)${C_RESET}"
    return 0
  fi
  echo "${C_DIM}(完整链接见文件)${C_RESET}"
}

maybe_show_links() {
  if links_visible; then
    return 0
  fi
  echo
  log_tip "完整导入链接默认写入文件，终端不打印（防截图）"
  if confirm "是否在本终端显示完整导入链接？"; then
    SHOW_LINKS=1
  fi
}

# 普通参数行（始终明文）
emit_line() {
  echo -e "  $1 $2"
}

emit_link_block() {
  local title="$1" link="$2"
  share_append_link "$title" "$link"
  if links_visible; then
    echo -e "  ${C_CYAN}${title}${C_RESET}"
    echo "  $link"
    echo
    print_qr "$link" "$title"
  else
    echo -e "  ${C_CYAN}${title}${C_RESET}  $(mask_link "$link")"
  fi
}

share_write_header() {
  mkdir -p "$SHARE_DIR"
  {
    echo "# VPS Proxy Manager v${SCRIPT_VERSION} · $(date '+%F %T %z')"
    echo "# 完整导入链接 · chmod 600 · 卸载协议时会清理"
    echo "# sudo cat ${SHARE_LINKS}"
    echo
  } > "$SHARE_LINKS"
  chmod 600 "$SHARE_LINKS"
}

share_append_link() {
  local title="$1" link="$2"
  mkdir -p "$SHARE_DIR"
  [[ -f "$SHARE_LINKS" ]] || share_write_header
  {
    echo "## ${title}"
    echo "${link}"
    echo
  } >> "$SHARE_LINKS"
  chmod 600 "$SHARE_LINKS"
}

share_flush_notice() {
  if [[ -f "$SHARE_LINKS" ]]; then
    chmod 600 "$SHARE_LINKS"
    log_ok "完整链接: sudo cat ${SHARE_LINKS}"
  fi
}

# 按当前已装协议重写分享文件；无协议则删除分享文件
refresh_share_file() {
  if ! any_protocol_installed; then
    rm -rf "$SHARE_DIR"
    return 0
  fi
  local old_show="${SHOW_LINKS}"
  SHOW_LINKS=0
  share_write_header
  # 静默重建（不刷屏）
  if is_reality_installed; then
    local ip l
    ip=$(get_public_ip)
    l=$(build_vless_link "$ip")
    share_append_link "REALITY" "$l"
  fi
  if is_ws_installed; then
    local host l2 l3 ip4
    host=$(state_get "XRAY_WS_HOST")
    l2=$(build_ws_link "$host")
    share_append_link "VLESS-WS-CF" "$l2"
    ip4=$(get_public_ipv4 2>/dev/null || true)
    l3=$(build_ws_link "${ip4:-$host}" "direct")
    share_append_link "VLESS-WS-direct" "$l3"
  fi
  if is_hy2_installed; then
    local ip l
    ip=$(get_public_ip)
    l=$(build_hy2_link "$ip")
    share_append_link "Hysteria2" "${l%%#*}"
  fi
  SHOW_LINKS="$old_show"
  chmod 600 "$SHARE_LINKS" 2>/dev/null || true
}

# 脚本产生的全部残留清理（无协议时 / 全清时）
purge_all_script_artifacts() {
  log_step "清理脚本产生的全部文件"
  remove_hy2_port_hop 2>/dev/null || true
  fw_remove_all_recorded 2>/dev/null || true
  if svc_exists "$XRAY_SVC"; then
    systemctl stop "$XRAY_SVC" 2>/dev/null || true
    systemctl disable "$XRAY_SVC" 2>/dev/null || true
    rm -f "/etc/systemd/system/${XRAY_SVC}"
  fi
  if svc_exists "$HY2_SVC"; then
    systemctl stop "$HY2_SVC" 2>/dev/null || true
    systemctl disable "$HY2_SVC" 2>/dev/null || true
    rm -f "/etc/systemd/system/${HY2_SVC}"
  fi
  systemctl daemon-reload 2>/dev/null || true
  rm -f "$XRAY_BIN" "$HY2_BIN"
  if [[ -f "$SYSCTL_FILE" ]]; then
    rm -f "$SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || true
  fi
  rm -f /etc/apt/sources.list.d/vps-cloudflare-warp.list 2>/dev/null || true
  # 整个沙盒：配置、日志、缓存、分享链接、证书等
  rm -rf "$SANDBOX_ROOT"
  log_ok "已清理 ${SANDBOX_ROOT}、二进制、systemd、sysctl、防火墙规则"
}

# 从终端读入（兼容 curl|bash / bash <(curl) 管道场景）
_tty_read() {
  local prompt="$1" reply=""
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt" reply < /dev/tty || true
  else
    read -r -p "$prompt" reply || true
  fi
  printf '%s' "$reply"
}

# 安全读取（兼容 set -u）
ask() {
  local prompt="$1"
  local default="${2:-}"
  local reply
  if [[ -n "$default" ]]; then
    reply=$(_tty_read "$(echo -e "  ${C_YELLOW}?${C_RESET} ${prompt} ${C_DIM}[${default}]${C_RESET}: ")")
    echo "${reply:-$default}"
  else
    reply=$(_tty_read "$(echo -e "  ${C_YELLOW}?${C_RESET} ${prompt}: ")")
    echo "${reply:-}"
  fi
}

confirm() {
  local prompt="$1"
  local reply
  reply=$(_tty_read "$(echo -e "  ${C_YELLOW}?${C_RESET} ${prompt} ${C_DIM}[y/N]${C_RESET}: ")")
  [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

# 随机高位端口（20000–60000，排除占用）
random_high_port() {
  local proto="${1:-tcp}" tries=0 port span r
  span=$((PORT_HIGH_MAX - PORT_HIGH_MIN + 1))
  while (( tries < 80 )); do
    r=$RANDOM
    # 两次 RANDOM 扩大范围，避免 15bit 偏差
    r=$(( (r << 15) ^ RANDOM ))
    port=$(( PORT_HIGH_MIN + (r % span + span) % span ))
    if ! port_in_use "$port" "$proto"; then
      echo "$port"
      return 0
    fi
    tries=$((tries + 1))
  done
  for port in $(seq "$PORT_HIGH_MIN" 97 "$PORT_HIGH_MAX"); do
    if ! port_in_use "$port" "$proto"; then
      echo "$port"
      return 0
    fi
  done
  die "无法找到空闲高位端口"
}

# 随机 WebSocket 路径
# 避免: /api /admin /wp- (WAF) · 避免 .png/.jpg/.css/.js (CF 易当静态缓存)
random_ws_path() {
  local a b c
  a=$(openssl rand -hex 6 2>/dev/null || printf '%x' $((RANDOM * RANDOM)))
  b=$(openssl rand -hex 4 2>/dev/null || printf '%x' $RANDOM)
  c=$(openssl rand -hex 3 2>/dev/null || printf '%x' $RANDOM)
  case $((RANDOM % 5)) in
    0) echo "/ray/${a}" ;;
    1) echo "/ws/${a}${b}" ;;
    2) echo "/vless/${a}" ;;
    3) echo "/tunnel/${a}/${b}" ;;
    *) echo "/${a}/${b}${c}" ;;
  esac
}

# 选端口：默认随机高位，回车采用；可输入自定义
# 提示打到 stderr，stdout 仅输出端口数字
pick_port() {
  local proto="$1" label="${2:-端口}"
  local suggested port
  suggested=$(random_high_port "$proto")
  echo -e "  ${C_DIM}${label} · ${proto^^} · 随机高位 ${suggested}${C_RESET}" >&2
  while true; do
    port=$(ask "端口（回车采用 ${suggested}）" "$suggested")
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      log_warn "请输入 1–65535" >&2
      continue
    fi
    if port_in_use "$port" "$proto"; then
      log_warn "端口 ${port}/${proto} 已被占用" >&2
      port_who "$port" "$proto" | sed 's/^/    /' >&2 || true
      if ! confirm "仍要使用？"; then
        suggested=$(random_high_port "$proto")
        echo -e "  ${C_DIM}重新生成: ${suggested}${C_RESET}" >&2
        continue
      fi
    fi
    printf '%s\n' "$port"
    return 0
  done
}

# 选 WS path：默认随机，可改（stdout 仅路径）
pick_ws_path() {
  local suggested path
  suggested=$(random_ws_path)
  echo -e "  ${C_DIM}WebSocket 路径 · 随机 ${suggested}${C_RESET}" >&2
  path=$(ask "路径（回车采用随机）" "$suggested")
  [[ "$path" == /* ]] || path="/${path}"
  path=$(echo "$path" | tr -d '[:space:]')
  printf '%s\n' "$path"
}

# 在端口数组中找第一个空闲
_first_free_port() {
  local p
  for p in "$@"; do
    if ! port_in_use "$p" "tcp"; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

_is_cf_https_port() {
  local p="$1" x
  for x in "${CF_HTTPS_ORIGIN_PORTS[@]}"; do [[ "$p" == "$x" ]] && return 0; done
  return 1
}

# VLESS+WS 固定 CF SSL=Full：源站 HTTPS + 自签证书，端口 ∈ CF HTTPS 列表
# stdout 仅端口；state: XRAY_WS_CF_MODE=https
pick_cf_origin_port() {
  local suggested p
  state_set "XRAY_WS_CF_MODE" "https"
  suggested=$(_first_free_port "${CF_HTTPS_ORIGIN_PORTS[@]}") || suggested="8443"
  log_tip "CF SSL=Full · 端口 ${CF_HTTPS_ORIGIN_PORTS[*]}"
  while true; do
    p=$(ask "源站端口" "$suggested")
    if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
      log_warn "请输入有效端口" >&2
      continue
    fi
    if ! _is_cf_https_port "$p"; then
      log_warn "${p} 不在 CF HTTPS 列表: ${CF_HTTPS_ORIGIN_PORTS[*]}" >&2
      if ! confirm "仍使用？（橙云 Full 通常失败）"; then continue; fi
    fi
    if port_in_use "$p" "tcp"; then
      log_warn "端口 ${p} 已被占用" >&2
      port_who "$p" "tcp" | sed 's/^/    /' >&2 || true
      if ! confirm "仍要使用？"; then
        suggested=$(_first_free_port "${CF_HTTPS_ORIGIN_PORTS[@]}") || suggested="8443"
        continue
      fi
    fi
    printf '%s\n' "$p"
    return 0
  done
}

# VLESS+WS 源站自签证书（CF Full 回源必需；Full strict 会失败）
gen_ws_origin_cert() {
  local cn="${1:-localhost}"
  mkdir -p "$XRAY_DIR"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 \
    -keyout "${XRAY_DIR}/ws-origin.key" \
    -out "${XRAY_DIR}/ws-origin.crt" \
    -subj "/CN=${cn}" \
    >/dev/null 2>&1
  chmod 600 "${XRAY_DIR}/ws-origin.key" "${XRAY_DIR}/ws-origin.crt"
  log_ok "源站 TLS 自签证书已生成（CN=${cn} · 配合 CF Full）"
}

# 生成随机字符串
rand_hex() {
  local len="${1:-16}"
  openssl rand -hex "$((len / 2))" 2>/dev/null || head -c "$((len / 2))" /dev/urandom | xxd -p | tr -d '\n'
}

rand_password() {
  local len="${1:-24}"
  # 避免 shell 特殊字符，便于 URL 编码
  openssl rand -base64 48 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$len"
}

# 判断是否为合法 IPv4
is_ipv4() {
  [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# 判断是否为可用公网 IPv6（排除 link-local / ULA 可选保留，此处接受全局与 ULA）
is_ipv6() {
  local ip="${1:-}"
  [[ -n "$ip" ]] || return 1
  # 粗检：含冒号且非 IPv4
  [[ "$ip" == *:* ]] || return 1
  # 排除 link-local fe80::/10、组播 ff00::/8、未指定
  [[ "$ip" == fe80:* || "$ip" == Fe80:* || "$ip" == FE80:* ]] && return 1
  [[ "$ip" == ff* || "$ip" == FF* ]] && return 1
  [[ "$ip" == "::" || "$ip" == "::1" ]] && return 1
  return 0
}

# 缓存读写（文件：值 + 时间戳）
cache_get() {
  local key="$1" ttl="${2:-600}" f now ts val
  f="${CACHE_DIR}/${key}"
  [[ -f "$f" ]] || return 1
  now=$(date +%s)
  ts=$(head -1 "$f" 2>/dev/null || echo 0)
  val=$(tail -n +2 "$f" 2>/dev/null | head -1 || true)
  [[ -n "$val" ]] || return 1
  if (( now - ts < ttl )); then
    echo "$val"
    return 0
  fi
  return 1
}

cache_set() {
  local key="$1" val="$2"
  mkdir -p "$CACHE_DIR"
  printf '%s\n%s\n' "$(date +%s)" "$val" > "${CACHE_DIR}/${key}"
  chmod 600 "${CACHE_DIR}/${key}" 2>/dev/null || true
}

# 内存档位：small(<1G) / medium(<4G) / large
mem_tier() {
  local kb mb
  kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  mb=$((kb / 1024))
  if (( mb < 1024 )); then
    echo "small"
  elif (( mb < 4096 )); then
    echo "medium"
  else
    echo "large"
  fi
}

# 网卡标称速率（Mbps），失败回退 1000
detect_nic_mbps() {
  local iface speed
  iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
  [[ -z "$iface" ]] && iface=$(ip -6 route show default 2>/dev/null | awk '{print $5; exit}')
  if [[ -n "$iface" && -r "/sys/class/net/${iface}/speed" ]]; then
    speed=$(cat "/sys/class/net/${iface}/speed" 2>/dev/null || echo -1)
    if [[ "$speed" =~ ^[0-9]+$ ]] && (( speed > 0 )); then
      echo "$speed"
      return 0
    fi
  fi
  echo "1000"
}

# 获取公网 IPv4（带缓存，短超时快速失败）
get_public_ipv4() {
  local ip cached
  cached=$(cache_get "public_ipv4" "$IP_CACHE_TTL" 2>/dev/null || true)
  if is_ipv4 "$cached"; then
    echo "$cached"
    return 0
  fi
  for url in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip"; do
    ip=$(curl -4 -fsSL --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
    if is_ipv4 "$ip"; then
      cache_set "public_ipv4" "$ip"
      echo "$ip"
      return 0
    fi
  done
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
  if is_ipv4 "$ip"; then
    cache_set "public_ipv4" "$ip"
    echo "$ip"
    return 0
  fi
  return 1
}

# 获取公网 IPv6（优先用于节点链接，带缓存）
get_public_ipv6() {
  local ip cached a
  cached=$(cache_get "public_ipv6" "$IP_CACHE_TTL" 2>/dev/null || true)
  if is_ipv6 "$cached"; then
    echo "$cached"
    return 0
  fi
  for url in \
    "https://api6.ipify.org" \
    "https://ipv6.icanhazip.com" \
    "https://ifconfig.co/ip" \
    "https://v6.ident.me"; do
    ip=$(curl -6 -fsSL --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
    if is_ipv6 "$ip"; then
      cache_set "public_ipv6" "$ip"
      echo "$ip"
      return 0
    fi
  done
  while read -r a; do
    a="${a%%/*}"
    if is_ipv6 "$a"; then
      cache_set "public_ipv6" "$a"
      echo "$a"
      return 0
    fi
  done < <(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' || true)
  ip=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
  if is_ipv6 "$ip"; then
    cache_set "public_ipv6" "$ip"
    echo "$ip"
    return 0
  fi
  return 1
}

# 主入口：有 IPv6 则优先 IPv6，否则 IPv4
get_public_ip() {
  local ip6 ip4
  ip6=$(get_public_ipv6 2>/dev/null || true)
  if is_ipv6 "$ip6"; then
    echo "$ip6"
    return 0
  fi
  ip4=$(get_public_ipv4 2>/dev/null || true)
  if is_ipv4 "$ip4"; then
    echo "$ip4"
    return 0
  fi
  echo "127.0.0.1"
}

# URI 主机格式化：IPv6 必须加方括号  [2001:db8::1]
format_host_for_uri() {
  local ip="${1:-}"
  if is_ipv6 "$ip"; then
    # 已带括号则原样
    if [[ "$ip" == \[*\] ]]; then
      echo "$ip"
    else
      echo "[${ip}]"
    fi
  else
    echo "$ip"
  fi
}

# 打印双栈地址摘要（优先行 + 备用行）
print_address_summary() {
  local primary ip4 ip6
  primary=$(get_public_ip)
  ip6=$(get_public_ipv6 2>/dev/null || true)
  ip4=$(get_public_ipv4 2>/dev/null || true)
  if is_ipv6 "$primary"; then
    echo -e "  地址(优先) : ${C_GREEN}${primary}${C_RESET}  ${C_DIM}[IPv6]${C_RESET}"
    [[ -n "$ip4" ]] && echo -e "  地址(备用) : ${ip4}  ${C_DIM}[IPv4]${C_RESET}"
  else
    echo -e "  地址(优先) : ${C_GREEN}${primary}${C_RESET}  ${C_DIM}[IPv4]${C_RESET}"
    if is_ipv6 "$ip6"; then
      echo -e "  地址(IPv6) : ${ip6}"
    else
      echo -e "  ${C_DIM}(未检测到公网 IPv6，已使用 IPv4)${C_RESET}"
    fi
  fi
}

# 检测架构
detect_arch() {
  local m
  m=$(uname -m)
  case "$m" in
    x86_64|amd64)  echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "不支持的 CPU 架构: $m（仅支持 x86_64 / arm64）" ;;
  esac
}

#-------------------------------------------------------------------------------
#  系统环境检测
#-------------------------------------------------------------------------------
check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 运行，一行安装：
  sudo bash <(curl -fsSL https://raw.githubusercontent.com/wsx112233/debian11-Reality/main/proxy_manager.sh)"
  fi
}

check_debian() {
  if [[ ! -f /etc/os-release ]]; then
    die "无法识别操作系统（缺少 /etc/os-release）"
  fi
  # shellcheck source=/dev/null
  . /etc/os-release
  if [[ "${ID:-}" != "debian" ]]; then
    log_err "本脚本仅支持 Debian 系统，当前系统: ${PRETTY_NAME:-unknown}"
    log_err "为避免破坏其他发行版，脚本将安全退出。"
    exit 1
  fi
  local ver
  ver="${VERSION_ID%%.*}"
  case "$ver" in
    11|12|13)
      log_ok "检测到 Debian ${VERSION_ID} (${VERSION_CODENAME:-}) · arch=$(detect_arch)"
      ;;
    *)
      log_warn "当前 Debian 版本 ${VERSION_ID} 未在测试矩阵中，将尝试继续（官方支持 11/12/13）"
      if ! confirm "是否继续？"; then
        exit 0
      fi
      ;;
  esac
}

ensure_sandbox() {
  mkdir -p "$SANDBOX_ROOT" "$XRAY_DIR" "$HY2_DIR" "$OPT_DIR" "$LOG_DIR" "$CACHE_DIR" "$SHARE_DIR"
  chmod 700 "$SANDBOX_ROOT"
  touch "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

# 是否仍有任一协议在装
any_protocol_installed() {
  [[ "$(state_get XRAY_INSTALLED)" == "1" ]] \
    || [[ "$(state_get XRAY_WS_INSTALLED)" == "1" ]] \
    || [[ "$(state_get HY2_INSTALLED)" == "1" ]] \
    || svc_exists "$XRAY_SVC" \
    || svc_exists "$HY2_SVC"
}

# 状态读写（简单 key=value）
state_set() {
  local key="$1" val="$2"
  ensure_sandbox
  if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
    # 使用临时文件避免 sed 破坏特殊字符
    local tmp
    tmp=$(mktemp)
    grep -v "^${key}=" "$STATE_FILE" > "$tmp" || true
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$STATE_FILE"
  fi
  chmod 600 "$STATE_FILE"
}

state_get() {
  local key="$1"
  if [[ -f "$STATE_FILE" ]]; then
    grep -E "^${key}=" "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true
  fi
}

#-------------------------------------------------------------------------------
#  依赖管理（仅按需安装，卸载不回滚 apt 包）
#-------------------------------------------------------------------------------
NEED_PKGS=()

pkg_missing() {
  ! command -v "$1" &>/dev/null
}

collect_deps() {
  NEED_PKGS=()
  local map=(
    "curl:curl"
    "wget:wget"
    "jq:jq"
    "openssl:openssl"
    "tar:tar"
    "unzip:unzip"
    "qrencode:qrencode"
    "iptables:iptables"
    "ss:iproute2"
    "systemctl:systemd"
    "gpg:gnupg"
  )
  if [[ ! -f /etc/ssl/certs/ca-certificates.crt ]]; then
    NEED_PKGS+=("ca-certificates")
  fi
  local item bin pkg
  for item in "${map[@]}"; do
    bin="${item%%:*}"
    pkg="${item##*:}"
    if pkg_missing "$bin"; then
      NEED_PKGS+=("$pkg")
    fi
  done
  # 去重
  if [[ ${#NEED_PKGS[@]} -gt 0 ]]; then
    mapfile -t NEED_PKGS < <(printf '%s\n' "${NEED_PKGS[@]}" | awk 'NF && !seen[$0]++')
  fi
  # ufw 不强制安装，仅在已存在时使用
}

# apt update 节流：会话内 / TTL 内只跑一次
apt_update_throttled() {
  local last now
  last=$(cache_get "apt_update_ts" "$APT_CACHE_TTL" 2>/dev/null || true)
  if [[ -n "$last" ]]; then
    log_info "跳过 apt update（${APT_CACHE_TTL}s 内已更新）"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  cache_set "apt_update_ts" "1"
}

install_deps() {
  collect_deps
  if [[ ${#NEED_PKGS[@]} -eq 0 ]]; then
    log_ok "标准依赖已齐全"
    return 0
  fi
  log_step "安装缺失依赖: ${NEED_PKGS[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt_update_throttled
  apt-get install -y -qq "${NEED_PKGS[@]}"
  log_ok "依赖安装完成"
}

#-------------------------------------------------------------------------------
#  服务状态
#-------------------------------------------------------------------------------
svc_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

svc_exists() {
  systemctl cat "$1" &>/dev/null
}

status_label() {
  local name="$1"  # xray | ws | hy2
  case "$name" in
    xray)
      if [[ "$(state_get XRAY_INSTALLED)" == "1" ]] && [[ -x "$XRAY_BIN" ]] && svc_exists "$XRAY_SVC"; then
        if svc_active "$XRAY_SVC"; then badge_run; else badge_stop; fi
      else
        badge_off
      fi
      ;;
    ws)
      if [[ "$(state_get XRAY_WS_INSTALLED)" == "1" ]] && [[ -x "$XRAY_BIN" ]] && svc_exists "$XRAY_SVC"; then
        if svc_active "$XRAY_SVC"; then badge_run; else badge_stop; fi
      else
        badge_off
      fi
      ;;
    hy2)
      if [[ "$(state_get HY2_INSTALLED)" == "1" ]] && [[ -x "$HY2_BIN" ]] && svc_exists "$HY2_SVC"; then
        if svc_active "$HY2_SVC"; then badge_run; else badge_stop; fi
      else
        badge_off
      fi
      ;;
  esac
}

# 状态行附加端口信息（主菜单用）
status_extra() {
  local name="$1"
  case "$name" in
    xray) [[ "$(state_get XRAY_INSTALLED)" == "1" ]] && echo " :$(state_get XRAY_PORT)" || true ;;
    ws)   [[ "$(state_get XRAY_WS_INSTALLED)" == "1" ]] && echo " :$(state_get XRAY_WS_PORT)$(state_get XRAY_WS_PATH)" || true ;;
    hy2)
      if [[ "$(state_get HY2_INSTALLED)" == "1" ]]; then
        if [[ "$(state_get HY2_HOP)" == "1" ]]; then
          echo " :$(state_get HY2_PORT) hop"
        else
          echo " :$(state_get HY2_PORT)/udp"
        fi
      fi
      ;;
  esac
}

#-------------------------------------------------------------------------------
#  端口检测
#-------------------------------------------------------------------------------
port_in_use() {
  local port="$1" proto="${2:-tcp}"
  if command -v ss &>/dev/null; then
    if [[ "$proto" == "tcp" ]]; then
      ss -lntn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && return 0
    else
      ss -lnun 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && return 0
    fi
  fi
  return 1
}

port_who() {
  local port="$1" proto="${2:-tcp}"
  if command -v ss &>/dev/null; then
    if [[ "$proto" == "tcp" ]]; then
      ss -lntp 2>/dev/null | grep -E "[:.]${port} " || true
    else
      ss -lnup 2>/dev/null | grep -E "[:.]${port} " || true
    fi
  fi
}

# 兼容旧名
prompt_port() {
  local proto="$1" _default="$2" label="${3:-端口}"
  pick_port "$proto" "$label"
}

#-------------------------------------------------------------------------------
#  防火墙（ufw / iptables / nftables 自动检测）
#-------------------------------------------------------------------------------
FW_BACKEND=""

detect_firewall() {
  local quiet="${1:-}"
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi "Status: active"; then
    FW_BACKEND="ufw"
  elif command -v nft &>/dev/null && nft list ruleset 2>/dev/null | grep -q .; then
    FW_BACKEND="nft"
  elif command -v iptables &>/dev/null; then
    FW_BACKEND="iptables"
  else
    FW_BACKEND="none"
  fi
  [[ "$quiet" == "quiet" ]] || log_info "防火墙后端: ${FW_BACKEND}"
}

# 从 FW_RULES 状态中剔除一条 port/proto 记录
fw_state_drop() {
  local port="$1" proto="$2"
  local rules new="" r
  rules=$(state_get "FW_RULES")
  IFS=',' read -ra arr <<< "$rules"
  for r in "${arr[@]}"; do
    [[ -z "$r" ]] && continue
    [[ "$r" == "${port}/${proto}" ]] && continue
    new+="${r},"
  done
  state_set "FW_RULES" "$new"
}

fw_allow() {
  local port="$1" proto="$2" comment="${3:-vps_proxy_mgr}"
  detect_firewall quiet
  case "$FW_BACKEND" in
    ufw)
      # ufw 规则默认覆盖 IPv4+IPv6（若 IPv6 已启用）
      ufw allow "${port}/${proto}" comment "$comment" >/dev/null 2>&1 || true
      log_ok "UFW 已放行 ${port}/${proto} (IPv4/IPv6)"
      ;;
    nft)
      # inet 表同时匹配 IPv4 + IPv6
      nft list table inet vps_proxy_mgr &>/dev/null || nft add table inet vps_proxy_mgr 2>/dev/null || true
      nft list chain inet vps_proxy_mgr input &>/dev/null || \
        nft 'add chain inet vps_proxy_mgr input { type filter hook input priority -10; policy accept; }' 2>/dev/null || true
      if ! nft list chain inet vps_proxy_mgr input 2>/dev/null | grep -qE "${proto} dport ${port}"; then
        nft add rule inet vps_proxy_mgr input "${proto}" dport "${port}" counter accept comment \""${comment}"\" 2>/dev/null || true
      fi
      log_ok "nftables 已放行 ${port}/${proto} (inet 双栈)"
      ;;
    iptables)
      if ! iptables -C INPUT -p "$proto" --dport "$port" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p "$proto" --dport "$port" -m comment --comment "$comment" -j ACCEPT
      fi
      # 同步 IPv6 规则
      if command -v ip6tables &>/dev/null; then
        if ! ip6tables -C INPUT -p "$proto" --dport "$port" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; then
          ip6tables -I INPUT -p "$proto" --dport "$port" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || true
        fi
      fi
      if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
      elif [[ -d /etc/iptables ]]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
      fi
      log_ok "iptables/ip6tables 已放行 ${port}/${proto}"
      ;;
    *)
      log_warn "未检测到活动防火墙，请手动放行 ${port}/${proto} (IPv4/IPv6)"
      ;;
  esac
  local rec
  rec=$(state_get "FW_RULES")
  if [[ ",${rec}," != *",${port}/${proto},"* ]]; then
    state_set "FW_RULES" "${rec}${port}/${proto},"
  fi
}

fw_remove() {
  local port="$1" proto="$2" comment="${3:-vps_proxy_mgr}"
  detect_firewall quiet
  case "$FW_BACKEND" in
    ufw)
      ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true
      log_ok "UFW 已移除 ${port}/${proto}"
      ;;
    nft)
      local handles h
      handles=$(nft -a list chain inet vps_proxy_mgr input 2>/dev/null \
        | grep -E "${proto} dport ${port}" \
        | grep -oE 'handle [0-9]+' \
        | awk '{print $2}' || true)
      for h in $handles; do
        nft delete rule inet vps_proxy_mgr input handle "$h" 2>/dev/null || true
      done
      if ! nft list chain inet vps_proxy_mgr input 2>/dev/null | grep -qE 'dport'; then
        nft delete table inet vps_proxy_mgr 2>/dev/null || true
      fi
      log_ok "nftables 已移除 ${port}/${proto}"
      ;;
    iptables)
      while iptables -C INPUT -p "$proto" --dport "$port" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -p "$proto" --dport "$port" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || break
      done
      if command -v ip6tables &>/dev/null; then
        while ip6tables -C INPUT -p "$proto" --dport "$port" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; do
          ip6tables -D INPUT -p "$proto" --dport "$port" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || break
        done
      fi
      if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
      fi
      log_ok "iptables/ip6tables 已移除 ${port}/${proto}"
      ;;
  esac
  fw_state_drop "$port" "$proto"
}

fw_remove_all_recorded() {
  local rules port proto r start end
  rules=$(state_get "FW_RULES")
  IFS=',' read -ra arr <<< "$rules"
  for r in "${arr[@]}"; do
    [[ -z "$r" ]] && continue
    # range:30000-32000/udp
    if [[ "$r" == range:* ]]; then
      r="${r#range:}"
      port="${r%/*}"
      proto="${r#*/}"
      start="${port%-*}"; end="${port#*-}"
      [[ "$proto" == "udp" ]] && fw_remove_udp_range "$start" "$end" "vps_proxy_mgr_hy2_hop" || true
      continue
    fi
    port="${r%/*}"
    proto="${r#*/}"
    case "$proto" in
      tcp)
        fw_remove "$port" "tcp" "vps_proxy_mgr_xray" || true
        fw_remove "$port" "tcp" "vps_proxy_mgr_ws" || true
        ;;
      udp) fw_remove "$port" "udp" "vps_proxy_mgr_hy2" || true ;;
      *)   fw_remove "$port" "$proto" "vps_proxy_mgr" || true ;;
    esac
  done
  remove_hy2_port_hop 2>/dev/null || true
  nft delete table inet vps_proxy_mgr 2>/dev/null || true
  state_set "FW_RULES" ""
}

#-------------------------------------------------------------------------------
#  SNI 校验与选取（并行探测，首个成功即返回）
#-------------------------------------------------------------------------------
check_sni_tls() {
  local sni="$1"
  local t="${SNI_PROBE_TIMEOUT}"
  # 单次探测：优先 TLS1.3；不用 -brief（Debian11 OpenSSL 1.1.1 无此选项）
  if echo | timeout "$t" openssl s_client -connect "${sni}:443" -servername "$sni" -tls1_3 \
      >/dev/null 2>&1; then
    return 0
  fi
  if echo | timeout "$t" openssl s_client -connect "${sni}:443" -servername "$sni" \
      >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

pick_sni() {
  local shuffled candidate result_file workdir pids=() pid winner=""
  # 已缓存的可用 SNI 直接复用（加速重装）
  winner=$(cache_get "good_sni" 86400 2>/dev/null || true)
  if [[ -n "$winner" && ! "$winner" =~ (microsoft|bing|azure|office) ]]; then
    log_ok "使用缓存 SNI: ${winner}"
    echo "$winner"
    return 0
  fi

  mapfile -t shuffled < <(printf '%s\n' "${SNI_POOL[@]}" | shuf 2>/dev/null || printf '%s\n' "${SNI_POOL[@]}")
  workdir=$(mktemp -d)
  result_file="${workdir}/winner"
  log_info "并行探测 SNI（最多 ${SNI_PROBE_PARALLEL} 路 · 超时 ${SNI_PROBE_TIMEOUT}s）..."

  local running=0
  for candidate in "${shuffled[@]}"; do
    if [[ "$candidate" =~ (microsoft|bing|azure|office|live\.com|msn\.com) ]]; then
      continue
    fi
    # 已有赢家则停止发新任务
    if [[ -f "$result_file" ]]; then
      break
    fi
    (
      if check_sni_tls "$candidate"; then
        # 原子写：首个成功者落盘
        printf '%s' "$candidate" > "${result_file}.${$}" 2>/dev/null || true
        mv -n "${result_file}.${$}" "$result_file" 2>/dev/null || true
      fi
    ) &
    pids+=($!)
    running=$((running + 1))
    # 控制并发
    if (( running >= SNI_PROBE_PARALLEL )); then
      if ! wait -n 2>/dev/null; then
        wait 2>/dev/null || true
      fi
      running=$((running - 1))
      [[ -f "$result_file" ]] && break
    fi
  done

  # 短暂等待首个结果
  local i
  for (( i=0; i<SNI_PROBE_TIMEOUT+2; i++ )); do
    if [[ -f "$result_file" ]]; then
      winner=$(cat "$result_file" 2>/dev/null || true)
      break
    fi
    sleep 0.3 2>/dev/null || sleep 1
  done

  # 杀掉残留探测
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -rf "$workdir"

  if [[ -n "$winner" ]]; then
    cache_set "good_sni" "$winner"
    log_ok "SNI 可用: ${winner}"
    echo "$winner"
    return 0
  fi
  log_warn "SNI 并行探测未命中，回退 www.apple.com"
  echo "www.apple.com"
}

#-------------------------------------------------------------------------------
#  下载工具（多镜像 + 校验 + 可续传）
#-------------------------------------------------------------------------------
# 粗检下载文件不是 HTML 错误页
_dl_looks_valid() {
  local f="$1" min_bytes="${2:-1000}"
  [[ -f "$f" && -s "$f" ]] || return 1
  local sz
  sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
  (( sz >= min_bytes )) || return 1
  # 排除明显 HTML/JSON 错误页
  if head -c 200 "$f" 2>/dev/null | grep -qiE '<!DOCTYPE|<html|Not Found|"message"'; then
    return 1
  fi
  return 0
}

# 规范化 release tag（只允许安全字符，防止日志/缓存污染）
sanitize_release_tag() {
  local t="${1:-}"
  # 去掉日志混入的控制字符与多余空白
  t=$(printf '%s' "$t" | tr -d '\r\n\t' | sed -E 's/.*((app\/)?v?[0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/' 2>/dev/null || true)
  if [[ "$t" =~ ^(app/)?v?[0-9]+\.[0-9]+(\.[0-9]+)?([.-][A-Za-z0-9._-]+)?$ ]]; then
    printf '%s\n' "$t"
    return 0
  fi
  return 1
}

download() {
  local url="$1" dest="$2" min_bytes="${3:-1000}" quiet="${4:-0}"
  local host
  host=$(echo "$url" | sed -E 's|https?://([^/]+).*|\1|')
  [[ "$quiet" != "1" ]] && log_info "拉取 ${url##*/} ← ${host}"
  rm -f "$dest" 2>/dev/null || true
  if curl -fL --retry 2 --retry-delay 1 --retry-all-errors \
      --connect-timeout "$DL_CONNECT_TIMEOUT" \
      --max-time "$DL_MAX_TIME" \
      --speed-time 20 --speed-limit 512 \
      -A "Mozilla/5.0 (compatible; vps-proxy-mgr/${SCRIPT_VERSION})" \
      -o "$dest" "$url" 2>/dev/null; then
    if _dl_looks_valid "$dest" "$min_bytes"; then
      return 0
    fi
  fi
  if command -v wget &>/dev/null; then
    rm -f "$dest" 2>/dev/null || true
    if wget -q --tries=2 --timeout="$DL_CONNECT_TIMEOUT" \
        -U "Mozilla/5.0" -O "$dest" "$url" 2>/dev/null \
        && _dl_looks_valid "$dest" "$min_bytes"; then
      return 0
    fi
  fi
  rm -f "$dest" 2>/dev/null || true
  return 1
}

# 精简镜像列表（少而稳，避免刷几十次失败日志）
github_release_urls() {
  local repo="$1" tag="$2" file="$3"
  local gh="https://github.com/${repo}/releases/download/${tag}/${file}"
  printf '%s\n' \
    "https://ghproxy.net/${gh}" \
    "https://gh-proxy.com/${gh}" \
    "https://mirror.ghproxy.com/${gh}" \
    "https://ghfast.top/${gh}" \
    "https://github.moeyy.xyz/${gh}" \
    "https://gh.ddlc.top/${gh}" \
    "$gh"
}

github_mirrors() {
  local url="$1"
  printf '%s\n' \
    "https://ghproxy.net/${url}" \
    "https://gh-proxy.com/${url}" \
    "https://mirror.ghproxy.com/${url}" \
    "https://ghfast.top/${url}" \
    "https://github.moeyy.xyz/${url}" \
    "$url"
}

# 带缓存的 GitHub latest tag（stdout 仅输出 tag）
github_latest_tag() {
  local api="$1" cache_key="$2" fallback="$3"
  local ver mirror clean
  ver=$(cache_get "$cache_key" "$VER_CACHE_TTL" 2>/dev/null || true)
  if clean=$(sanitize_release_tag "$ver"); then
    printf '%s\n' "$clean"
    return 0
  fi
  # 缓存污染则删除
  rm -f "${CACHE_DIR}/${cache_key}" 2>/dev/null || true
  ver=""
  for mirror in \
    "$api" \
    "https://ghproxy.net/${api}" \
    "https://ghfast.top/${api}" \
    "https://github.moeyy.xyz/${api}"; do
    ver=$(curl -fsSL --connect-timeout 8 --max-time 15 "$mirror" 2>/dev/null \
      | jq -r '.tag_name // empty' 2>/dev/null || true)
    if clean=$(sanitize_release_tag "$ver"); then
      cache_set "$cache_key" "$clean"
      printf '%s\n' "$clean"
      return 0
    fi
  done
  log_warn "版本 API 不可用，使用 ${fallback}"
  printf '%s\n' "$fallback"
}

# 通用：按 URL 列表下载（去重、安静失败）
download_from_list() {
  local dest="$1" min_bytes="${2:-1000}"
  shift 2
  local m n=0 seen="|"
  for m in "$@"; do
    [[ -z "$m" ]] && continue
    [[ "$m" == *cdn.jsdelivr.net* ]] && continue
    [[ "$seen" == *"|${m}|"* ]] && continue
    seen+="${m}|"
    n=$((n + 1))
    if download "$m" "$dest" "$min_bytes"; then
      log_ok "下载完成"
      return 0
    fi
    # 只提示失败序号，不刷完整 URL
    log_warn "镜像 #${n} 失败"
  done
  return 1
}

#-------------------------------------------------------------------------------
#  Xray REALITY-Vision 安装
#-------------------------------------------------------------------------------
install_xray_binary() {
  if [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version &>/dev/null; then
    log_ok "Xray 已存在"
    return 0
  fi

  local arch asset_name tmp ver clean
  local -a urls=()
  arch=$(detect_arch)
  case "$arch" in
    amd64) asset_name="Xray-linux-64.zip" ;;
    arm64) asset_name="Xray-linux-arm64-v8a.zip" ;;
  esac

  log_step "下载 Xray-core"
  # 清除可能被污染的版本缓存
  rm -f "${CACHE_DIR}/xray_ver" 2>/dev/null || true
  ver=$(github_latest_tag "$XRAY_GITHUB_API" "xray_ver" "v25.12.8")
  clean=$(sanitize_release_tag "$ver" || true)
  if [[ -z "$clean" ]]; then
    ver="v25.12.8"
  else
    ver="$clean"
  fi
  [[ "$ver" == v* || "$ver" == app/* ]] || ver="v${ver}"
  log_info "版本 ${ver}"

  mapfile -t urls < <(github_release_urls "XTLS/Xray-core" "$ver" "$asset_name")

  tmp=$(mktemp -d)
  if ! download_from_list "${tmp}/xray.zip" 500000 "${urls[@]}"; then
    local alt
    for alt in "v25.3.6" "v1.8.24"; do
      log_warn "尝试备用版本 ${alt}"
      mapfile -t urls < <(github_release_urls "XTLS/Xray-core" "$alt" "$asset_name")
      if download_from_list "${tmp}/xray.zip" 500000 "${urls[@]}"; then
        ver="$alt"
        break
      fi
    done
    if [[ ! -s "${tmp}/xray.zip" ]]; then
      rm -rf "$tmp"
      log_err "Xray 下载失败"
      log_tip "手动: 下载 ${asset_name} → 解压后 install -m 755 xray ${XRAY_BIN}"
      die "请检查网络后重试"
    fi
  fi

  unzip -qo "${tmp}/xray.zip" -d "${tmp}/out" 2>/dev/null || true
  local found="${tmp}/out/xray"
  [[ -f "$found" ]] || found=$(find "${tmp}/out" -type f -name xray 2>/dev/null | head -1 || true)
  if [[ -z "$found" || ! -f "$found" ]]; then
    rm -rf "$tmp"
    die "压缩包损坏或非 zip"
  fi
  install -m 755 "$found" "$XRAY_BIN"
  [[ -f "${tmp}/out/geoip.dat" ]] && install -m 644 "${tmp}/out/geoip.dat" "${XRAY_DIR}/geoip.dat"
  [[ -f "${tmp}/out/geosite.dat" ]] && install -m 644 "${tmp}/out/geosite.dat" "${XRAY_DIR}/geosite.dat"
  rm -rf "$tmp"
  chmod +x "$XRAY_BIN"
  log_ok "Xray $($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}' || echo "$ver")"
}

gen_xray_keys() {
  local out priv pub uuid short_id
  out=$("$XRAY_BIN" x25519 2>/dev/null) || die "xray x25519 密钥生成失败"
  # 兼容旧版 "Private key:" / "Public key:" 与新版 "PrivateKey:" / "Password:"(即公钥)
  priv=$(echo "$out" | grep -iE '^(PrivateKey|Private key)\s*:' | head -1 | sed -E 's/^[^:]+:[[:space:]]*//' | tr -d '[:space:]')
  pub=$(echo "$out" | grep -iE '^(PublicKey|Public key|Password)\s*:' | head -1 | sed -E 's/^[^:]+:[[:space:]]*//' | tr -d '[:space:]')
  if [[ -z "$priv" ]]; then
    priv=$(echo "$out" | awk 'BEGIN{IGNORECASE=1} /Private/{print $NF; exit}')
  fi
  if [[ -z "$pub" ]]; then
    pub=$(echo "$out" | awk 'BEGIN{IGNORECASE=1} /Public|Password/{print $NF; exit}')
  fi
  [[ -n "$priv" && -n "$pub" ]] || die "解析 x25519 密钥失败: $out"

  # 保留已有 UUID（与 VLESS+WS 共用，避免重装 REALITY 冲掉 WS 客户端）
  uuid=$(state_get "XRAY_UUID")
  if [[ -z "$uuid" ]]; then
    uuid=$("$XRAY_BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    state_set "XRAY_UUID" "$uuid"
  fi
  short_id=$(rand_hex 16)

  state_set "XRAY_PRIVKEY" "$priv"
  state_set "XRAY_PUBKEY" "$pub"
  state_set "XRAY_SHORTID" "$short_id"
  log_ok "已生成 x25519 / shortId / UUID（密钥不在终端显示）"
}

# 确保 Xray UUID（REALITY / WS 共用一份 UUID 亦可，此处各自可独立）
ensure_xray_uuid() {
  local uuid
  uuid=$(state_get "XRAY_UUID")
  if [[ -z "$uuid" ]]; then
    if [[ -x "$XRAY_BIN" ]]; then
      uuid=$("$XRAY_BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    else
      uuid=$(cat /proc/sys/kernel/random/uuid)
    fi
    state_set "XRAY_UUID" "$uuid"
  fi
  echo "$uuid"
}

# 根据 state 重写 xray 配置（支持 REALITY 与/或 VLESS+WS 双入站）
rebuild_xray_config() {
  local uuid r_port r_sni r_priv r_sid
  local w_port w_path w_host
  local inbounds="" need=0

  ensure_sandbox
  uuid=$(ensure_xray_uuid)

  if [[ "$(state_get XRAY_INSTALLED)" == "1" ]]; then
    r_port=$(state_get "XRAY_PORT")
    r_sni=$(state_get "XRAY_SNI")
    r_priv=$(state_get "XRAY_PRIVKEY")
    r_sid=$(state_get "XRAY_SHORTID")
    [[ -n "$r_port" && -n "$r_priv" ]] || die "REALITY 状态不完整，请重装"
    need=1
    inbounds+=$(cat <<EOF
    {
      "tag": "vless-reality",
      "listen": "::",
      "port": ${r_port},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${r_sni}:443",
          "xver": 0,
          "serverNames": ["${r_sni}"],
          "privateKey": "${r_priv}",
          "shortIds": ["", "${r_sid}"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
EOF
)
  fi

  if [[ "$(state_get XRAY_WS_INSTALLED)" == "1" ]]; then
    w_port=$(state_get "XRAY_WS_PORT")
    w_path=$(state_get "XRAY_WS_PATH")
    w_host=$(state_get "XRAY_WS_HOST")
    local w_mode w_sec_block
    # 固定 Full：源站 TLS 自签（不再支持 Flexible/明文）
    state_set "XRAY_WS_CF_MODE" "https"
    [[ -n "$w_port" && -n "$w_path" ]] || die "VLESS+WS 状态不完整，请重装"
    need=1
    [[ -n "$inbounds" ]] && inbounds+=","
    [[ -f "${XRAY_DIR}/ws-origin.crt" ]] || gen_ws_origin_cert "${w_host}"
    inbounds+=$(cat <<EOF
    {
      "tag": "vless-ws",
      "listen": "::",
      "port": ${w_port},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid}" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{
            "certificateFile": "${XRAY_DIR}/ws-origin.crt",
            "keyFile": "${XRAY_DIR}/ws-origin.key"
          }]
        },
        "wsSettings": {
          "path": "${w_path}",
          "headers": { "Host": "${w_host}" }
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
EOF
)
  fi

  if [[ "$need" -eq 0 ]]; then
    # 无入站：停服务但不删二进制（可能仅剩 hy2）
    if svc_exists "$XRAY_SVC"; then
      systemctl stop "$XRAY_SVC" 2>/dev/null || true
      systemctl disable "$XRAY_SVC" 2>/dev/null || true
      rm -f "/etc/systemd/system/${XRAY_SVC}"
      systemctl daemon-reload 2>/dev/null || true
    fi
    rm -f "${XRAY_DIR}/config.json"
    return 0
  fi

  cat > "${XRAY_DIR}/config.json" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "${LOG_DIR}/xray-error.log"
  },
  "inbounds": [
${inbounds}
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": { "domainStrategy": "AsIs" },
      "streamSettings": {
        "sockopt": { "tcpFastOpen": true, "tcpNoDelay": true }
      }
    },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
  chmod 600 "${XRAY_DIR}/config.json"
  log_ok "Xray 配置已更新 ${XRAY_DIR}/config.json"
}

write_xray_systemd() {
  cat > "/etc/systemd/system/${XRAY_SVC}" <<EOF
[Unit]
Description=VPS Proxy Manager - Xray (REALITY / VLESS-WS)
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -c ${XRAY_DIR}/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
LimitNPROC=512
TasksMax=infinity
StandardOutput=append:${LOG_DIR}/xray-stdout.log
StandardError=append:${LOG_DIR}/xray-stderr.log
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${SANDBOX_ROOT}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  if [[ -f "${XRAY_DIR}/config.json" ]]; then
    if "$XRAY_BIN" run -test -c "${XRAY_DIR}/config.json" >/dev/null 2>&1 \
      || "$XRAY_BIN" -test -config "${XRAY_DIR}/config.json" >/dev/null 2>&1; then
      log_ok "Xray 配置语法校验通过"
    else
      log_warn "无法执行配置测试（或测试失败），仍将尝试启动服务"
    fi
  fi
  systemctl daemon-reload
  systemctl enable --now "$XRAY_SVC"
  sleep 1
  if svc_active "$XRAY_SVC"; then
    log_ok "Xray 服务已启动 (${XRAY_SVC})"
  else
    log_err "Xray 服务启动失败，最近日志："
    journalctl -u "$XRAY_SVC" -n 30 --no-pager || true
    die "请检查配置后重试"
  fi
}

# 静默启用 TG 加速资料（不破坏系统路由/DNS）
ensure_tg_accel() {
  write_tg_cidr_hint
  # 若已装 Hy2，用加强版 sysctl；否则轻量缓冲
  if [[ "$(state_get HY2_INSTALLED)" == "1" ]]; then
    apply_hy2_perf_sysctl
  else
    apply_tg_sysctl_quiet
  fi
  state_set "TG_ACCEL" "1"
}

# 仅写对 TG/UDP 友好的缓冲参数（不提供菜单、不装 WARP）
apply_tg_sysctl_quiet() {
  local tier rmax wmax
  tier=$(mem_tier)
  case "$tier" in
    small)  rmax=4194304;  wmax=4194304 ;;
    medium) rmax=8388608;  wmax=8388608 ;;
    *)      rmax=16777216; wmax=16777216 ;;
  esac
  # 若用户系统已是 bbr 则保持；我们只保证缓冲与 fq 对 UDP 友好
  cat > "$SYSCTL_FILE" <<EOF
# Managed by vps_proxy_mgr (TG/UDP buffers) — removed on full uninstall
net.core.rmem_max = ${rmax}
net.core.wmem_max = ${wmax}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.netdev_max_backlog = 8192
EOF
  local key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    key=$(echo "$line" | sed -E 's/^[[:space:]]*([^=[:space:]]+)[[:space:]]*=.*/\1/')
    val=$(echo "$line" | sed -E 's/^[^=]+=[[:space:]]*//')
    [[ -n "$key" && -n "$val" ]] || continue
    sysctl -w "${key}=${val}" >/dev/null 2>&1 || true
  done < "$SYSCTL_FILE"
}

# 全部协议卸完：清理 TG + 分享文件 + 缓存等脚本产物
cleanup_tg_if_idle() {
  if any_protocol_installed; then
    # 仍有协议：刷新分享文件（去掉已卸协议的链接）
    refresh_share_file 2>/dev/null || true
    return 0
  fi
  # 无任何协议：清掉脚本产生的全部残留
  uninstall_tg_accel
  rm -rf "$SHARE_DIR" "$CACHE_DIR" "$LOG_DIR" 2>/dev/null || true
  # 若沙盒已空则删除根目录
  if [[ -d "$SANDBOX_ROOT" ]] && [[ -z "$(ls -A "$SANDBOX_ROOT" 2>/dev/null || true)" ]]; then
    rmdir "$SANDBOX_ROOT" 2>/dev/null || true
  fi
}

uninstall_tg_accel() {
  if [[ -f "$SYSCTL_FILE" ]]; then
    rm -f "$SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || true
  fi
  rm -rf "$OPT_DIR" "$WARP_DIR" "$SHARE_DIR"
  rm -f /etc/apt/sources.list.d/vps-cloudflare-warp.list 2>/dev/null || true
  # state 可能已不存在
  if [[ -f "$STATE_FILE" ]]; then
    state_set "TG_ACCEL" "0"
    state_set "OPT_INSTALLED" "0"
    state_set "BBR_APPLIED" "0"
    state_set "WARP_INSTALLED" "0"
    state_set "WARP_SOCKS" ""
  fi
}

install_reality() {
  local t0 port sni
  t0=$(date +%s)
  ui_section "安装 REALITY-Vision"
  log_info "协议: VLESS + TCP + REALITY + Vision · 随机高位端口"
  ensure_sandbox
  install_deps

  if [[ "$(state_get XRAY_INSTALLED)" == "1" ]]; then
    log_warn "已安装 REALITY"
    if ! confirm "覆盖重装？"; then
      return 0
    fi
    local oldp
    oldp=$(state_get "XRAY_PORT")
    [[ -n "$oldp" ]] && fw_remove "$oldp" "tcp" "vps_proxy_mgr_xray" || true
    state_set "XRAY_INSTALLED" "0"
  fi

  port=$(pick_port "tcp" "REALITY")
  log_info "探测可用伪装 SNI…"
  sni=$(pick_sni)

  if [[ ! -x "$XRAY_BIN" ]]; then
    install_xray_binary
  fi
  gen_xray_keys
  state_set "XRAY_PORT" "$port"
  state_set "XRAY_SNI" "$sni"
  state_set "XRAY_INSTALLED" "1"
  rebuild_xray_config
  fw_allow "$port" "tcp" "vps_proxy_mgr_xray"
  ensure_tg_accel
  write_xray_systemd

  echo
  log_ok "REALITY 完成 · 端口 ${C_GREEN}${port}${C_RESET} · SNI ${sni} · ${C_DIM}$(( $(date +%s) - t0 ))s${C_RESET}"
  show_xray_link
}

uninstall_reality() {
  log_step "卸载 Xray REALITY"
  local port
  port=$(state_get "XRAY_PORT")
  [[ -n "$port" ]] && fw_remove "$port" "tcp" "vps_proxy_mgr_xray" || true
  state_set "XRAY_INSTALLED" "0"
  state_set "XRAY_PORT" ""
  state_set "XRAY_PRIVKEY" ""
  state_set "XRAY_PUBKEY" ""
  state_set "XRAY_SHORTID" ""
  state_set "XRAY_SNI" ""
  # 若 WS 仍在，只重建配置；否则停 xray 并视情况删二进制
  if [[ "$(state_get XRAY_WS_INSTALLED)" == "1" ]]; then
    rebuild_xray_config
    systemctl restart "$XRAY_SVC" 2>/dev/null || write_xray_systemd
  else
    if svc_exists "$XRAY_SVC"; then
      systemctl stop "$XRAY_SVC" 2>/dev/null || true
      systemctl disable "$XRAY_SVC" 2>/dev/null || true
      rm -f "/etc/systemd/system/${XRAY_SVC}"
      systemctl daemon-reload 2>/dev/null || true
    fi
    rm -f "$XRAY_BIN"
    rm -rf "$XRAY_DIR"
    state_set "XRAY_UUID" ""
  fi
  cleanup_tg_if_idle
  log_ok "Xray REALITY 已卸载"
}

install_vless_ws() {
  local t0 port path host uuid def_host ip4 ip6 last_host
  t0=$(date +%s)
  ui_section "安装 VLESS + WebSocket（CF · 仅 Full）"
  log_info "源站 HTTPS 自签 · CF SSL 必须 Full · 端口 ∈ ${CF_HTTPS_ORIGIN_PORTS[*]}"
  ensure_sandbox
  install_deps

  if [[ "$(state_get XRAY_WS_INSTALLED)" == "1" ]]; then
    log_warn "已安装 VLESS+WS"
    if ! confirm "覆盖重装？"; then
      return 0
    fi
    local oldp
    oldp=$(state_get "XRAY_WS_PORT")
    [[ -n "$oldp" ]] && fw_remove "$oldp" "tcp" "vps_proxy_mgr_ws" || true
    state_set "XRAY_WS_INSTALLED" "0"
  fi

  port=$(pick_cf_origin_port)
  path=$(pick_ws_path)

  # Host/SNI 必须是域名，绝不能默认填服务器 IP（IPv4/IPv6 都不行）
  # 用户若用 AAAA 解析到本机，只要域名橙云即可，与本机默认提示 IP 无关
  ip4=$(get_public_ipv4 2>/dev/null || true)
  ip6=$(get_public_ipv6 2>/dev/null || true)
  last_host=$(state_get "XRAY_WS_HOST")
  def_host=""
  if [[ -n "$last_host" ]] && ! is_ipv4 "$last_host" && ! is_ipv6 "$last_host"; then
    def_host="$last_host"
  fi
  [[ -n "$ip4" ]] && log_tip "CF DNS A → ${ip4}"
  [[ -n "$ip6" ]] && log_tip "CF DNS AAAA → ${ip6}"
  if [[ -n "$def_host" ]]; then
    host=$(ask "域名 Host/SNI（勿填 IP）" "$def_host")
  else
    host=$(ask "域名 Host/SNI（如 yx.example.com）" "")
  fi
  host=$(echo "$host" | tr -d '[:space:]')
  while [[ -z "$host" ]] || is_ipv4 "$host" || is_ipv6 "$host"; do
    log_warn "请填写 Cloudflare 橙云域名（不是 IP）"
    host=$(ask "域名 Host/SNI" "")
    host=$(echo "$host" | tr -d '[:space:]')
  done

  if [[ ! -x "$XRAY_BIN" ]]; then
    install_xray_binary
  fi
  gen_ws_origin_cert "$host"
  uuid=$(ensure_xray_uuid)
  state_set "XRAY_WS_PORT" "$port"
  state_set "XRAY_WS_PATH" "$path"
  state_set "XRAY_WS_HOST" "$host"
  state_set "XRAY_WS_CF_MODE" "https"
  state_set "XRAY_WS_INSTALLED" "1"
  rebuild_xray_config
  fw_allow "$port" "tcp" "vps_proxy_mgr_ws"
  ensure_tg_accel
  write_xray_systemd

  echo
  log_ok "VLESS+WS 完成  :${port}${path}  ${host}"
  log_tip "CF: 橙云 + SSL=Full + 放行 TCP ${port}（含 IPv6）"
  show_ws_link
}

uninstall_vless_ws() {
  log_step "卸载 VLESS+WS"
  local port
  port=$(state_get "XRAY_WS_PORT")
  [[ -n "$port" ]] && fw_remove "$port" "tcp" "vps_proxy_mgr_ws" || true
  state_set "XRAY_WS_INSTALLED" "0"
  state_set "XRAY_WS_PORT" ""
  state_set "XRAY_WS_PATH" ""
  state_set "XRAY_WS_HOST" ""
  state_set "XRAY_WS_CF_MODE" ""
  rm -f "${XRAY_DIR}/ws-origin.crt" "${XRAY_DIR}/ws-origin.key" 2>/dev/null || true
  if [[ "$(state_get XRAY_INSTALLED)" == "1" ]]; then
    rebuild_xray_config
    systemctl restart "$XRAY_SVC" 2>/dev/null || write_xray_systemd
  else
    if svc_exists "$XRAY_SVC"; then
      systemctl stop "$XRAY_SVC" 2>/dev/null || true
      systemctl disable "$XRAY_SVC" 2>/dev/null || true
      rm -f "/etc/systemd/system/${XRAY_SVC}"
      systemctl daemon-reload 2>/dev/null || true
    fi
    rm -f "$XRAY_BIN"
    rm -rf "$XRAY_DIR"
    state_set "XRAY_UUID" ""
  fi
  cleanup_tg_if_idle
  log_ok "VLESS+WS 已卸载"
}

#-------------------------------------------------------------------------------
#  Hysteria 2 安装
#-------------------------------------------------------------------------------
install_hy2_binary() {
  if [[ -x "$HY2_BIN" ]] && "$HY2_BIN" version &>/dev/null; then
    log_ok "Hysteria2 已存在"
    return 0
  fi

  local arch asset_name tmp ver clean
  local -a urls=()
  arch=$(detect_arch)
  case "$arch" in
    amd64) asset_name="hysteria-linux-amd64" ;;
    arm64) asset_name="hysteria-linux-arm64" ;;
  esac

  log_step "下载 Hysteria2"
  rm -f "${CACHE_DIR}/hy2_ver" 2>/dev/null || true
  ver=$(github_latest_tag "$HY2_GITHUB_API" "hy2_ver" "app/v2.6.1")
  clean=$(sanitize_release_tag "$ver" || true)
  [[ -n "$clean" ]] && ver="$clean"
  # Hy2 tag 通常为 app/vX.Y.Z
  if [[ "$ver" != app/* ]]; then
    [[ "$ver" == v* ]] && ver="app/${ver}" || ver="app/v${ver}"
  fi
  log_info "版本 ${ver}"
  mapfile -t urls < <(github_release_urls "apernet/hysteria" "$ver" "$asset_name")

  tmp=$(mktemp -d)
  if ! download_from_list "${tmp}/hy2" 2000000 "${urls[@]}"; then
    mapfile -t urls < <(github_release_urls "apernet/hysteria" "app/v2.6.1" "$asset_name")
    if ! download_from_list "${tmp}/hy2" 2000000 "${urls[@]}"; then
      rm -rf "$tmp"
      log_err "Hysteria2 下载失败"
      log_tip "手动下载 ${asset_name} → ${HY2_BIN}"
      die "请检查网络后重试"
    fi
  fi
  install -m 755 "${tmp}/hy2" "$HY2_BIN"
  rm -rf "$tmp"
  chmod +x "$HY2_BIN"
  log_ok "Hysteria2 已安装"
}

gen_hy2_cert() {
  # 伪装目标：随机大厂 HTTPS（非微软），抗主动探测
  local pool=("www.apple.com" "www.cloudflare.com" "www.amazon.com" "www.google.com" "gateway.icloud.com")
  local masq_host
  masq_host="${pool[$((RANDOM % ${#pool[@]}))]}"
  log_info "自签证书 + 伪装站点 CN=${masq_host}"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 \
    -keyout "${HY2_DIR}/server.key" \
    -out "${HY2_DIR}/server.crt" \
    -subj "/CN=${masq_host}" \
    >/dev/null 2>&1
  chmod 600 "${HY2_DIR}/server.key" "${HY2_DIR}/server.crt"
  state_set "HY2_MASQ" "https://${masq_host}"
}

# 生成端口跳跃区间（高位、避开主端口，宽度约 2000）
random_hop_range() {
  local main_port="${1:-0}"
  local span=2000 start end tries=0
  while (( tries < 40 )); do
    start=$(( PORT_HIGH_MIN + RANDOM % (PORT_HIGH_MAX - PORT_HIGH_MIN - span) ))
    end=$(( start + span - 1 ))
    if (( end > PORT_HIGH_MAX )); then
      end=$PORT_HIGH_MAX
      start=$(( end - span + 1 ))
    fi
    # 主监听端口不要落在跳跃段内（主端口单独放行，跳跃段 REDIRECT 到主端口）
    if (( main_port < start || main_port > end )); then
      echo "${start}-${end}"
      return 0
    fi
    tries=$((tries + 1))
  done
  echo "30000-32000"
}

# 防火墙放行 UDP 端口段
fw_allow_udp_range() {
  local start="$1" end="$2" comment="${3:-vps_proxy_mgr_hy2_hop}"
  detect_firewall quiet
  case "$FW_BACKEND" in
    ufw)
      ufw allow "${start}:${end}/udp" comment "$comment" >/dev/null 2>&1 || true
      log_ok "UFW 已放行 UDP ${start}-${end}"
      ;;
    nft)
      nft list table inet vps_proxy_mgr &>/dev/null || nft add table inet vps_proxy_mgr 2>/dev/null || true
      nft list chain inet vps_proxy_mgr input &>/dev/null || \
        nft 'add chain inet vps_proxy_mgr input { type filter hook input priority -10; policy accept; }' 2>/dev/null || true
      nft add rule inet vps_proxy_mgr input udp dport "${start}-${end}" counter accept comment \""${comment}"\" 2>/dev/null || true
      log_ok "nftables 已放行 UDP ${start}-${end}"
      ;;
    iptables)
      if ! iptables -C INPUT -p udp --dport "${start}:${end}" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p udp --dport "${start}:${end}" -m comment --comment "$comment" -j ACCEPT
      fi
      if command -v ip6tables &>/dev/null; then
        if ! ip6tables -C INPUT -p udp --dport "${start}:${end}" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; then
          ip6tables -I INPUT -p udp --dport "${start}:${end}" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || true
        fi
      fi
      log_ok "iptables 已放行 UDP ${start}-${end}"
      ;;
    *) log_warn "请手动放行 UDP ${start}-${end}" ;;
  esac
  local rec
  rec=$(state_get "FW_RULES")
  state_set "FW_RULES" "${rec}range:${start}-${end}/udp,"
}

fw_remove_udp_range() {
  local start="$1" end="$2" comment="${3:-vps_proxy_mgr_hy2_hop}"
  detect_firewall quiet
  case "$FW_BACKEND" in
    ufw)
      ufw delete allow "${start}:${end}/udp" >/dev/null 2>&1 || true
      ;;
    nft)
      local handles h
      handles=$(nft -a list chain inet vps_proxy_mgr input 2>/dev/null \
        | grep -E "udp dport ${start}-${end}|dport \\{ ${start}" \
        | grep -oE 'handle [0-9]+' | awk '{print $2}' || true)
      for h in $handles; do
        nft delete rule inet vps_proxy_mgr input handle "$h" 2>/dev/null || true
      done
      ;;
    iptables)
      while iptables -C INPUT -p udp --dport "${start}:${end}" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -p udp --dport "${start}:${end}" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || break
      done
      if command -v ip6tables &>/dev/null; then
        while ip6tables -C INPUT -p udp --dport "${start}:${end}" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; do
          ip6tables -D INPUT -p udp --dport "${start}:${end}" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || break
        done
      fi
      ;;
  esac
}

# 端口跳跃：将 hop 段 UDP REDIRECT 到主监听端口（客户端跳端口，服务端单进程）
setup_hy2_port_hop() {
  local main_port="$1" hop_start="$2" hop_end="$3"
  local cmt="vps_proxy_mgr_hy2_hop"
  # IPv4
  if command -v iptables &>/dev/null; then
    # 先清旧规则再加
    while iptables -t nat -C PREROUTING -p udp --dport "${hop_start}:${hop_end}" -m comment --comment "$cmt" -j REDIRECT --to-ports "$main_port" 2>/dev/null; do
      iptables -t nat -D PREROUTING -p udp --dport "${hop_start}:${hop_end}" -m comment --comment "$cmt" -j REDIRECT --to-ports "$main_port" 2>/dev/null || break
    done
    iptables -t nat -A PREROUTING -p udp --dport "${hop_start}:${hop_end}" -m comment --comment "$cmt" -j REDIRECT --to-ports "$main_port"
  fi
  if command -v ip6tables &>/dev/null; then
    while ip6tables -t nat -C PREROUTING -p udp --dport "${hop_start}:${hop_end}" -m comment --comment "$cmt" -j REDIRECT --to-ports "$main_port" 2>/dev/null; do
      ip6tables -t nat -D PREROUTING -p udp --dport "${hop_start}:${hop_end}" -m comment --comment "$cmt" -j REDIRECT --to-ports "$main_port" 2>/dev/null || break
    done
    ip6tables -t nat -A PREROUTING -p udp --dport "${hop_start}:${hop_end}" -m comment --comment "$cmt" -j REDIRECT --to-ports "$main_port" 2>/dev/null || true
  fi
  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save >/dev/null 2>&1 || true
  fi
  fw_allow_udp_range "$hop_start" "$hop_end" "$cmt"
  state_set "HY2_HOP" "1"
  state_set "HY2_HOP_START" "$hop_start"
  state_set "HY2_HOP_END" "$hop_end"
  log_ok "端口跳跃已启用: UDP ${hop_start}-${hop_end} → ${main_port}"
}

remove_hy2_port_hop() {
  local main_port hop_start hop_end cmt="vps_proxy_mgr_hy2_hop"
  main_port=$(state_get "HY2_PORT")
  hop_start=$(state_get "HY2_HOP_START")
  hop_end=$(state_get "HY2_HOP_END")
  [[ -z "$hop_start" || -z "$hop_end" ]] && {
    state_set "HY2_HOP" "0"
    return 0
  }
  if command -v iptables &>/dev/null && [[ -n "$main_port" ]]; then
    while iptables -t nat -C PREROUTING -p udp --dport "${hop_start}:${hop_end}" -m comment --comment "$cmt" -j REDIRECT --to-ports "$main_port" 2>/dev/null; do
      iptables -t nat -D PREROUTING -p udp --dport "${hop_start}:${hop_end}" -m comment --comment "$cmt" -j REDIRECT --to-ports "$main_port" 2>/dev/null || break
    done
  fi
  if command -v ip6tables &>/dev/null && [[ -n "$main_port" ]]; then
    while ip6tables -t nat -C PREROUTING -p udp --dport "${hop_start}:${hop_end}" -m comment --comment "$cmt" -j REDIRECT --to-ports "$main_port" 2>/dev/null; do
      ip6tables -t nat -D PREROUTING -p udp --dport "${hop_start}:${hop_end}" -m comment --comment "$cmt" -j REDIRECT --to-ports "$main_port" 2>/dev/null || break
    done
  fi
  fw_remove_udp_range "$hop_start" "$hop_end" "$cmt" || true
  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save >/dev/null 2>&1 || true
  fi
  state_set "HY2_HOP" "0"
  state_set "HY2_HOP_START" ""
  state_set "HY2_HOP_END" ""
  log_ok "端口跳跃规则已移除"
}

# Hy2 专用：加强 UDP/QUIC 内核参数（在 TG 缓冲基础上叠加）
apply_hy2_perf_sysctl() {
  local tier rmax wmax
  tier=$(mem_tier)
  case "$tier" in
    small)  rmax=8388608;  wmax=8388608 ;;
    medium) rmax=16777216; wmax=16777216 ;;
    *)      rmax=33554432; wmax=33554432 ;;
  esac
  cat > "$SYSCTL_FILE" <<EOF
# Managed by vps_proxy_mgr — Hy2/TG performance — removed on full uninstall
net.core.rmem_max = ${rmax}
net.core.wmem_max = ${wmax}
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 204800
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = 65536 131072 262144
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 1024 65535
EOF
  modprobe tcp_bbr 2>/dev/null || true
  local key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    key=$(echo "$line" | sed -E 's/^[[:space:]]*([^=[:space:]]+)[[:space:]]*=.*/\1/')
    val=$(echo "$line" | sed -E 's/^[^=]+=[[:space:]]*//')
    [[ -n "$key" && -n "$val" ]] || continue
    sysctl -w "${key}=${val}" >/dev/null 2>&1 || true
  done < "$SYSCTL_FILE"
  # 网卡 offload
  local iface
  iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || true)
  if [[ -n "$iface" ]] && command -v ethtool &>/dev/null; then
    ethtool -K "$iface" gro on gso on tso on 2>/dev/null || true
  fi
  log_ok "已应用 Hy2 传输优化 sysctl（档位 ${tier} · rmem_max=${rmax}）"
}

write_hy2_config() {
  local port="$1"
  local password masq tier nic_mbps bw_up bw_down
  local sw_init sw_max cw_init cw_max streams
  local obfs_pass obfs_block=""
  password=$(state_get "HY2_PASSWORD")
  if [[ -z "$password" ]]; then
    password=$(rand_password 24)
    state_set "HY2_PASSWORD" "$password"
  fi
  masq=$(state_get "HY2_MASQ")
  [[ -z "$masq" ]] && masq="https://www.apple.com"

  obfs_pass=$(state_get "HY2_OBFS")
  if [[ -n "$obfs_pass" ]]; then
    obfs_block=$(cat <<OBFS
# Salamander 混淆 — 抗 DPI / 特征识别
obfs:
  type: salamander
  salamander:
    password: "${obfs_pass}"
OBFS
)
  fi

  # 按内存分档 QUIC 窗口（抗丢包拉大）
  tier=$(mem_tier)
  nic_mbps=$(detect_nic_mbps)
  case "$tier" in
    small)
      sw_init=4194304; sw_max=8388608
      cw_init=10485760; cw_max=20971520
      streams=1024
      ;;
    medium)
      sw_init=8388608; sw_max=16777216
      cw_init=20971520; cw_max=41943040
      streams=2048
      ;;
    *)
      sw_init=16777216; sw_max=33554432
      cw_init=41943040; cw_max=83886080
      streams=4096
      ;;
  esac
  if (( nic_mbps >= 10000 )); then
    bw_up="10 gbps"; bw_down="10 gbps"
  elif (( nic_mbps >= 1000 )); then
    bw_up="1 gbps"; bw_down="1 gbps"
  elif (( nic_mbps >= 100 )); then
    bw_up="${nic_mbps} mbps"; bw_down="${nic_mbps} mbps"
  else
    bw_up="100 mbps"; bw_down="100 mbps"
  fi
  log_info "Hy2 档位=${tier} · 网卡≈${nic_mbps}Mbps · 带宽 ${bw_up}"

  cat > "${HY2_DIR}/config.yaml" <<EOF
# Hysteria 2 — managed by vps_proxy_mgr
# 传输优化 + 抗封锁（masquerade / 可选 obfs / 端口跳跃在 netfilter）
listen: :${port}

tls:
  cert: ${HY2_DIR}/server.crt
  key: ${HY2_DIR}/server.key

auth:
  type: password
  password: "${password}"

${obfs_block}

# 伪装成正常 HTTPS 站点，降低主动探测风险
masquerade:
  type: proxy
  proxy:
    url: ${masq}
    rewriteHost: true

# QUIC 大窗口 — 高延迟/高丢包（TG 视频）更稳
quic:
  initStreamReceiveWindow: ${sw_init}
  maxStreamReceiveWindow: ${sw_max}
  initConnReceiveWindow: ${cw_init}
  maxConnReceiveWindow: ${cw_max}
  maxIdleTimeout: 60s
  maxIncomingStreams: ${streams}
  disablePathMTUDiscovery: false

bandwidth:
  up: ${bw_up}
  down: ${bw_down}

ignoreClientBandwidth: true
udpIdleTimeout: 90s
EOF
  chmod 600 "${HY2_DIR}/config.yaml"
  state_set "HY2_PORT" "$port"
  state_set "HY2_TIER" "$tier"
  state_set "HY2_BW" "${bw_up}"
  log_ok "Hysteria2 配置已写入 ${HY2_DIR}/config.yaml"
}

write_hy2_systemd() {
  cat > "/etc/systemd/system/${HY2_SVC}" <<EOF
[Unit]
Description=VPS Proxy Manager - Hysteria2
Documentation=https://v2.hysteria.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true
ExecStart=${HY2_BIN} server -c ${HY2_DIR}/config.yaml
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
LimitNPROC=65535
TasksMax=infinity
# UDP 高并发
Environment=HYSTERIA_LOG_LEVEL=warn
StandardOutput=append:${LOG_DIR}/hy2-stdout.log
StandardError=append:${LOG_DIR}/hy2-stderr.log

ProtectSystem=full
ProtectHome=true
ReadWritePaths=${SANDBOX_ROOT}
PrivateTmp=true
# 更快恢复
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$HY2_SVC"
  sleep 1
  if svc_active "$HY2_SVC"; then
    log_ok "Hysteria2 服务已启动 (${HY2_SVC})"
  else
    log_err "Hysteria2 启动失败，最近日志："
    journalctl -u "$HY2_SVC" -n 30 --no-pager || true
    die "请检查配置后重试"
  fi
}

install_hysteria2() {
  local t0 port hop_on="0" hop_range hop_start hop_end obfs_on="0" obfs_pass
  t0=$(date +%s)
  ui_section "安装 Hysteria 2"
  log_info "QUIC / UDP · 随机高位端口 · 可选端口跳跃 / 混淆"
  ensure_sandbox
  install_deps

  if [[ "$(state_get HY2_INSTALLED)" == "1" ]] || svc_exists "$HY2_SVC"; then
    log_warn "已安装 Hysteria2"
    if ! confirm "覆盖重装？"; then
      return 0
    fi
    uninstall_hysteria2 || true
  fi

  port=$(pick_port "udp" "Hysteria2 主端口")

  # —— 抗封锁可选项 ——
  echo
  log_info "抗封锁增强（均可跳过）"
  if confirm "启用端口跳跃 Port Hopping？（推荐，抗 UDP QoS）"; then
    hop_on="1"
    hop_range=$(random_hop_range "$port")
    hop_range=$(ask "跳跃端口段 start-end" "$hop_range")
    if [[ "$hop_range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      hop_start="${BASH_REMATCH[1]}"
      hop_end="${BASH_REMATCH[2]}"
      if (( hop_start >= hop_end || hop_start < 1 || hop_end > 65535 )); then
        log_warn "端口段无效，已关闭跳跃"
        hop_on="0"
      elif (( port >= hop_start && port <= hop_end )); then
        log_warn "主端口 ${port} 落在跳跃段内，已关闭跳跃"
        hop_on="0"
      fi
    else
      log_warn "格式应为 30000-32000，已关闭跳跃"
      hop_on="0"
    fi
  fi

  # 留空=不启用；直接输入密码=启用（避免把密码误填进 y/N）
  obfs_pass=$(ask "Salamander 混淆密码（回车跳过不启用）" "")
  if [[ -n "$obfs_pass" ]]; then
    # 用户若习惯输入 y，再给一次随机密码
    if [[ "${obfs_pass,,}" == "y" || "${obfs_pass,,}" == "yes" ]]; then
      obfs_pass=$(rand_password 16)
      obfs_pass=$(ask "obfs 密码（回车用随机）" "$obfs_pass")
    fi
    if [[ -n "$obfs_pass" && "${obfs_pass,,}" != "n" && "${obfs_pass,,}" != "no" ]]; then
      obfs_on="1"
      state_set "HY2_OBFS" "$obfs_pass"
      log_ok "已启用 Salamander obfs"
    else
      state_set "HY2_OBFS" ""
    fi
  else
    state_set "HY2_OBFS" ""
  fi

  install_hy2_binary
  gen_hy2_cert
  write_hy2_config "$port"
  fw_allow "$port" "udp" "vps_proxy_mgr_hy2"

  if [[ "$hop_on" == "1" ]]; then
    setup_hy2_port_hop "$port" "$hop_start" "$hop_end"
  else
    state_set "HY2_HOP" "0"
    state_set "HY2_HOP_START" ""
    state_set "HY2_HOP_END" ""
  fi

  # 传输性能：Hy2 加强版 sysctl（覆盖/增强 TG 缓冲）
  apply_hy2_perf_sysctl
  ensure_tg_accel
  write_hy2_systemd

  state_set "HY2_INSTALLED" "1"
  echo
  log_ok "Hysteria2 完成 · 主端口 UDP ${C_GREEN}${port}${C_RESET}"
  [[ "$hop_on" == "1" ]] && log_ok "端口跳跃 ${hop_start}-${hop_end} → ${port}"
  [[ "$obfs_on" == "1" ]] && log_ok "Salamander obfs 已开启"
  log_info "耗时 $(( $(date +%s) - t0 ))s"
  show_hy2_link
}

uninstall_hysteria2() {
  log_step "卸载 Hysteria2"
  local port
  port=$(state_get "HY2_PORT")
  remove_hy2_port_hop || true
  if svc_exists "$HY2_SVC"; then
    systemctl stop "$HY2_SVC" 2>/dev/null || true
    systemctl disable "$HY2_SVC" 2>/dev/null || true
    rm -f "/etc/systemd/system/${HY2_SVC}"
    systemctl daemon-reload
  fi
  [[ -n "$port" ]] && fw_remove "$port" "udp" "vps_proxy_mgr_hy2" || true
  rm -f "$HY2_BIN"
  rm -rf "$HY2_DIR"
  state_set "HY2_INSTALLED" "0"
  state_set "HY2_PORT" ""
  state_set "HY2_PASSWORD" ""
  state_set "HY2_MASQ" ""
  state_set "HY2_TIER" ""
  state_set "HY2_BW" ""
  state_set "HY2_OBFS" ""
  state_set "HY2_HOP" "0"
  state_set "HY2_HOP_START" ""
  state_set "HY2_HOP_END" ""
  cleanup_tg_if_idle
  log_ok "Hysteria2 已彻底卸载"
}

#-------------------------------------------------------------------------------
#  Telegram 加速资料（静默，无菜单）
#-------------------------------------------------------------------------------
write_tg_cidr_hint() {
  # 仅写客户端分流参考，不改系统路由/DNS，不破坏现有环境
  local f="${OPT_DIR}/telegram_cidrs.txt"
  mkdir -p "$OPT_DIR"
  {
    echo "# Telegram Official CIDRs (AS62041 / AS59930 etc.)"
    echo "# 客户端：将这些网段 / 域名走已安装代理即可加速 TG"
    printf '%s\n' "${TG_CIDRS[@]}"
  } > "$f"
  cat > "${OPT_DIR}/README-TG.txt" <<EOF
Telegram 加速（随协议静默安装）
================================
1. 服务端已写入 UDP 友好缓冲（${SYSCTL_FILE}），改善 Hy2 / TG 视频卡顿。
2. 客户端请将下列域名与 ${f} 中 CIDR 走代理：
   telegram.org, t.me, td.telegram.org, telegra.ph,
   *.telegram.org, *.t.me
3. 使用 VLESS+WS + Cloudflare 时：客户端地址填 CF 优选 IP，
   Host/SNI 填你的域名，path 与面板一致。
4. 本脚本不劫持系统路由、不改 resolv.conf、不装 WARP。
5. 全部协议卸载后，上述文件与 sysctl 片段会一并删除。
EOF
}

#-------------------------------------------------------------------------------
#  一键组合 / 全清
#-------------------------------------------------------------------------------
install_all() {
  local t0
  t0=$(date +%s)
  log_step "一键组合安装：REALITY + VLESS-WS + Hy2（TG 加速默认静默启用）"
  install_reality
  echo
  install_vless_ws
  echo
  install_hysteria2
  echo
  log_ok "========== 组合安装全部完成（总耗时 $(( $(date +%s) - t0 ))s）=========="
  show_all_links
}

uninstall_all() {
  log_step "彻底清理所有协议与脚本文件"
  if ! confirm "确认删除全部协议、配置、链接文件与沙盒？"; then
    log_info "已取消"
    return 0
  fi
  # 先尽量按模块卸（清防火墙端口等）
  uninstall_reality 2>/dev/null || true
  uninstall_vless_ws 2>/dev/null || true
  uninstall_hysteria2 2>/dev/null || true
  # 兜底：脚本产生的全部路径
  purge_all_script_artifacts
  echo
  local dirty=0 p
  for p in "$XRAY_BIN" "$HY2_BIN" "$SANDBOX_ROOT" "$SYSCTL_FILE" \
           "/etc/systemd/system/${XRAY_SVC}" "/etc/systemd/system/${HY2_SVC}" \
           "$SHARE_DIR" "$SHARE_LINKS"; do
    if [[ -e "$p" ]]; then
      log_warn "仍存在: $p"
      dirty=1
    fi
  done
  if [[ $dirty -eq 0 ]]; then
    log_ok "自检通过：脚本残留已清空"
  else
    log_warn "请手动检查残留路径"
  fi
}

#-------------------------------------------------------------------------------
#  客户端链接与二维码
#-------------------------------------------------------------------------------
urlencode() {
  # 便携 URL 编码（避免依赖 python）
  local s="$1"
  if command -v jq &>/dev/null; then
    jq -rn --arg s "$s" '$s|@uri' 2>/dev/null && return 0
  fi
  local i c out="" hex
  local LC_ALL=C
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *)
        printf -v hex '%%%02X' "'${c}"
        out+="${hex}"
        ;;
    esac
  done
  echo "$out"
}

# 按指定地址构建 VLESS 链接（$1 可选，默认 get_public_ip 优先 IPv6）
build_vless_link() {
  local ip host uuid port pub sni short_id name tag
  ip="${1:-}"
  [[ -z "$ip" ]] && ip=$(get_public_ip)
  host=$(format_host_for_uri "$ip")
  uuid=$(state_get "XRAY_UUID")
  port=$(state_get "XRAY_PORT")
  pub=$(state_get "XRAY_PUBKEY")
  sni=$(state_get "XRAY_SNI")
  short_id=$(state_get "XRAY_SHORTID")
  if is_ipv6 "$ip"; then
    tag="REALITY-IPv6-${sni}"
  else
    tag="REALITY-IPv4-${sni}"
  fi
  name=$(urlencode "$tag")
  # IPv6: vless://uuid@[2001:db8::1]:443?...
  echo "vless://${uuid}@${host}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${short_id}&type=tcp#${name}"
}

# 按指定地址构建 Hy2 链接（$1 可选，默认优先 IPv6）
build_hy2_link() {
  local ip host port pass name tag qs obfs hop_s hop_e
  ip="${1:-}"
  [[ -z "$ip" ]] && ip=$(get_public_ip)
  host=$(format_host_for_uri "$ip")
  port=$(state_get "HY2_PORT")
  pass=$(state_get "HY2_PASSWORD")
  obfs=$(state_get "HY2_OBFS")
  hop_s=$(state_get "HY2_HOP_START")
  hop_e=$(state_get "HY2_HOP_END")
  if is_ipv6 "$ip"; then
    tag="Hy2-IPv6"
  else
    tag="Hy2-IPv4"
  fi
  # 标准 URI：主机后必须是单一端口；端口跳跃用查询参数 mport=start-end
  # 错误示例（多数客户端解析失败、导入 0 条）:
  #   hysteria2://pass@ip:38324-40323?...
  # 正确:
  #   hysteria2://pass@ip:30585?mport=38324-40323&...
  qs="insecure=1&sni=www.apple.com"
  if [[ "$(state_get HY2_HOP)" == "1" && -n "$hop_s" && -n "$hop_e" ]]; then
    qs+="&mport=${hop_s}-${hop_e}"
    tag="${tag}-hop"
  fi
  if [[ -n "$obfs" ]]; then
    qs+="&obfs=salamander&obfs-password=$(urlencode "$obfs")"
  fi
  name=$(urlencode "$tag")
  # 密码中的特殊字符需编码（但当前生成的是字母数字）
  echo "hysteria2://${pass}@${host}:${port}?${qs}#${name}"
}

# VLESS+WS 链接：地址可用 CF 优选 IP；Host/SNI 用域名
# $1=连接地址(可优选IP)  缺省用域名 Host
build_ws_link() {
  local addr host_hdr path port uuid name enc_path enc_host
  addr="${1:-}"
  host_hdr=$(state_get "XRAY_WS_HOST")
  path=$(state_get "XRAY_WS_PATH")
  port=$(state_get "XRAY_WS_PORT")
  uuid=$(state_get "XRAY_UUID")
  [[ -z "$addr" ]] && addr="$host_hdr"
  # 客户端经 CF：地址=优选IP，端口=443，security=tls，sni/host=域名
  # 源站直连调试：地址=服务器IP，端口=源站端口，security=none
  enc_path=$(urlencode "$path")
  enc_host=$(urlencode "$host_hdr")
  name=$(urlencode "VLESS-WS-CF")
  # 默认生成「走 CF 443 TLS」形态（优选 IP 场景）
  if [[ -n "${2:-}" && "$2" == "direct" ]]; then
    local h
    h=$(format_host_for_uri "$addr")
    name=$(urlencode "VLESS-WS-direct")
    echo "vless://${uuid}@${h}:${port}?encryption=none&security=none&type=ws&host=${enc_host}&path=${enc_path}#${name}"
  else
    local h
    h=$(format_host_for_uri "$addr")
    echo "vless://${uuid}@${h}:443?encryption=none&security=tls&type=ws&host=${enc_host}&path=${enc_path}&sni=${enc_host}&fp=chrome#${name}"
  fi
}

print_qr() {
  local content="$1" title="${2:-QR}"
  if command -v qrencode &>/dev/null; then
    echo -e "${C_BOLD}--- ${title} 二维码 ---${C_RESET}"
    qrencode -t ANSIUTF8 "$content" 2>/dev/null || qrencode -t UTF8 "$content" 2>/dev/null || true
  else
    log_warn "未安装 qrencode，跳过二维码（apt install qrencode）"
  fi
}

show_xray_link() {
  if [[ "$(state_get XRAY_INSTALLED)" != "1" ]]; then
    return 0
  fi
  local ip6 ip4 link_primary link_v4
  ip6=$(get_public_ipv6 2>/dev/null || true)
  ip4=$(get_public_ipv4 2>/dev/null || true)
  if is_ipv6 "$ip6"; then
    link_primary=$(build_vless_link "$ip6")
  else
    link_primary=$(build_vless_link "${ip4:-$(get_public_ip)}")
  fi
  ui_section "REALITY-Vision"
  print_address_summary
  emit_line "端口    " "${C_GREEN}$(state_get XRAY_PORT)${C_RESET}  flow=xtls-rprx-vision"
  emit_line "UUID    " "$(state_get XRAY_UUID)"
  emit_line "SNI     " "$(state_get XRAY_SNI)"
  emit_line "PBK     " "$(state_get XRAY_PUBKEY)"
  emit_line "SID     " "$(state_get XRAY_SHORTID)  fp=chrome"
  hr
  emit_link_block "REALITY 导入链接" "$link_primary"
  if is_ipv6 "$ip6" && is_ipv4 "$ip4"; then
    link_v4=$(build_vless_link "$ip4")
    emit_link_block "REALITY IPv4 备用" "$link_v4"
  fi
}

show_hy2_link() {
  if [[ "$(state_get HY2_INSTALLED)" != "1" ]]; then
    return 0
  fi
  local ip6 ip4 link_primary link_v4
  ip6=$(get_public_ipv6 2>/dev/null || true)
  ip4=$(get_public_ipv4 2>/dev/null || true)
  if is_ipv6 "$ip6"; then
    link_primary=$(build_hy2_link "$ip6")
  else
    link_primary=$(build_hy2_link "${ip4:-$(get_public_ip)}")
  fi
  ui_section "Hysteria 2"
  print_address_summary
  emit_line "主端口  " "${C_GREEN}$(state_get HY2_PORT)/UDP${C_RESET}"
  if [[ "$(state_get HY2_HOP)" == "1" ]]; then
    emit_line "端口跳跃" "$(state_get HY2_HOP_START)-$(state_get HY2_HOP_END) → 主端口"
  else
    emit_line "端口跳跃" "未启用"
  fi
  emit_line "密码    " "$(state_get HY2_PASSWORD)"
  if [[ -n "$(state_get HY2_OBFS)" ]]; then
    emit_line "obfs    " "salamander · $(state_get HY2_OBFS)"
  else
    emit_line "混淆    " "未启用"
  fi
  emit_line "SNI     " "www.apple.com · insecure=1"
  local _tier _bw
  _tier=$(state_get "HY2_TIER"); _bw=$(state_get "HY2_BW")
  [[ -n "$_tier" ]] && emit_line "档位    " "${_tier} · ${_bw:-auto}"
  hr
  emit_link_block "Hysteria2 导入链接" "${link_primary%%#*}"
  if is_ipv6 "$ip6" && is_ipv4 "$ip4"; then
    link_v4=$(build_hy2_link "$ip4")
    emit_link_block "Hysteria2 IPv4 备用" "${link_v4%%#*}"
  fi
}

show_ws_link() {
  if [[ "$(state_get XRAY_WS_INSTALLED)" != "1" ]]; then
    return 0
  fi
  local host path port uuid link_cf link_direct ip4 tip4 tip6
  host=$(state_get "XRAY_WS_HOST")
  path=$(state_get "XRAY_WS_PATH")
  port=$(state_get "XRAY_WS_PORT")
  uuid=$(state_get "XRAY_UUID")
  ip4=$(get_public_ipv4 2>/dev/null || true)
  link_cf=$(build_ws_link "$host")
  link_direct=$(build_ws_link "${ip4:-$host}" "direct")
  ui_section "VLESS + WebSocket (CF Full)"
  tip4=$(get_public_ipv4 2>/dev/null || true)
  tip6=$(get_public_ipv6 2>/dev/null || true)
  emit_line "UUID    " "$uuid"
  emit_line "源站    " "https :${port}${path}"
  emit_line "Host/SNI" "$host"
  emit_line "客户端  " "域名或优选IP · 443 · TLS · 无 flow"
  emit_line "CF SSL  " "Full · 橙云 · 安全组 ${port}/tcp"
  [[ -n "$tip4" ]] && emit_line "DNS A   " "$tip4"
  [[ -n "$tip6" ]] && emit_line "DNS AAAA" "$tip6"
  hr
  emit_link_block "VLESS-WS-CF" "$link_cf"
  emit_link_block "VLESS-WS-direct(调试)" "$link_direct"
}

show_all_links() {
  local any=0
  is_reality_installed && any=1
  is_ws_installed && any=1
  is_hy2_installed && any=1
  if [[ $any -eq 0 ]]; then
    ui_section "节点"
    log_warn "尚未安装任何协议"
    return 0
  fi
  if [[ "${1:-}" != "quiet" ]]; then
    maybe_show_links
  fi
  share_write_header
  show_xray_link
  show_ws_link
  show_hy2_link
  share_flush_notice
  if ! links_visible; then
    log_tip "显示完整链接: 菜单[3]选 y  或  SHOW_LINKS=1 sudo $0 --links"
  fi
}

# 一键诊断：本机监听 / 服务 / 常见 CF 坑提示
run_diagnose() {
  ui_section "诊断"
  svc_active "$XRAY_SVC" 2>/dev/null && log_ok "xray 运行" || log_info "xray 未运行"
  svc_active "$HY2_SVC" 2>/dev/null && log_ok "hy2 运行" || log_info "hy2 未运行"
  if command -v ss &>/dev/null; then
    ss -lntup 2>/dev/null | grep -E 'vps_xray|vps_hysteria' | awk '{print "  "$1,$5}' || true
  fi
  if is_ws_installed; then
    local wp code
    wp=$(state_get XRAY_WS_PORT)
    if _is_cf_https_port "$wp"; then
      log_ok "WS :${wp} 合法 Full 端口"
    else
      log_err "WS :${wp} 不在 CF HTTPS 列表"
    fi
    code=$(curl -skS -o /dev/null -w '%{http_code}' --connect-timeout 2 \
      -H "Connection: Upgrade" -H "Upgrade: websocket" \
      -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
      -H "Sec-WebSocket-Protocol: binary" \
      -H "Host: $(state_get XRAY_WS_HOST)" \
      "https://127.0.0.1:${wp}$(state_get XRAY_WS_PATH)" 2>/dev/null || echo "000")
    # 400 有时是 curl 缺头；能连上端口即可，101 最佳
    if [[ "$code" == "101" ]]; then
      log_ok "本机 WS 101"
    elif [[ "$code" == "400" || "$code" == "000" ]]; then
      log_tip "本机探测 ${code}（端口已监听则可忽略；以 CF Full 为准）"
    else
      log_warn "本机 WS HTTP ${code}"
    fi
    log_tip "CF: 橙云 + Full + 放行 ${wp}/tcp"
  fi
  is_hy2_installed && log_ok "Hy2 :$(state_get HY2_PORT) hop=$(state_get HY2_HOP)"
  [[ -f "$SHARE_LINKS" ]] && log_tip "链接: cat ${SHARE_LINKS}"
}

#-------------------------------------------------------------------------------
#  服务运维
#-------------------------------------------------------------------------------
service_menu() {
  while true; do
    ui_section "服务管理"
    echo -e "  ${C_WHITE}[1]${C_RESET}  重启全部已装服务"
    echo -e "  ${C_WHITE}[2]${C_RESET}  停止全部"
    echo -e "  ${C_WHITE}[3]${C_RESET}  systemctl 状态"
    echo -e "  ${C_WHITE}[4]${C_RESET}  仅重启 Xray"
    echo -e "  ${C_WHITE}[5]${C_RESET}  仅重启 Hysteria2"
    echo -e "  ${C_WHITE}[6]${C_RESET}  连通诊断（推荐排错）"
    echo -e "  ${C_WHITE}[7]${C_RESET}  查看最近错误日志"
    echo -e "  ${C_WHITE}[0]${C_RESET}  返回"
    echo
    local c
    c=$(ask "选择" "0")
    case "$c" in
      1)
        svc_exists "$XRAY_SVC" && systemctl restart "$XRAY_SVC" && log_ok "Xray 已重启" || true
        svc_exists "$HY2_SVC" && systemctl restart "$HY2_SVC" && log_ok "Hy2 已重启" || true
        ;;
      2)
        svc_exists "$XRAY_SVC" && systemctl stop "$XRAY_SVC" && log_ok "Xray 已停止" || true
        svc_exists "$HY2_SVC" && systemctl stop "$HY2_SVC" && log_ok "Hy2 已停止" || true
        ;;
      3)
        svc_exists "$XRAY_SVC" && systemctl --no-pager -l status "$XRAY_SVC" || true
        svc_exists "$HY2_SVC" && systemctl --no-pager -l status "$HY2_SVC" || true
        ;;
      4) systemctl restart "$XRAY_SVC" && log_ok "Xray 已重启" || log_err "失败" ;;
      5) systemctl restart "$HY2_SVC" && log_ok "Hy2 已重启" || log_err "失败" ;;
      6) run_diagnose ;;
      7)
        echo
        [[ -f "${LOG_DIR}/xray-error.log" ]] && { log_info "xray-error (尾部):"; tail -n 30 "${LOG_DIR}/xray-error.log" 2>/dev/null | sed 's/^/    /' || true; }
        journalctl -u "$XRAY_SVC" -u "$HY2_SVC" -n 40 --no-pager 2>/dev/null | sed 's/^/    /' || true
        ;;
      0) return 0 ;;
      *) log_warn "请输入 0–7" ;;
    esac
    echo
  done
}

#-------------------------------------------------------------------------------
#  协议安装状态 / 多选解析
#-------------------------------------------------------------------------------
# 协议是否已安装（按 state，不依赖“是否在运行”）
is_reality_installed() { [[ "$(state_get XRAY_INSTALLED)" == "1" ]]; }
is_ws_installed()      { [[ "$(state_get XRAY_WS_INSTALLED)" == "1" ]]; }
is_hy2_installed()     { [[ "$(state_get HY2_INSTALLED)" == "1" ]]; }

# 解析多选编号：raw=用户输入 allow=允许的数字串如 "123"
# 支持: 1 | 1 3 | 1,3 | 13 | a/all（展开 allow 全部）
# 成功时打印去重后的编号（空格分隔）
parse_multi_choice() {
  local raw="$1" allow="$2"
  local out=() seen="|" i d
  raw=$(echo "${raw:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  [[ -z "$raw" ]] && return 1
  if [[ "$raw" == "a" || "$raw" == "all" || "$raw" == "*" ]]; then
    for (( i=0; i<${#allow}; i++ )); do
      out+=("${allow:i:1}")
    done
    printf '%s\n' "${out[*]}"
    return 0
  fi
  raw="${raw//,/}"
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  for (( i=0; i<${#raw}; i++ )); do
    d="${raw:i:1}"
    [[ "$allow" == *"$d"* ]] || return 1
    if [[ "$seen" != *"|${d}|"* ]]; then
      out+=("$d")
      seen+="${d}|"
    fi
  done
  [[ ${#out[@]} -gt 0 ]] || return 1
  printf '%s\n' "${out[*]}"
}

#---------- 安装：列出全部协议，多选要装哪些 ----------
menu_install() {
  local raw picks p t0 names=""
  ui_section "安装"
  printf "  ${C_WHITE}[1]${C_RESET} REALITY   %b%s\n" "$(status_label xray)" "$(status_extra xray)"
  printf "  ${C_WHITE}[2]${C_RESET} Hy2       %b%s\n" "$(status_label hy2)" "$(status_extra hy2)"
  printf "  ${C_WHITE}[3]${C_RESET} VLESS-WS  %b%s\n" "$(status_label ws)" "$(status_extra ws)"
  echo -e "  ${C_DIM}多选 13 / a 全选 / 0 返回${C_RESET}"
  echo
  raw=$(ask "安装" "")
  [[ -z "$raw" || "$raw" == "0" ]] && { log_info "已取消"; return 0; }
  if ! picks=$(parse_multi_choice "$raw" "123"); then
    log_warn "输入 1/2/3，多选如 13"
    return 0
  fi
  for p in $picks; do
    case "$p" in
      1) names+="REALITY " ;;
      2) names+="Hy2 " ;;
      3) names+="WS " ;;
    esac
  done
  log_ok "安装: ${names}"
  SHOW_LINKS=0
  share_write_header
  t0=$(date +%s)
  for p in $picks; do
    case "$p" in
      1) install_reality ;;
      2) install_hysteria2 ;;
      3) install_vless_ws ;;
    esac
  done
  echo
  log_ok "完成 $(( $(date +%s) - t0 ))s"
  share_flush_notice
}

#---------- 卸载：只列出【已安装】的协议，再多选 ----------
menu_uninstall() {
  local ids=() labels=() allow="" i=0 names="" raw picks p idx
  ui_section "卸载协议"
  if is_reality_installed; then
    i=$((i + 1)); ids+=("reality"); labels+=("REALITY"); allow+="$i"
    echo -e "  ${C_WHITE}[${i}]${C_RESET}  REALITY-Vision     $(status_label xray)"
  fi
  if is_hy2_installed; then
    i=$((i + 1)); ids+=("hy2"); labels+=("Hy2"); allow+="$i"
    echo -e "  ${C_WHITE}[${i}]${C_RESET}  Hysteria 2         $(status_label hy2)"
  fi
  if is_ws_installed; then
    i=$((i + 1)); ids+=("ws"); labels+=("VLESS-WS"); allow+="$i"
    echo -e "  ${C_WHITE}[${i}]${C_RESET}  VLESS+WS           $(status_label ws)"
  fi
  if [[ $i -eq 0 ]]; then
    echo
    log_warn "没有已安装的协议"
    log_info "请先选主菜单 [1] 安装"
    return 0
  fi
  hr
  echo -e "  ${C_DIM}多选编号 · 全选 ${C_CYAN}a${C_DIM} · 返回 ${C_CYAN}0${C_RESET}"
  echo
  raw=$(ask "要卸载哪些" "")
  [[ -z "$raw" || "$raw" == "0" ]] && { log_info "已取消"; return 0; }
  if ! picks=$(parse_multi_choice "$raw" "$allow"); then
    log_warn "只能选上面已列出的编号"
    return 0
  fi
  for p in $picks; do
    idx=$((p - 1))
    names+="${labels[idx]} "
  done
  if ! confirm "确认卸载 ${C_BOLD}${names}${C_RESET}？"; then
    log_info "已取消"
    return 0
  fi
  for p in $picks; do
    idx=$((p - 1))
    case "${ids[idx]}" in
      reality) uninstall_reality || true ;;
      hy2)     uninstall_hysteria2 || true ;;
      ws)      uninstall_vless_ws || true ;;
    esac
  done
  if ! any_protocol_installed; then
    # 无协议：清理脚本产生的全部文件（含 client-links.txt、缓存、sysctl…）
    uninstall_tg_accel || true
    rm -rf "$SHARE_DIR" "$CACHE_DIR" "$LOG_DIR" 2>/dev/null || true
    # 空沙盒则删根
    if [[ -d "$SANDBOX_ROOT" ]]; then
      # 若只剩空目录或 state，一并清
      rm -rf "$SANDBOX_ROOT"
    fi
    log_ok "已全部卸载，脚本文件已清理（含 ${SHARE_LINKS}）"
  else
    refresh_share_file 2>/dev/null || true
    log_ok "卸载完成 · 已更新分享文件"
  fi
}

#-------------------------------------------------------------------------------
#  主菜单
#-------------------------------------------------------------------------------
print_banner() {
  clear 2>/dev/null || true
  echo
  echo -e "  ${C_BOLD}Proxy Manager${C_RESET} ${C_DIM}v${SCRIPT_VERSION}${C_RESET}"
  printf "  REALITY  %b%s\n" "$(status_label xray)" "$(status_extra xray)"
  printf "  VLESS-WS %b%s\n" "$(status_label ws)" "$(status_extra ws)"
  printf "  Hy2      %b%s\n" "$(status_label hy2)" "$(status_extra hy2)"
  hr
  echo -e "  ${C_WHITE}[1]${C_RESET} 安装  ${C_WHITE}[2]${C_RESET} 卸载  ${C_WHITE}[3]${C_RESET} 节点"
  echo -e "  ${C_WHITE}[4]${C_RESET} 服务  ${C_WHITE}[5]${C_RESET} 诊断  ${C_WHITE}[0]${C_RESET} 退出"
  echo
}

main_loop() {
  while true; do
    print_banner
    local choice
    choice=$(ask "请选择" "")
    echo
    case "$choice" in
      1)  menu_install ;;
      2)  menu_uninstall ;;
      3)  show_all_links ;;
      4)  service_menu ;;
      5)  run_diagnose ;;
      0|q|Q)
        echo
        log_info "再见"
        exit 0
        ;;
      *)
        log_warn "请输入 0–5"
        ;;
    esac
    pause_return
  done
}

#-------------------------------------------------------------------------------
#  入口
#-------------------------------------------------------------------------------
usage() {
  cat <<EOF
用法: sudo $0 [选项]

  (无参数)          交互菜单
  -h, --help       帮助
  -v               版本
  --status         组件状态（无密钥）
  --diagnose       连通诊断（无密钥）
  --links          导出链接到文件（终端默认脱敏）
  --show-secrets   与 --links 联用：终端打印完整密钥
  SHOW_LINKS=1     终端打印完整导入链接

隐私:
  UUID/密码/端口/path 等正常显示
  完整导入链接默认隐藏，写入 ${SHARE_LINKS} (600)
  卸载协议时更新/删除该文件；无协议时清理脚本全部产物

一行安装:
  curl -fsSL https://raw.githubusercontent.com/wsx112233/debian11-Reality/main/get | sudo bash
EOF
}

print_status_once() {
  echo "REALITY  : $(status_label xray | sed 's/\x1b\[[0-9;]*m//g')$(status_extra xray)"
  echo "VLESS+WS : $(status_label ws | sed 's/\x1b\[[0-9;]*m//g')$(status_extra ws)"
  echo "Hy2      : $(status_label hy2 | sed 's/\x1b\[[0-9;]*m//g')$(status_extra hy2)"
  echo "TG_ACCEL : $(state_get TG_ACCEL)"
  echo "SHARE    : ${SHARE_LINKS}"
}

main() {
  local do_links=0 do_status=0 do_diag=0
  local a
  for a in "$@"; do
    case "$a" in
      -h|--help) usage; exit 0 ;;
      -v|--version) echo "proxy_manager.sh ${SCRIPT_VERSION}"; exit 0 ;;
      --show-links|--show-secrets) SHOW_LINKS=1 ;;
      --links) do_links=1 ;;
      --status) do_status=1 ;;
      --diagnose) do_diag=1 ;;
      "") ;;
      *)
        if [[ -n "$a" ]]; then
          log_err "未知参数: $a"
          usage
          exit 1
        fi
        ;;
    esac
  done

  check_root
  check_debian
  ensure_sandbox

  if [[ $do_status -eq 1 ]]; then
    print_status_once
    exit 0
  fi
  if [[ $do_diag -eq 1 ]]; then
    run_diagnose
    exit 0
  fi
  if [[ $do_links -eq 1 ]]; then
    if links_visible; then show_all_links; else show_all_links quiet; fi
    exit 0
  fi

  preflight || true
  main_loop
}

main "$@"
