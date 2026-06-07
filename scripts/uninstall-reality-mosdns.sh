#!/usr/bin/env bash
set -Eeuo pipefail

STACK_NAME="reality-mosdns-stack"
STATE_DIR="${STATE_DIR:-/var/lib/$STACK_NAME}"
MANIFEST="$STATE_DIR/manifest.env"
LOCK_DIR="/var/lock/$STACK_NAME.lock"
YES=0
PURGE_MOSDNS_CONFIG=1
PURGE_REALITY=1

usage() {
  cat <<'USAGE'
Usage:
  sudo bash scripts/uninstall-reality-mosdns.sh [options]

Options:
  --yes                 Run without interactive confirmation.
  --keep-mosdns-config  Keep /etc/mosdns.
  --keep-reality        Do not remove Xray/Hysteria files.
  -h, --help            Show this help.

This script removes files created by scripts/install-reality-mosdns.sh.
If mosdns or Xray existed before install, the matching cleanup is skipped.
USAGE
}

log() {
  printf '[%s] %s\n' "$STACK_NAME" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$STACK_NAME" "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    --keep-mosdns-config) PURGE_MOSDNS_CONFIG=0 ;;
    --keep-reality) PURGE_REALITY=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift || true
done

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash scripts/uninstall-reality-mosdns.sh"
[ -f "$MANIFEST" ] || die "Manifest not found: $MANIFEST"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  die "Another $STACK_NAME operation is running, or stale lock exists: $LOCK_DIR"
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# shellcheck disable=SC1090
. "$MANIFEST"

safe_remove() {
  local p="$1"
  case "$p" in
    /etc/mosdns|/etc/mosdns/*|/usr/local/bin/mosdns|/usr/local/bin/mosdns-*|/etc/systemd/system/mosdns.service|/etc/logrotate.d/mosdns|/var/log/mosdns.log|/usr/local/bin/xray|/usr/local/etc/xray|/usr/local/etc/xray/*|/etc/xray|/etc/xray/*|/etc/systemd/system/xray.service|/lib/systemd/system/xray.service|/usr/local/bin/hysteria|/usr/local/bin/hysteria2|/etc/systemd/system/hysteria2.service|/var/lib/reality-mosdns-stack/manifest.env)
      if [ -e "$p" ] || [ -L "$p" ]; then
        rm -rf "$p"
      fi
      ;;
    *)
      die "Refusing to remove unexpected path: $p"
      ;;
  esac
}

if [ "$YES" -ne 1 ]; then
  cat <<EOF
This will uninstall $STACK_NAME.

Recorded install:
  mosdns installed:  ${INSTALL_MOSDNS:-0}
  reality installed: ${INSTALL_REALITY:-0}
  mosdns preexisting: ${MOSDNS_PREEXISTING:-unknown}
  xray preexisting:   ${XRAY_PREEXISTING:-unknown}

Cleanup policy:
  - Preexisting services are not removed.
  - apt packages are not removed because they may be shared by production workloads.
  - firewall/sysctl changes from the upstream Reality script cannot be safely inferred; review them manually if you enabled them there.
EOF
  printf 'Continue? [y/N] '
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) die "Cancelled." ;;
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

systemctl daemon-reload || true
systemctl reset-failed mosdns xray hysteria2 >/dev/null 2>&1 || true

safe_remove "$MANIFEST"
rmdir "$STATE_DIR" >/dev/null 2>&1 || true

log "Uninstall complete."
