#!/usr/bin/env bash
set -euo pipefail
readonly SCRIPT_VERSION="1.4.0"
readonly SANDBOX_ROOT="/etc/vps_proxy_mgr"
readonly BIN_DIR="/usr/local/bin"
readonly XRAY_BIN="${BIN_DIR}/vps_xray"
readonly HY2_BIN="${BIN_DIR}/vps_hysteria"
readonly XRAY_DIR="${SANDBOX_ROOT}/xray"
readonly HY2_DIR="${SANDBOX_ROOT}/hysteria2"
readonly OPT_DIR="${SANDBOX_ROOT}/optimize"
readonly LOG_DIR="${SANDBOX_ROOT}/logs"
readonly CACHE_DIR="${SANDBOX_ROOT}/cache"
readonly STATE_FILE="${SANDBOX_ROOT}/state.env"
# 旧版 WARP 残留清理用（不再安装）
readonly WARP_DIR="${SANDBOX_ROOT}/warp"

# 安装速度相关：缓存 TTL（秒）
readonly IP_CACHE_TTL=600
readonly APT_CACHE_TTL=1800
readonly VER_CACHE_TTL=3600
readonly SNI_PROBE_TIMEOUT=3
readonly SNI_PROBE_PARALLEL=6
readonly DL_CONNECT_TIMEOUT=8
readonly DL_MAX_TIME=180

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

# 颜色
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'

#-------------------------------------------------------------------------------
#  日志与工具函数
#-------------------------------------------------------------------------------
log_info()  { echo -e "${C_CYAN}[INFO]${C_RESET}  $*"; }
log_ok()    { echo -e "${C_GREEN}[ OK ]${C_RESET}  $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
log_err()   { echo -e "${C_RED}[ERR ]${C_RESET}  $*" >&2; }
log_step()  { echo -e "${C_BLUE}${C_BOLD}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }

die() {
  log_err "$*"
  exit 1
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
    reply=$(_tty_read "$(echo -e "${C_YELLOW}${prompt}${C_RESET} [${default}]: ")")
    echo "${reply:-$default}"
  else
    reply=$(_tty_read "$(echo -e "${C_YELLOW}${prompt}${C_RESET}: ")")
    echo "${reply:-}"
  fi
}

confirm() {
  local prompt="$1"
  local reply
  reply=$(_tty_read "$(echo -e "${C_YELLOW}${prompt} [y/N]${C_RESET}: ")")
  [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
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
  mkdir -p "$SANDBOX_ROOT" "$XRAY_DIR" "$HY2_DIR" "$OPT_DIR" "$LOG_DIR" "$CACHE_DIR"
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
        if svc_active "$XRAY_SVC"; then
          echo -e "${C_GREEN}运行中${C_RESET}"
        else
          echo -e "${C_YELLOW}已停止${C_RESET}"
        fi
      else
        echo -e "${C_DIM}未安装${C_RESET}"
      fi
      ;;
    ws)
      if [[ "$(state_get XRAY_WS_INSTALLED)" == "1" ]] && [[ -x "$XRAY_BIN" ]] && svc_exists "$XRAY_SVC"; then
        if svc_active "$XRAY_SVC"; then
          echo -e "${C_GREEN}运行中${C_RESET}"
        else
          echo -e "${C_YELLOW}已停止${C_RESET}"
        fi
      else
        echo -e "${C_DIM}未安装${C_RESET}"
      fi
      ;;
    hy2)
      if [[ -x "$HY2_BIN" ]] && svc_exists "$HY2_SVC"; then
        if svc_active "$HY2_SVC"; then
          echo -e "${C_GREEN}运行中${C_RESET}"
        else
          echo -e "${C_YELLOW}已停止${C_RESET}"
        fi
      else
        echo -e "${C_DIM}未安装${C_RESET}"
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

prompt_port() {
  local proto="$1" default="$2" label="${3:-端口}"
  local port
  while true; do
    port=$(ask "请输入 ${label} (${proto^^})" "$default")
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      log_warn "端口无效，请输入 1-65535"
      continue
    fi
    if port_in_use "$port" "$proto"; then
      log_warn "端口 ${port}/${proto} 已被占用："
      port_who "$port" "$proto" | sed 's/^/    /' || true
      log_warn "常见占用进程：nginx / caddy / apache2 / 其他代理"
      if confirm "仍要使用该端口（可能冲突）？"; then
        echo "$port"
        return 0
      fi
      continue
    fi
    echo "$port"
    return 0
  done
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
  local rules port proto r
  rules=$(state_get "FW_RULES")
  IFS=',' read -ra arr <<< "$rules"
  for r in "${arr[@]}"; do
    [[ -z "$r" ]] && continue
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
#  下载工具（短超时快速失败 + 多镜像）
#-------------------------------------------------------------------------------
download() {
  local url="$1" dest="$2"
  log_info "下载: ${url##*/} ..."
  # 连接超时短、整体上限可控；失败立即换镜像，避免卡死
  if curl -fL --retry 1 --retry-delay 1 \
      --connect-timeout "$DL_CONNECT_TIMEOUT" \
      --max-time "$DL_MAX_TIME" \
      --speed-time 15 --speed-limit 1024 \
      -o "$dest" "$url" 2>/dev/null; then
    [[ -s "$dest" ]] && return 0
  fi
  if command -v wget &>/dev/null; then
    wget -q --tries=1 --timeout="$DL_CONNECT_TIMEOUT" -O "$dest" "$url" 2>/dev/null && [[ -s "$dest" ]] && return 0
  fi
  rm -f "$dest" 2>/dev/null || true
  return 1
}

# 构造 GitHub 多镜像列表（官方 + 常用加速）
github_mirrors() {
  local url="$1"
  printf '%s\n' \
    "$url" \
    "https://ghfast.top/${url}" \
    "https://mirror.ghproxy.com/${url}" \
    "https://ghproxy.net/${url}" \
    "https://gh-proxy.com/${url}"
}

# 带缓存的 GitHub latest tag
github_latest_tag() {
  local api="$1" cache_key="$2" fallback="$3"
  local ver
  ver=$(cache_get "$cache_key" "$VER_CACHE_TTL" 2>/dev/null || true)
  if [[ -n "$ver" ]]; then
    log_info "使用缓存版本: ${ver}"
    echo "$ver"
    return 0
  fi
  ver=$(curl -fsSL --connect-timeout 5 --max-time 10 "$api" 2>/dev/null | jq -r '.tag_name // empty' || true)
  if [[ -z "$ver" ]]; then
    # API 镜像兜底
    ver=$(curl -fsSL --connect-timeout 5 --max-time 10 "https://ghfast.top/${api}" 2>/dev/null \
      | jq -r '.tag_name // empty' || true)
  fi
  if [[ -n "$ver" ]]; then
    cache_set "$cache_key" "$ver"
    echo "$ver"
    return 0
  fi
  log_warn "GitHub API 不可用，使用回退版本 ${fallback}"
  echo "$fallback"
}

#-------------------------------------------------------------------------------
#  Xray REALITY-Vision 安装
#-------------------------------------------------------------------------------
install_xray_binary() {
  local arch asset_name url tmp ver
  arch=$(detect_arch)
  # Xray 发布包命名：Xray-linux-64 / Xray-linux-arm64-v8a
  case "$arch" in
    amd64) asset_name="Xray-linux-64.zip" ;;
    arm64) asset_name="Xray-linux-arm64-v8a.zip" ;;
  esac

  log_step "获取 Xray-core 最新版本"
  ver=$(github_latest_tag "$XRAY_GITHUB_API" "xray_ver" "v25.3.6")
  url="https://github.com/XTLS/Xray-core/releases/download/${ver}/${asset_name}"

  tmp=$(mktemp -d)
  local ok=0 m
  while read -r m; do
    [[ -z "$m" ]] && continue
    if download "$m" "${tmp}/xray.zip"; then
      ok=1
      break
    fi
    log_warn "镜像失败，尝试下一个..."
  done < <(github_mirrors "$url")
  if [[ $ok -ne 1 ]]; then
    rm -rf "$tmp"
    die "Xray 下载失败，请检查网络或 GitHub 连通性"
  fi

  unzip -qo "${tmp}/xray.zip" -d "${tmp}/out"
  if [[ ! -f "${tmp}/out/xray" ]]; then
    rm -rf "$tmp"
    die "Xray 压缩包内未找到二进制"
  fi
  install -m 755 "${tmp}/out/xray" "$XRAY_BIN"
  [[ -f "${tmp}/out/geoip.dat" ]] && install -m 644 "${tmp}/out/geoip.dat" "${XRAY_DIR}/geoip.dat"
  [[ -f "${tmp}/out/geosite.dat" ]] && install -m 644 "${tmp}/out/geosite.dat" "${XRAY_DIR}/geosite.dat"
  rm -rf "$tmp"
  log_ok "Xray 已安装: $($XRAY_BIN version 2>/dev/null | head -1 || echo "$ver")"
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
  log_ok "已生成 x25519 / shortId（UUID=${uuid}）"
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
    [[ -n "$w_port" && -n "$w_path" ]] || die "VLESS+WS 状态不完整，请重装"
    need=1
    [[ -n "$inbounds" ]] && inbounds+=","
    # 无 TLS：便于 Cloudflare 橙云 Flexible / 或客户端直连后自建 CDN TLS
    # 推荐：CF 源站 HTTP，客户端连 CF 优选 IP + 域名 TLS
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
        "security": "none",
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

# 静默启用 TG 加速资料（不装 WARP、不改 BBR 菜单；不破坏系统路由）
ensure_tg_accel() {
  if [[ "$(state_get TG_ACCEL)" == "1" ]] && [[ -f "${OPT_DIR}/telegram_cidrs.txt" ]]; then
    return 0
  fi
  write_tg_cidr_hint
  # 轻量 UDP 缓冲（仅写入我们的 sysctl 文件；不强制改已有拥塞控制以外的系统策略）
  # 若文件已存在则刷新缓冲相关项；全协议卸载时会删除
  apply_tg_sysctl_quiet
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

# 全部协议卸完后清理 TG 加速残留
cleanup_tg_if_idle() {
  if any_protocol_installed; then
    return 0
  fi
  uninstall_tg_accel
}

uninstall_tg_accel() {
  # 只清本脚本写入的文件；不 purge 用户自装 WARP；清理旧版残留目录
  if [[ -f "$SYSCTL_FILE" ]]; then
    rm -f "$SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || true
  fi
  rm -rf "$OPT_DIR"
  # 旧版 WARP 沙盒残留（我们不再安装，但全清时去掉）
  if [[ -d "$WARP_DIR" ]]; then
    rm -rf "$WARP_DIR"
  fi
  rm -f /etc/apt/sources.list.d/vps-cloudflare-warp.list 2>/dev/null || true
  state_set "TG_ACCEL" "0"
  state_set "OPT_INSTALLED" "0"
  state_set "BBR_APPLIED" "0"
  state_set "WARP_INSTALLED" "0"
  state_set "WARP_SOCKS" ""
}

install_reality() {
  local t0 port sni
  t0=$(date +%s)
  log_step "安装 Xray REALITY-Vision (VLESS + TCP + REALITY + Vision)"
  ensure_sandbox
  install_deps

  if [[ "$(state_get XRAY_INSTALLED)" == "1" ]]; then
    log_warn "检测到已安装 REALITY"
    if ! confirm "是否覆盖重装？"; then
      return 0
    fi
    # 仅卸 REALITY 入站，保留 WS
    local oldp
    oldp=$(state_get "XRAY_PORT")
    [[ -n "$oldp" ]] && fw_remove "$oldp" "tcp" "vps_proxy_mgr_xray" || true
    state_set "XRAY_INSTALLED" "0"
  fi

  port=$(prompt_port "tcp" "443" "REALITY TCP 端口")
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

  log_ok "REALITY-Vision 安装完成（耗时 $(( $(date +%s) - t0 ))s）"
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
  local t0 port path host uuid
  t0=$(date +%s)
  log_step "安装 VLESS + WebSocket（可走 Cloudflare 优选 IP）"
  ensure_sandbox
  install_deps

  if [[ "$(state_get XRAY_WS_INSTALLED)" == "1" ]]; then
    log_warn "检测到已安装 VLESS+WS"
    if ! confirm "是否覆盖重装？"; then
      return 0
    fi
    local oldp
    oldp=$(state_get "XRAY_WS_PORT")
    [[ -n "$oldp" ]] && fw_remove "$oldp" "tcp" "vps_proxy_mgr_ws" || true
    state_set "XRAY_WS_INSTALLED" "0"
  fi

  port=$(prompt_port "tcp" "8080" "VLESS+WS 源站端口（CF 回源常用 80/8080）")
  path=$(ask "WebSocket path（以 / 开头）" "/$(rand_hex 8)")
  [[ "$path" == /* ]] || path="/${path}"
  host=$(ask "Host / 域名（CF 解析到本机的域名，可先填 IP）" "$(get_public_ipv4 2>/dev/null || get_public_ip)")

  if [[ ! -x "$XRAY_BIN" ]]; then
    install_xray_binary
  fi
  uuid=$(ensure_xray_uuid)
  state_set "XRAY_WS_PORT" "$port"
  state_set "XRAY_WS_PATH" "$path"
  state_set "XRAY_WS_HOST" "$host"
  state_set "XRAY_WS_INSTALLED" "1"
  rebuild_xray_config
  fw_allow "$port" "tcp" "vps_proxy_mgr_ws"
  ensure_tg_accel
  write_xray_systemd

  log_ok "VLESS+WS 安装完成（耗时 $(( $(date +%s) - t0 ))s）"
  log_info "CF 面板：DNS 橙云代理 → 源站 ${host}:${port}，SSL 建议 Full；客户端地址填 CF 优选 IP，Host/SNI 填域名"
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
  local arch asset_name url tmp ver
  arch=$(detect_arch)
  case "$arch" in
    amd64) asset_name="hysteria-linux-amd64" ;;
    arm64) asset_name="hysteria-linux-arm64" ;;
  esac

  log_step "获取 Hysteria2 最新版本"
  ver=$(github_latest_tag "$HY2_GITHUB_API" "hy2_ver" "app/v2.6.1")
  url="https://github.com/apernet/hysteria/releases/download/${ver}/${asset_name}"

  tmp=$(mktemp -d)
  local ok=0 m
  while read -r m; do
    [[ -z "$m" ]] && continue
    if download "$m" "${tmp}/hy2"; then
      ok=1
      break
    fi
    log_warn "镜像失败，尝试下一个..."
  done < <(github_mirrors "$url")
  if [[ $ok -ne 1 ]]; then
    rm -rf "$tmp"
    die "Hysteria2 下载失败"
  fi
  install -m 755 "${tmp}/hy2" "$HY2_BIN"
  rm -rf "$tmp"
  log_ok "Hysteria2 已安装: $($HY2_BIN version 2>/dev/null | head -1 || echo "$ver")"
}

gen_hy2_cert() {
  # REALITY 禁用微软系 SNI；Hy2 伪装站点使用 Apple 等大厂 HTTPS
  local masq_host="www.apple.com"
  log_info "生成自签名证书 (CN=${masq_host})"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 \
    -keyout "${HY2_DIR}/server.key" \
    -out "${HY2_DIR}/server.crt" \
    -subj "/CN=${masq_host}" \
    >/dev/null 2>&1
  chmod 600 "${HY2_DIR}/server.key" "${HY2_DIR}/server.crt"
  state_set "HY2_MASQ" "https://${masq_host}"
}

write_hy2_config() {
  local port="$1"
  local password masq tier nic_mbps bw_up bw_down
  local sw_init sw_max cw_init cw_max streams
  password=$(state_get "HY2_PASSWORD")
  if [[ -z "$password" ]]; then
    password=$(rand_password 24)
    state_set "HY2_PASSWORD" "$password"
  fi
  masq=$(state_get "HY2_MASQ")
  [[ -z "$masq" ]] && masq="https://www.apple.com"

  # 按内存分档 QUIC 窗口；按网卡速率设带宽（避免写死 1gbps 误导拥塞）
  tier=$(mem_tier)
  nic_mbps=$(detect_nic_mbps)
  case "$tier" in
    small)
      sw_init=2097152; sw_max=4194304
      cw_init=5242880; cw_max=10485760
      streams=512
      ;;
    medium)
      sw_init=4194304; sw_max=8388608
      cw_init=10485760; cw_max=20971520
      streams=1024
      ;;
    *)
      sw_init=8388608; sw_max=16777216
      cw_init=20971520; cw_max=41943040
      streams=2048
      ;;
  esac
  # 带宽声明：取网卡速率，最低 100 Mbps；格式 Hy2 可解析
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
# 内核 UDP 缓冲见 ${SYSCTL_FILE}；档位 ${tier}
listen: :${port}

tls:
  cert: ${HY2_DIR}/server.crt
  key: ${HY2_DIR}/server.key

auth:
  type: password
  password: "${password}"

masquerade:
  type: proxy
  proxy:
    url: ${masq}
    rewriteHost: true

# QUIC 窗口按内存分档（高丢包 / TG 视频友好）
quic:
  initStreamReceiveWindow: ${sw_init}
  maxStreamReceiveWindow: ${sw_max}
  initConnReceiveWindow: ${cw_init}
  maxConnReceiveWindow: ${cw_max}
  maxIdleTimeout: 30s
  maxIncomingStreams: ${streams}
  disablePathMTUDiscovery: false

bandwidth:
  up: ${bw_up}
  down: ${bw_down}

# 以服务端带宽为准，避免客户端低估导致限速
ignoreClientBandwidth: true
udpIdleTimeout: 60s
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
RestartSec=5s
LimitNOFILE=1048576
LimitNPROC=512
TasksMax=infinity
# 配合内核 rmem/wmem
Environment=HYSTERIA_LOG_LEVEL=warn
StandardOutput=append:${LOG_DIR}/hy2-stdout.log
StandardError=append:${LOG_DIR}/hy2-stderr.log

ProtectSystem=full
ProtectHome=true
ReadWritePaths=${SANDBOX_ROOT}
PrivateTmp=true

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
  local t0
  t0=$(date +%s)
  log_step "安装 Hysteria 2 (QUIC 抗丢包)"
  ensure_sandbox
  install_deps

  if [[ "$(state_get HY2_INSTALLED)" == "1" ]] || svc_exists "$HY2_SVC"; then
    log_warn "检测到已安装 Hysteria2"
    if ! confirm "是否覆盖重装？"; then
      return 0
    fi
    uninstall_hysteria2 || true
  fi

  local default_port="8443"
  # 若 443/UDP 空闲可优先（可与 REALITY 的 443/TCP 同端口协同）
  if ! port_in_use 443 "udp"; then
    default_port="443"
  fi
  local port
  port=$(prompt_port "udp" "$default_port" "Hysteria2 UDP 端口")

  install_hy2_binary
  gen_hy2_cert
  write_hy2_config "$port"
  fw_allow "$port" "udp" "vps_proxy_mgr_hy2"
  ensure_tg_accel
  write_hy2_systemd

  state_set "HY2_INSTALLED" "1"
  log_ok "Hysteria2 安装完成（耗时 $(( $(date +%s) - t0 ))s）"
  show_hy2_link
}

uninstall_hysteria2() {
  log_step "卸载 Hysteria2"
  local port
  port=$(state_get "HY2_PORT")
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
  log_step "彻底一键清理所有组件与残留"
  if ! confirm "确认删除 REALITY / VLESS-WS / Hy2 / TG加速 与沙盒目录？"; then
    log_info "已取消"
    return 0
  fi
  uninstall_reality || true
  uninstall_vless_ws || true
  uninstall_hysteria2 || true
  uninstall_tg_accel || true
  fw_remove_all_recorded || true
  rm -rf "$SANDBOX_ROOT"
  rm -f "$XRAY_BIN" "$HY2_BIN"
  rm -f "/etc/systemd/system/${XRAY_SVC}" "/etc/systemd/system/${HY2_SVC}"
  systemctl daemon-reload 2>/dev/null || true
  echo
  log_step "卸载后环境自检"
  local dirty=0 p
  for p in "$XRAY_BIN" "$HY2_BIN" "$SANDBOX_ROOT" "$SYSCTL_FILE" \
           "/etc/systemd/system/${XRAY_SVC}" "/etc/systemd/system/${HY2_SVC}" \
           "$OPT_DIR" "$WARP_DIR"; do
    if [[ -e "$p" ]]; then
      log_warn "仍存在: $p"
      dirty=1
    fi
  done
  if [[ $dirty -eq 0 ]]; then
    log_ok "自检通过：协议与 TG 加速残留已清空"
  else
    log_warn "存在残留项，可手动 rm（不影响系统包）"
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
  local ip host port pass name tag
  ip="${1:-}"
  [[ -z "$ip" ]] && ip=$(get_public_ip)
  host=$(format_host_for_uri "$ip")
  port=$(state_get "HY2_PORT")
  pass=$(state_get "HY2_PASSWORD")
  if is_ipv6 "$ip"; then
    tag="Hy2-IPv6"
  else
    tag="Hy2-IPv4"
  fi
  name=$(urlencode "$tag")
  echo "hysteria2://${pass}@${host}:${port}?insecure=1&sni=www.apple.com#${name}"
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
  if [[ "$(state_get XRAY_INSTALLED)" != "1" ]] && [[ ! -f "${XRAY_DIR}/config.json" ]]; then
    log_warn "REALITY 未安装"
    return 0
  fi
  local ip6 ip4 link_primary link_v4
  ip6=$(get_public_ipv6 2>/dev/null || true)
  ip4=$(get_public_ipv4 2>/dev/null || true)
  # 有 IPv6 则主链接用 IPv6
  if is_ipv6 "$ip6"; then
    link_primary=$(build_vless_link "$ip6")
  else
    link_primary=$(build_vless_link "${ip4:-$(get_public_ip)}")
  fi
  echo
  echo -e "${C_BOLD}${C_GREEN}======== Xray REALITY-Vision 节点参数 ========${C_RESET}"
  print_address_summary
  echo -e "  端口       : $(state_get XRAY_PORT)"
  echo -e "  监听       : :: (双栈，IPv4+IPv6)"
  echo -e "  UUID       : $(state_get XRAY_UUID)"
  echo -e "  流控 flow  : xtls-rprx-vision"
  echo -e "  传输       : tcp"
  echo -e "  安全       : reality"
  echo -e "  SNI        : $(state_get XRAY_SNI)"
  echo -e "  PublicKey  : $(state_get XRAY_PUBKEY)"
  echo -e "  ShortId    : $(state_get XRAY_SHORTID)"
  echo -e "  Fingerprint: chrome"
  echo
  if is_ipv6 "$ip6"; then
    echo -e "${C_CYAN}导入链接 (IPv6 优先):${C_RESET}"
  else
    echo -e "${C_CYAN}导入链接 (IPv4):${C_RESET}"
  fi
  echo "$link_primary"
  echo
  print_qr "$link_primary" "VLESS 优先"
  # 双栈都在时额外给出 IPv4 备用链接
  if is_ipv6 "$ip6" && is_ipv4 "$ip4"; then
    link_v4=$(build_vless_link "$ip4")
    echo
    echo -e "${C_DIM}备用 IPv4 链接:${C_RESET}"
    echo "$link_v4"
  fi
  echo -e "${C_GREEN}===============================================${C_RESET}"
}

show_hy2_link() {
  if [[ "$(state_get HY2_INSTALLED)" != "1" ]] && [[ ! -f "${HY2_DIR}/config.yaml" ]]; then
    log_warn "Hysteria2 未安装"
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
  echo
  echo -e "${C_BOLD}${C_GREEN}======== Hysteria2 节点参数 ========${C_RESET}"
  print_address_summary
  echo -e "  端口(UDP)  : $(state_get HY2_PORT)"
  echo -e "  监听       : :$(state_get HY2_PORT) (双栈 IPv4+IPv6)"
  echo -e "  密码       : $(state_get HY2_PASSWORD)"
  echo -e "  SNI        : www.apple.com"
  echo -e "  跳过证书验证: 是 (insecure=1，自签证书)"
  echo -e "  伪装       : $(state_get HY2_MASQ)"
  local _tier _bw
  _tier=$(state_get "HY2_TIER")
  _bw=$(state_get "HY2_BW")
  [[ -n "$_tier" ]] && echo -e "  性能档位   : ${_tier} · 带宽声明 ${_bw:-auto}"
  echo
  if is_ipv6 "$ip6"; then
    echo -e "${C_CYAN}导入链接 (IPv6 优先):${C_RESET}"
  else
    echo -e "${C_CYAN}导入链接 (IPv4):${C_RESET}"
  fi
  echo "$link_primary"
  echo
  print_qr "$link_primary" "Hy2 优先"
  if is_ipv6 "$ip6" && is_ipv4 "$ip4"; then
    link_v4=$(build_hy2_link "$ip4")
    echo
    echo -e "${C_DIM}备用 IPv4 链接:${C_RESET}"
    echo "$link_v4"
  fi
  echo -e "${C_GREEN}====================================${C_RESET}"
}

show_ws_link() {
  if [[ "$(state_get XRAY_WS_INSTALLED)" != "1" ]]; then
    log_warn "VLESS+WS 未安装"
    return 0
  fi
  local host path port uuid link_cf link_direct ip4
  host=$(state_get "XRAY_WS_HOST")
  path=$(state_get "XRAY_WS_PATH")
  port=$(state_get "XRAY_WS_PORT")
  uuid=$(state_get "XRAY_UUID")
  ip4=$(get_public_ipv4 2>/dev/null || true)
  # CF 优选：地址先填域名（用户可改为优选 IP）
  link_cf=$(build_ws_link "$host")
  link_direct=$(build_ws_link "${ip4:-$host}" "direct")
  echo
  echo -e "${C_BOLD}${C_GREEN}======== VLESS + WebSocket（CF 优选 IP）========${C_RESET}"
  echo -e "  UUID       : ${uuid}"
  echo -e "  源站端口   : ${port}  (Xray 本机监听，CF 回源)"
  echo -e "  Path       : ${path}"
  echo -e "  Host       : ${host}"
  echo -e "  传输       : ws"
  echo
  echo -e "${C_CYAN}【推荐】经 Cloudflare（客户端地址可改为优选 IP）:${C_RESET}"
  echo -e "  地址=域名或 CF 优选 IP · 端口=443 · TLS=开启 · SNI/Host=${host}"
  echo "$link_cf"
  echo
  print_qr "$link_cf" "VLESS-WS CF"
  echo
  echo -e "${C_DIM}【调试】直连源站（不经 CF）:${C_RESET}"
  echo "$link_direct"
  echo -e "${C_GREEN}================================================${C_RESET}"
}

show_all_links() {
  show_xray_link
  show_ws_link
  show_hy2_link
  if [[ -f "${OPT_DIR}/README-TG.txt" ]]; then
    echo
    echo -e "${C_DIM}TG 加速资料: ${OPT_DIR}/README-TG.txt${C_RESET}"
  fi
}

#-------------------------------------------------------------------------------
#  服务运维
#-------------------------------------------------------------------------------
service_menu() {
  while true; do
    echo
    echo -e "${C_BOLD}--- 服务运维 ---${C_RESET}"
    echo "  1) 重启全部已装服务"
    echo "  2) 停止全部已装服务"
    echo "  3) 查看状态 (systemctl status)"
    echo "  4) 仅重启 Xray"
    echo "  5) 仅重启 Hysteria2"
    echo "  0) 返回主菜单"
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
        svc_exists "$XRAY_SVC" && systemctl status "$XRAY_SVC" --no-pager -l || true
        svc_exists "$HY2_SVC" && systemctl status "$HY2_SVC" --no-pager -l || true
        ;;
      4) systemctl restart "$XRAY_SVC" && log_ok "Xray 已重启" || log_err "失败" ;;
      5) systemctl restart "$HY2_SVC" && log_ok "Hy2 已重启" || log_err "失败" ;;
      0) return 0 ;;
      *) log_warn "无效选项" ;;
    esac
  done
}

#-------------------------------------------------------------------------------
#  主菜单
#-------------------------------------------------------------------------------
print_banner() {
  clear 2>/dev/null || true
  echo -e "${C_CYAN}${C_BOLD}"
  cat <<'BANNER'
╔══════════════════════════════════════════════════════════╗
║         VPS Proxy Manager  ·  Debian 11/12/13            ║
║     REALITY  ·  VLESS+WS(CF)  ·  Hysteria2  ·  TG        ║
╚══════════════════════════════════════════════════════════╝
BANNER
  echo -e "${C_RESET}"
  echo -e "  版本 ${SCRIPT_VERSION}  ·  沙盒 ${SANDBOX_ROOT}"
  echo
  echo -e "  状态  REALITY  : $(status_label xray)"
  echo -e "  状态  VLESS+WS : $(status_label ws)"
  echo -e "  状态  Hy2      : $(status_label hy2)"
  echo
  echo -e "${C_BOLD}安装${C_RESET}"
  echo "  [1] 单独安装 REALITY-Vision"
  echo "  [2] 单独安装 Hysteria 2"
  echo "  [3] 单独安装 VLESS+WS（可用 Cloudflare 优选 IP）"
  echo "  [4] 一键组合安装 (REALITY + VLESS-WS + Hy2)"
  echo
  echo -e "${C_BOLD}卸载${C_RESET}"
  echo "  [5] 单独彻底卸载 REALITY"
  echo "  [6] 单独彻底卸载 Hysteria 2"
  echo "  [7] 单独彻底卸载 VLESS+WS"
  echo "  [8] 彻底一键清理所有组件与残留（含 TG 加速）"
  echo
  echo -e "${C_BOLD}运维${C_RESET}"
  echo "  [9] 查看节点参数 / 导入链接 / 二维码"
  echo "  [10] 重启 / 停止 / 查看服务状态"
  echo "  [0] 退出"
  echo
}

main_loop() {
  while true; do
    print_banner
    local choice
    choice=$(ask "请输入选项" "")
    echo
    case "$choice" in
      1)  install_reality ;;
      2)  install_hysteria2 ;;
      3)  install_vless_ws ;;
      4)  install_all ;;
      5)  uninstall_reality ;;
      6)  uninstall_hysteria2 ;;
      7)  uninstall_vless_ws ;;
      8)  uninstall_all ;;
      9)  show_all_links ;;
      10) service_menu ;;
      0|q|Q)
        log_info "再见"
        exit 0
        ;;
      *)
        log_warn "无效选项: ${choice}"
        ;;
    esac
    echo
    _tty_read "$(echo -e "${C_DIM}按 Enter 返回主菜单...${C_RESET}")" >/dev/null || true
  done
}

#-------------------------------------------------------------------------------
#  入口
#-------------------------------------------------------------------------------
usage() {
  cat <<EOF
用法: sudo $0 [选项]

  无参数          进入彩色交互菜单
  -h, --help     显示帮助
  -v, --version  显示版本
  --status       打印组件状态后退出

一行安装:
  curl -fsSL https://raw.githubusercontent.com/wsx112233/debian11-Reality/main/get | sudo bash

沙盒: ${SANDBOX_ROOT}
服务: ${XRAY_SVC} / ${HY2_SVC}
EOF
}

print_status_once() {
  echo "REALITY  : $(status_label xray | sed 's/\x1b\[[0-9;]*m//g')"
  echo "VLESS+WS : $(status_label ws | sed 's/\x1b\[[0-9;]*m//g')"
  echo "Hy2      : $(status_label hy2 | sed 's/\x1b\[[0-9;]*m//g')"
  echo "TG_ACCEL : $(state_get TG_ACCEL)"
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    -v|--version) echo "proxy_manager.sh ${SCRIPT_VERSION}"; exit 0 ;;
    --status)
      check_root
      check_debian
      print_status_once
      exit 0
      ;;
    "")
      ;;
    *)
      log_err "未知参数: $1"
      usage
      exit 1
      ;;
  esac
  check_root
  check_debian
  ensure_sandbox
  main_loop
}

main "$@"
