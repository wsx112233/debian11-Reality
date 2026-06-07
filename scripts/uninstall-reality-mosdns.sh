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
PURGE_REPO_DIR=0
SELECT_PROTOCOL=""
LAST_PROTOCOL_UNINSTALL=0

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

service_known() {
  systemctl list-unit-files "$1" --no-legend 2>/dev/null | awk 'NF { found=1 } END { exit found ? 0 : 1 }'
}

if [ "${INSTALL_REALITY:-0}" != "1" ] && [ -f /usr/local/etc/xray/client-link.txt ] && service_known xray.service; then
  INSTALL_REALITY=1
  XRAY_PREEXISTING=0
  log "manifest 未记录 reality-vision，但检测到 Xray 客户端链接和服务，将按已安装处理。"
fi

if [ "${INSTALL_HYSTERIA:-0}" != "1" ] && [ -f /etc/hysteria/client-link.txt ] && service_known hysteria2.service; then
  INSTALL_HYSTERIA=1
  HYSTERIA_PREEXISTING=0
  log "manifest 未记录 hysteria2，但检测到 Hysteria2 客户端链接和服务，将按已安装处理。"
fi

if [ -z "$SELECT_PROTOCOL" ] && [ "$YES" -ne 1 ]; then
  echo "选择要卸载的协议"
  if [ "${INSTALL_REALITY:-0}" = "1" ] && [ "${INSTALL_HYSTERIA:-0}" = "1" ]; then
    echo "1) 全部"
    echo "2) reality-vision"
    echo "3) hysteria2"
    echo "4) reality-vision + hysteria2"
    echo "5) 退出"
    printf '请选择要卸载的协议 [1]: '
    read -r protocol_answer
    case "${protocol_answer:-1}" in
      1) SELECT_PROTOCOL="all" ;;
      2) SELECT_PROTOCOL="reality-vision" ;;
      3) SELECT_PROTOCOL="hysteria2" ;;
      4) SELECT_PROTOCOL="reality-vision+hysteria2" ;;
      5) echo "已退出。"; exit 0 ;;
      *) die "无效协议选择: $protocol_answer" ;;
    esac
  elif [ "${INSTALL_REALITY:-0}" = "1" ]; then
    SELECT_PROTOCOL="reality-vision"
    echo "仅检测到 reality-vision，将直接卸载。"
  elif [ "${INSTALL_HYSTERIA:-0}" = "1" ]; then
    SELECT_PROTOCOL="hysteria2"
    echo "仅检测到 hysteria2，将直接卸载。"
  else
    echo "未记录已安装协议。"
    echo "1) 清理残留"
    echo "2) 退出"
    printf '请选择操作 [1]: '
    read -r protocol_answer
    case "${protocol_answer:-1}" in
      1) SELECT_PROTOCOL="all" ;;
      2) echo "已退出。"; exit 0 ;;
      *) die "无效选择: $protocol_answer" ;;
    esac
  fi
fi

SELECT_PROTOCOL="${SELECT_PROTOCOL:-all}"
case "$SELECT_PROTOCOL" in
  reality|reality-vision)
    [ "${INSTALL_HYSTERIA:-0}" = "1" ] || LAST_PROTOCOL_UNINSTALL=1
    ;;
  hysteria2)
    [ "${INSTALL_REALITY:-0}" = "1" ] || LAST_PROTOCOL_UNINSTALL=1
    ;;
  reality+hysteria2|reality-vision+hysteria2)
    LAST_PROTOCOL_UNINSTALL=1
    ;;
esac

case "$SELECT_PROTOCOL" in
  all) PURGE_REPO_DIR=1 ;;
  reality|reality-vision)
    PURGE_HYSTERIA=0
    if [ "$LAST_PROTOCOL_UNINSTALL" -eq 1 ]; then
      PURGE_REPO_DIR=1
    else
      PURGE_MOSDNS_CONFIG=0
    fi
    ;;
  hysteria2)
    PURGE_REALITY=0
    if [ "$LAST_PROTOCOL_UNINSTALL" -eq 1 ]; then
      PURGE_REPO_DIR=1
    else
      PURGE_MOSDNS_CONFIG=0
    fi
    ;;
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

safe_remove_repo_dir() {
  local dir="${REPO_DIR:-}"
  [ "$PURGE_REPO_DIR" -eq 1 ] || return 0
  [ -n "$dir" ] || return 0

  case "$dir" in
    /*) ;;
    *) die "拒绝删除项目目录，REPO_DIR 不是绝对路径: $dir" ;;
  esac

  case "$dir" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "拒绝删除系统关键目录: $dir"
      ;;
  esac

  [ -f "$dir/install.sh" ] || die "拒绝删除项目目录，未找到 $dir/install.sh"
  [ -f "$dir/scripts/install-reality-mosdns.sh" ] || die "拒绝删除项目目录，未找到 $dir/scripts/install-reality-mosdns.sh"
  [ -f "$dir/mosdns/config.yaml" ] || die "拒绝删除项目目录，未找到 $dir/mosdns/config.yaml"

  log "Removing project directory: $dir"
  rm -rf -- "$dir"
}

quote() {
  printf '%q' "$1"
}

update_manifest_after_partial_uninstall() {
  [ "$PURGE_REPO_DIR" -eq 0 ] || return 0

  case "$SELECT_PROTOCOL" in
    reality|reality-vision)
      INSTALL_REALITY=0
      ;;
    hysteria2)
      INSTALL_HYSTERIA=0
      ;;
    reality+hysteria2|reality-vision+hysteria2)
      INSTALL_REALITY=0
      INSTALL_HYSTERIA=0
      ;;
  esac

  {
    printf 'STACK_NAME=%s\n' "$(quote "${STACK_NAME:-reality-mosdns-stack}")"
    printf 'INSTALLED_AT=%s\n' "$(quote "${INSTALLED_AT:-}")"
    printf 'UPDATED_AT=%s\n' "$(quote "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    printf 'REPO_DIR=%s\n' "$(quote "${REPO_DIR:-}")"
    printf 'LOG_FILE=%s\n' "$(quote "${LOG_FILE:-}")"
    printf 'INSTALL_MOSDNS=%s\n' "$(quote "${INSTALL_MOSDNS:-0}")"
    printf 'INSTALL_REALITY=%s\n' "$(quote "${INSTALL_REALITY:-0}")"
    printf 'INSTALL_HYSTERIA=%s\n' "$(quote "${INSTALL_HYSTERIA:-0}")"
    printf 'MOSDNS_PREEXISTING=%s\n' "$(quote "${MOSDNS_PREEXISTING:-1}")"
    printf 'XRAY_PREEXISTING=%s\n' "$(quote "${XRAY_PREEXISTING:-1}")"
    printf 'HYSTERIA_PREEXISTING=%s\n' "$(quote "${HYSTERIA_PREEXISTING:-${XRAY_PREEXISTING:-1}}")"
    printf 'REALITY_INSTALL_URL=%s\n' "$(quote "${REALITY_INSTALL_URL:-}")"
    printf 'REALITY_SCRIPT_SHA256=%s\n' "$(quote "${REALITY_SCRIPT_SHA256:-}")"
    printf 'REALITY_PROTOCOL=%s\n' "$(quote "${REALITY_PROTOCOL:-}")"
    printf 'HYSTERIA_PORT=%s\n' "$(quote "${HYSTERIA_PORT:-}")"
    printf 'GLOBAL_CLI=%s\n' "$(quote "${GLOBAL_CLI:-/usr/local/bin/reality-mosdns}")"
  } >"$MANIFEST"
  chmod 0644 "$MANIFEST"
}

if [ "$YES" -ne 1 ]; then
  if [ "$PURGE_REPO_DIR" -eq 1 ]; then
    repo_cleanup_text="会删除安装目录: ${REPO_DIR:-unknown}"
  else
    repo_cleanup_text="不会删除安装目录"
  fi
  cat <<EOF
即将卸载 $STACK_NAME。

安装记录:
  mosdns 已安装:  ${INSTALL_MOSDNS:-0}
  reality 已安装: ${INSTALL_REALITY:-0}
  hysteria2 已安装: ${INSTALL_HYSTERIA:-0}
  mosdns 原本存在: ${MOSDNS_PREEXISTING:-unknown}
  xray 原本存在:   ${XRAY_PREEXISTING:-unknown}
  hysteria 原本存在: ${HYSTERIA_PREEXISTING:-${XRAY_PREEXISTING:-unknown}}

清理策略:
  - 选择协议: $SELECT_PROTOCOL
  - 安装前已存在的服务不会被删除。
  - 安装目录: $repo_cleanup_text
  - 不删除 apt 包，因为它们可能被生产环境其他服务共用。
  - 防火墙和 sysctl 改动无法安全推断，如曾手动调整，请自行复核。
EOF
  echo "开始卸载。"
fi

if { [ "${INSTALL_MOSDNS:-0}" = "1" ] || [ "$SELECT_PROTOCOL" = "all" ]; } && [ "${MOSDNS_PREEXISTING:-1}" = "0" ]; then
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

if [ "$PURGE_REALITY" -eq 1 ] && { [ "${INSTALL_REALITY:-0}" = "1" ] || [ "$SELECT_PROTOCOL" = "all" ]; } && [ "${XRAY_PREEXISTING:-1}" = "0" ]; then
  log "Removing Reality/Xray artifacts."
  systemctl disable --now xray >/dev/null 2>&1 || true
  safe_remove /etc/systemd/system/xray.service
  safe_remove /lib/systemd/system/xray.service
  safe_remove /usr/local/bin/xray
  safe_remove /usr/local/etc/xray
  safe_remove /etc/xray
else
  log "Skipping Reality/Xray cleanup because it was preexisting, disabled, or not installed by this stack."
fi

if [ "$PURGE_HYSTERIA" -eq 1 ] && { [ "${INSTALL_HYSTERIA:-0}" = "1" ] || [ "$SELECT_PROTOCOL" = "all" ]; } && [ "${HYSTERIA_PREEXISTING:-${XRAY_PREEXISTING:-1}}" = "0" ]; then
  log "Removing Hysteria2 artifacts."
  systemctl disable --now hysteria2 >/dev/null 2>&1 || true
  safe_remove /etc/systemd/system/hysteria2.service
  safe_remove /usr/local/bin/hysteria
  safe_remove /usr/local/bin/hysteria2
  safe_remove /etc/hysteria
else
  log "Skipping Hysteria2 cleanup because it was preexisting, disabled, or not installed by this stack."
fi

safe_remove_repo_dir
if [ "$PURGE_REPO_DIR" -eq 1 ]; then
  safe_remove "${GLOBAL_CLI:-/usr/local/bin/reality-mosdns}"
  safe_remove "$MANIFEST"
  rmdir "$STATE_DIR" >/dev/null 2>&1 || true
else
  update_manifest_after_partial_uninstall
fi

systemctl daemon-reload || true
systemctl reset-failed mosdns xray hysteria2 >/dev/null 2>&1 || true

log "Uninstall complete."
