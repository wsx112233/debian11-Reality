#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -gt 0 ]; then
  case "$1" in
    uninstall|remove)
      shift
      exec bash "$REPO_DIR/scripts/uninstall-reality-mosdns.sh" "$@"
      ;;
    install)
      shift
      exec bash "$REPO_DIR/scripts/install-reality-mosdns.sh" "$@"
      ;;
    *)
      exec bash "$REPO_DIR/scripts/install-reality-mosdns.sh" "$@"
      ;;
  esac
fi

ask_choice() {
  local prompt="$1" default="$2" answer
  printf '%s [%s]: ' "$prompt" "$default"
  read -r answer
  printf '%s\n' "${answer:-$default}"
}

echo "Reality + mosdns installer"
echo
echo "1) Install"
echo "2) Uninstall"
action="$(ask_choice "Choose action" "1")"

case "$action" in
  2)
    exec bash "$REPO_DIR/scripts/uninstall-reality-mosdns.sh"
    ;;
  1)
    ;;
  *)
    echo "Invalid action: $action" >&2
    exit 1
    ;;
esac

echo
echo "Deployment mode"
echo "1) Reality + mosdns without 3x-ui"
echo "2) Reality + mosdns with 3x-ui"
mode="$(ask_choice "Choose deployment mode" "1")"

case "$mode" in
  1) deployment="standalone" ;;
  2) deployment="3x-ui" ;;
  *) echo "Invalid deployment mode: $mode" >&2; exit 1 ;;
esac

echo
echo "Protocol"
echo "1) reality-vision"
echo "2) hysteria2"
echo "3) reality-vision + hysteria2"
protocol_choice="$(ask_choice "Choose protocol" "1")"

case "$protocol_choice" in
  1) protocol="reality-vision" ;;
  2) protocol="hysteria2" ;;
  3) protocol="reality-vision+hysteria2" ;;
  *) echo "Invalid protocol: $protocol_choice" >&2; exit 1 ;;
esac

reality_port=""
hysteria_port=""
dest="www.microsoft.com:443"
server_name="www.microsoft.com"

case "$protocol" in
  reality-vision|reality-vision+hysteria2)
    reality_port="$(ask_choice "Reality listening port" "443")"
    dest="$(ask_choice "Reality dest" "$dest")"
    server_name="$(ask_choice "Reality server-name" "$server_name")"
    ;;
esac

case "$protocol" in
  hysteria2|reality-vision+hysteria2)
    hysteria_port="$(ask_choice "Hysteria2 UDP listening port" "8443")"
    ;;
esac

echo
echo "Ready to install:"
echo "  deployment: $deployment"
echo "  protocol:   $protocol"
[ -z "$reality_port" ] || echo "  reality:    $reality_port -> $dest / $server_name"
[ -z "$hysteria_port" ] || echo "  hysteria2:  $hysteria_port/udp"
printf 'Continue installation? [Y/n]: '
read -r confirm
case "${confirm:-Y}" in
  y|Y|yes|YES) ;;
  *) echo "Cancelled."; exit 0 ;;
esac

args=(--deployment "$deployment" --protocol "$protocol")
[ -z "$reality_port" ] || args+=(--port "$reality_port" --dest "$dest" --server-name "$server_name")
[ -z "$hysteria_port" ] || args+=(--hysteria-port "$hysteria_port")

exec bash "$REPO_DIR/scripts/install-reality-mosdns.sh" "${args[@]}"
