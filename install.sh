#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -gt 0 ]; then
  case "$1" in
    install) shift ;;
  esac
  exec bash "$REPO_DIR/scripts/install-reality-mosdns.sh" "$@"
fi

ask_choice() {
  local prompt="$1" default="$2" answer
  printf '%s [%s]: ' "$prompt" "$default" >&2
  read -r answer
  printf '%s\n' "${answer:-$default}"
}

ask_yes_no() {
  local prompt="$1" default="$2" answer
  printf '%s [%s]: ' "$prompt" "$default" >&2
  read -r answer
  answer="${answer:-$default}"
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

echo "Reality + mosdns 安装器"
echo
echo "协议"
echo "1) reality-vision"
echo "2) hysteria2"
echo "3) reality-vision + hysteria2"
protocol_choice="$(ask_choice "请选择协议" "1")"

case "$protocol_choice" in
  1) protocol="reality-vision" ;;
  2) protocol="hysteria2" ;;
  3) protocol="reality-vision+hysteria2" ;;
  *) echo "无效协议: $protocol_choice" >&2; exit 1 ;;
esac

reality_port=""
hysteria_port=""
dest="www.microsoft.com:443"
server_name="www.microsoft.com"

case "$protocol" in
  reality-vision|reality-vision+hysteria2)
    reality_port="$(ask_choice "Reality 监听端口，直接回车自动选择未占用高位端口" "auto")"
    dest="$(ask_choice "Reality 回落目标 dest" "$dest")"
    server_name="$(ask_choice "Reality server-name" "$server_name")"
    ;;
esac

case "$protocol" in
  hysteria2|reality-vision+hysteria2)
    hysteria_port="$(ask_choice "Hysteria2 UDP 监听端口，直接回车自动选择未占用高位端口" "auto")"
    ;;
esac

echo
echo "即将安装:"
echo "  组件:     Reality + mosdns"
echo "  协议:     $protocol"
[ -z "$reality_port" ] || echo "  Reality:  $reality_port -> $dest / $server_name"
[ -z "$hysteria_port" ] || echo "  Hysteria2:$hysteria_port/udp"
printf '确认开始安装？[Y/n]: '
read -r confirm
case "${confirm:-Y}" in
  y|Y|yes|YES) ;;
  *) echo "已取消。"; exit 0 ;;
esac

args=(--yes --protocol "$protocol")
[ -z "$reality_port" ] || [ "$reality_port" = "auto" ] || args+=(--port "$reality_port")
case "$protocol" in
  reality-vision|reality-vision+hysteria2)
    args+=(--dest "$dest" --server-name "$server_name")
    ;;
esac
[ -z "$hysteria_port" ] || [ "$hysteria_port" = "auto" ] || args+=(--hysteria-port "$hysteria_port")

if [ -e /etc/mosdns ] || [ -e /usr/local/bin/mosdns ]; then
  if ask_yes_no "检测到已有 mosdns，是否允许本安装器复用或更新它？" "n"; then
    args+=(--allow-existing-mosdns)
  fi
fi

if [ -e /usr/local/bin/xray ] || [ -e /usr/local/etc/xray ] || [ -e /etc/xray ] || [ -e /usr/local/bin/hysteria2 ] || [ -e /etc/hysteria ]; then
  if ask_yes_no "检测到已有 Xray/Hysteria，是否允许本安装器复用或更新它？" "n"; then
    args+=(--allow-existing-xray)
  fi
fi

exec bash "$REPO_DIR/scripts/install-reality-mosdns.sh" "${args[@]}"
