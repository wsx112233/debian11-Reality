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

service_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

manifest_has_reality() {
  [ -r /var/lib/reality-mosdns-stack/manifest.env ] || return 1
  (
    # shellcheck disable=SC1091
    . /var/lib/reality-mosdns-stack/manifest.env
    [ "${INSTALL_REALITY:-0}" = "1" ]
  )
}

manifest_has_hysteria() {
  [ -r /var/lib/reality-mosdns-stack/manifest.env ] || return 1
  (
    # shellcheck disable=SC1091
    . /var/lib/reality-mosdns-stack/manifest.env
    [ "${INSTALL_HYSTERIA:-0}" = "1" ]
  )
}

reality_installed() {
  manifest_has_reality && return 0
  [ -f /usr/local/etc/xray/client-link.txt ] && service_active xray
}

hysteria_installed() {
  manifest_has_hysteria && return 0
  [ -f /etc/hysteria/client-link.txt ] && service_active hysteria2
}

echo "Reality + mosdns 安装器"
echo
if reality_installed && hysteria_installed; then
  echo "检测到 reality-vision + hysteria2 已安装，无需重复安装。"
  echo "卸载请执行: sudo reality-mosdns uninstall"
  exit 0
elif reality_installed; then
  protocol="hysteria2"
  echo "检测到 reality-vision 已安装，将继续安装 hysteria2。"
elif hysteria_installed; then
  protocol="reality-vision"
  echo "检测到 hysteria2 已安装，将继续安装 reality-vision。"
else
  echo "协议"
  echo "1) reality-vision"
  echo "2) hysteria2"
  echo "3) reality-vision + hysteria2"
  echo "4) 退出"
  protocol_choice="$(ask_choice "请选择协议" "1")"

  case "$protocol_choice" in
    1) protocol="reality-vision" ;;
    2) protocol="hysteria2" ;;
    3) protocol="reality-vision+hysteria2" ;;
    4) echo "已退出。"; exit 0 ;;
    *) echo "无效协议: $protocol_choice" >&2; exit 1 ;;
  esac
fi

reality_port=""
hysteria_port=""
dest="www.microsoft.com:443"
server_name="www.microsoft.com"
has_existing_mosdns=0
has_existing_xray=0

if [ -e /etc/mosdns ] || [ -e /usr/local/bin/mosdns ]; then
  has_existing_mosdns=1
fi

if [ -e /usr/local/bin/xray ] || [ -e /usr/local/etc/xray ] || [ -e /etc/xray ] || [ -e /usr/local/bin/hysteria2 ] || [ -e /etc/hysteria ]; then
  has_existing_xray=1
fi

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
[ "$has_existing_mosdns" -eq 0 ] || echo "  已有 mosdns: 将复用或更新"
[ "$has_existing_xray" -eq 0 ] || echo "  已有 Xray/Hysteria: 将复用或更新"
echo "开始安装。"

args=(--yes --protocol "$protocol")
[ -z "$reality_port" ] || [ "$reality_port" = "auto" ] || args+=(--port "$reality_port")
case "$protocol" in
  reality-vision|reality-vision+hysteria2)
    args+=(--dest "$dest" --server-name "$server_name")
    ;;
esac
[ -z "$hysteria_port" ] || [ "$hysteria_port" = "auto" ] || args+=(--hysteria-port "$hysteria_port")

[ "$has_existing_mosdns" -eq 0 ] || args+=(--allow-existing-mosdns)
[ "$has_existing_xray" -eq 0 ] || args+=(--allow-existing-xray)

exec bash "$REPO_DIR/scripts/install-reality-mosdns.sh" "${args[@]}"
