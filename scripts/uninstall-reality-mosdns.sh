#!/usr/bin/env bash
set -Eeuo pipefail

STACK_NAME="reality-mosdns-stack"
STATE_DIR="${STATE_DIR:-/var/lib/$STACK_NAME}"
MANIFEST="$STATE_DIR/manifest.env"
LOCK_DIR="/var/lock/$STACK_NAME.lock"
YES=0
PURGE_MOSDNS_CONFIG=1
PURGE_REALITY=1
PURGE_HYSTERIA=1
SELECT_PROTOCOL=""

usage() {
  cat <<'USAGE'
Usage:
  sudo bash scripts/uninstall-reality-mosdns.sh [options]

Options:
  --yes                 Run without interactive confirmation.
  --keep-mosdns-config  Keep /etc/mosdns.
  --keep-reality        Do not remove Xray/Hysteria files.
  --protocol VALUE      all, reality-vision, hysteria2, or reality-vision+hysteria2.
  -h, --help            Show this help.

This script removes files created by scripts/install-reality-mosdns.sh.
If mosdns or Xray existed before install, the matching cleanup is skipped.
USAGE
}

log() {
  printf '[%s] %s\n' "$STACK_NAME" "$*" >&2
}

die() {
  printf '[%s] 错误: %s\n' "$STACK_NAME" "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    --keep-mosdns-config) PURGE_MOSDNS_CONFIG=0 ;;
    --keep-reality) PURGE_REALITY=0 ;;
    --protocol) shift; [ "$#" -gt 0 ] || die "Missing value for --protocol"; SELECT_PROTOCOL="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift || true
done

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行：sudo bash scripts/uninstall-reality-mosdns.sh"
[ -f "$MANIFEST" ] || die "未找到安装清单: $MANIFEST"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  die "另一个 $STACK_NAME 操作正在运行，或锁文件未清理: $LOCK_DIR"
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# shellcheck disable=SC1090
. "$MANIFEST"

if [ -z "$SELECT_PROTOCOL" ] && [ "$YES" -ne 1 ]; then
  echo "选择要卸载的协议"
  echo "1) 全部"
  echo "2) reality-vision"
  echo "3) hysteria2"
  echo "4) reality-vision + hysteria2"
  printf '请选择要卸载的协议 [1]: '
  read -r protocol_answer
  case "${protocol_answer:-1}" in
    1) SELECT_PROTOCOL="all" ;;
    2) SELECT_PROTOCOL="reality-vision" ;;
    3) SELECT_PROTOCOL="hysteria2" ;;
    4) SELECT_PROTOCOL="reality-vision+hysteria2" ;;
    *) die "无效协议选择: $protocol_answer" ;;
  esac
fi

SELECT_PROTOCOL="${SELECT_PROTOCOL:-all}"
case "$SELECT_PROTOCOL" in
  all) ;;
  reality|reality-vision) PURGE_HYSTERIA=0; PURGE_MOSDNS_CONFIG=0 ;;
  hysteria2) PURGE_REALITY=0; PURGE_MOSDNS_CONFIG=0 ;;
  reality+hysteria2|reality-vision+hysteria2) PURGE_MOSDNS_CONFIG=0 ;;
  *) die "不支持的协议: $SELECT_PROTOCOL" ;;
esac

safe_remove() {
  local p="$1"
  case "$p" in
    /etc/mosdns|/etc/mosdns/*|/usr/local/bin/mosdns|/usr/local/bin/mosdns-*|/usr/local/bin/reality-mosdns|/etc/systemd/system/mosdns.service|/etc/logrotate.d/mosdns|/var/log/mosdns.log|/usr/local/bin/xray|/usr/local/etc/xray|/usr/local/etc/xray/*|/etc/xray|/etc/xray/*|/etc/systemd/system/xray.service|/lib/systemd/system/xray.service|/usr/local/bin/hysteria|/usr/local/bin/hysteria2|/etc/hysteria|/etc/hysteria/*|/etc/systemd/system/hysteria2.service|/var/lib/reality-mosdns-stack/manifest.env)
      if [ -e "$p" ] || [ -L "$p" ]; then
        rm -rf "$p"
      fi
      ;;
    *)
      die "拒绝删除非预期路径: $p"
      ;;
  esac
}

if [ "$YES" -ne 1 ]; then
  cat <<EOF
即将卸载 $STACK_NAME。

安装记录:
  mosdns 已安装:  ${INSTALL_MOSDNS:-0}
  reality 已安装: ${INSTALL_REALITY:-0}
  mosdns 原本存在: ${MOSDNS_PREEXISTING:-unknown}
  xray 原本存在:   ${XRAY_PREEXISTING:-unknown}

清理策略:
  - 选择协议: $SELECT_PROTOCOL
  - 安装前已存在的服务不会被删除。
  - 不删除 apt 包，因为它们可能被生产环境其他服务共用。
  - 防火墙和 sysctl 改动无法安全推断，如曾手动调整，请自行复核。
EOF
  printf '继续卸载？[y/N] '
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) die "已取消。" ;;
  esac
fi

if [ "${INSTALL_MOSDNS:-0}" = "1" ] && [ "${MOSDNS_PREEXISTING:-1}" = "0" ]; then
  log "Removing mosdns service and binaries."
  systemctl disable --now mosdns >/dev/null 2>&1 || true
  safe_remove /etc/systemd/system/mosdns.service
  safe_remove /usr/local/bin/mosdns
  safe_remove /usr/local/bin/mosdns-update-rules
  safe_remove /usr/local/bin/mosdns-benchmark
  safe_remove /etc/logrotate.d/mosdns
  safe_remove /var/log/mosdns.log
  if [ "$PURGE_MOSDNS_CONFIG" -eq 1 ]; then
    safe_remove /etc/mosdns
  fi
else
  log "Skipping mosdns cleanup because it was preexisting or not installed by this stack."
fi

if [ "$PURGE_REALITY" -eq 1 ] && [ "${INSTALL_REALITY:-0}" = "1" ] && [ "${XRAY_PREEXISTING:-1}" = "0" ]; then
  log "Removing common Reality/Xray/Hysteria artifacts created by debian11-Reality."
  systemctl disable --now xray >/dev/null 2>&1 || true
  systemctl disable --now hysteria2 >/dev/null 2>&1 || true
  safe_remove /etc/systemd/system/xray.service
  safe_remove /lib/systemd/system/xray.service
  safe_remove /usr/local/bin/xray
  safe_remove /usr/local/etc/xray
  safe_remove /etc/xray
  safe_remove /etc/systemd/system/hysteria2.service
  safe_remove /usr/local/bin/hysteria
  safe_remove /usr/local/bin/hysteria2
else
  log "Skipping Reality/Xray cleanup because it was preexisting, disabled, or not installed by this stack."
fi

if [ "$PURGE_HYSTERIA" -eq 1 ] && [ "${INSTALL_HYSTERIA:-0}" = "1" ] && [ "${XRAY_PREEXISTING:-1}" = "0" ]; then
  log "Removing Hysteria2 artifacts."
  systemctl disable --now hysteria2 >/dev/null 2>&1 || true
  safe_remove /etc/systemd/system/hysteria2.service
  safe_remove /usr/local/bin/hysteria
  safe_remove /usr/local/bin/hysteria2
  safe_remove /etc/hysteria
else
  log "Skipping Hysteria2 cleanup because it was preexisting, disabled, or not installed by this stack."
fi

systemctl daemon-reload || true
systemctl reset-failed mosdns xray hysteria2 >/dev/null 2>&1 || true

safe_remove "${GLOBAL_CLI:-/usr/local/bin/reality-mosdns}"
safe_remove "$MANIFEST"
rmdir "$STATE_DIR" >/dev/null 2>&1 || true

log "Uninstall complete."
