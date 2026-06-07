#!/usr/bin/env bash
set -Eeuo pipefail

STACK_NAME="reality-mosdns-stack"
STATE_DIR="${STATE_DIR:-/var/lib/$STACK_NAME}"
MANIFEST="$STATE_DIR/manifest.env"
LOG_FILE="$STATE_DIR/install.log"
LOCK_DIR="/var/lock/$STACK_NAME.lock"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REALITY_INSTALL_URL="${REALITY_INSTALL_URL:-}"
REALITY_SCRIPT_SHA256="${REALITY_SCRIPT_SHA256:-}"
REALITY_PROTOCOL="${REALITY_PROTOCOL:-reality}"
REALITY_PORT="${REALITY_PORT:-}"
REALITY_DEST="${REALITY_DEST:-}"
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-}"
REALITY_SCRIPT_PATH="${REALITY_SCRIPT_PATH:-}"
DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-standalone}"
HYSTERIA_PORT="${HYSTERIA_PORT:-}"

INSTALL_MOSDNS=1
INSTALL_REALITY=1
INSTALL_HYSTERIA=0
YES=0
ALLOW_EXISTING_MOSDNS=0
ALLOW_EXISTING_XRAY=0
PREFLIGHT_ONLY=0
ROLLBACK_ON_FAILURE=1
INSTALL_STARTED=0

usage() {
  cat <<'USAGE'
Usage:
  sudo bash scripts/install-reality-mosdns.sh [options]

Options:
  --yes                         Run without interactive confirmation.
  --skip-mosdns                 Do not install mosdns.
  --skip-reality                Do not install Reality/Xray.
  --allow-existing-mosdns       Allow installing over an existing /etc/mosdns or mosdns service.
  --allow-existing-xray         Allow running the Reality installer when Xray/Hysteria files already exist.
  --reality-script PATH         Use a local debian11-Reality install.sh instead of downloading it.
  --deployment VALUE            standalone or 3x-ui. Default: standalone.
  --preflight-only              Run checks only, then exit.
  --no-rollback                 Do not auto-run uninstall when this wrapper fails after changes begin.
  --protocol VALUE              reality-vision, hysteria2, or reality-vision+hysteria2.
  --port PORT                   Port passed to debian11-Reality install.sh.
  --hysteria-port PORT          Hysteria2 UDP listening port. Default: 8443.
  --dest HOST:PORT              dest passed to debian11-Reality install.sh.
  --server-name NAME            server-name passed to debian11-Reality install.sh.
  -h, --help                    Show this help.

Environment:
  REALITY_INSTALL_URL           Optional legacy remote install.sh URL. Empty uses local Xray Reality installer.
  REALITY_SCRIPT_SHA256         Optional sha256 for the downloaded install.sh.
  MOSDNS_DOWNLOAD_URL           Optional mosdns release mirror URL.
USAGE
}

log() {
  local line
  line="[$STACK_NAME] $*"
  printf '%s\n' "$line" >&2
  if [ -d "$STATE_DIR" ]; then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

die() {
  printf '[%s] ERROR: %s\n' "$STACK_NAME" "$*" >&2
  exit 1
}

on_exit() {
  local status="$1"
  if [ -n "${tmp_dir:-}" ] && [ -d "$tmp_dir" ]; then
    rm -rf "$tmp_dir"
  fi
  if [ -d "$LOCK_DIR" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  if [ "$status" -ne 0 ] && [ "$INSTALL_STARTED" -eq 1 ] && [ "$ROLLBACK_ON_FAILURE" -eq 1 ] && [ -f "$MANIFEST" ]; then
    log "Install failed; running best-effort rollback."
    bash "$REPO_DIR/scripts/uninstall-reality-mosdns.sh" --yes >>"$LOG_FILE" 2>&1 || true
  fi
}

trap 'on_exit $?' EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    --skip-mosdns) INSTALL_MOSDNS=0 ;;
    --skip-reality) INSTALL_REALITY=0 ;;
    --allow-existing-mosdns) ALLOW_EXISTING_MOSDNS=1 ;;
    --allow-existing-xray) ALLOW_EXISTING_XRAY=1 ;;
    --reality-script) shift; [ "$#" -gt 0 ] || die "Missing value for --reality-script"; REALITY_SCRIPT_PATH="$1" ;;
    --deployment) shift; [ "$#" -gt 0 ] || die "Missing value for --deployment"; DEPLOYMENT_MODE="$1" ;;
    --preflight-only) PREFLIGHT_ONLY=1 ;;
    --no-rollback) ROLLBACK_ON_FAILURE=0 ;;
    --protocol) shift; [ "$#" -gt 0 ] || die "Missing value for --protocol"; REALITY_PROTOCOL="$1" ;;
    --port) shift; [ "$#" -gt 0 ] || die "Missing value for --port"; REALITY_PORT="$1" ;;
    --hysteria-port) shift; [ "$#" -gt 0 ] || die "Missing value for --hysteria-port"; HYSTERIA_PORT="$1" ;;
    --dest) shift; [ "$#" -gt 0 ] || die "Missing value for --dest"; REALITY_DEST="$1" ;;
    --server-name) shift; [ "$#" -gt 0 ] || die "Missing value for --server-name"; REALITY_SERVER_NAME="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift || true
done

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash scripts/install-reality-mosdns.sh"
[ -n "$REALITY_PROTOCOL" ] || die "--protocol cannot be empty."

case "$REALITY_PROTOCOL" in
  reality|reality-vision)
    INSTALL_REALITY=1
    INSTALL_HYSTERIA=0
    ;;
  hysteria2)
    INSTALL_REALITY=0
    INSTALL_HYSTERIA=1
    ;;
  reality+hysteria2|reality-vision+hysteria2)
    INSTALL_REALITY=1
    INSTALL_HYSTERIA=1
    ;;
  *) die "Unsupported protocol: $REALITY_PROTOCOL" ;;
esac

case "$DEPLOYMENT_MODE" in
  standalone|3x-ui) ;;
  *) die "Unsupported deployment mode: $DEPLOYMENT_MODE" ;;
esac

[ "$INSTALL_MOSDNS" -eq 1 ] || [ "$INSTALL_REALITY" -eq 1 ] || [ "$INSTALL_HYSTERIA" -eq 1 ] || die "Nothing to install."

validate_port() {
  local value="$1"
  [ -z "$value" ] && return 0
  case "$value" in
    *[!0-9]*|'') die "Invalid port: $value" ;;
  esac
  [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || die "Port out of range: $value"
}

validate_port "$REALITY_PORT"
validate_port "$HYSTERIA_PORT"

if [ -n "$REALITY_INSTALL_URL" ]; then
  case "$REALITY_INSTALL_URL" in
    https://*|http://*) ;;
    *) [ -n "$REALITY_SCRIPT_PATH" ] || die "REALITY_INSTALL_URL must start with http:// or https://." ;;
  esac
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  die "Another $STACK_NAME operation is running, or stale lock exists: $LOCK_DIR"
fi

if [ -r /etc/os-release ]; then
  . /etc/os-release
  if [ "${ID:-}" != "debian" ] || [ "${VERSION_ID:-}" != "11" ]; then
    [ "${ALLOW_NON_DEBIAN11:-0}" = "1" ] || die "This script is designed for Debian 11. Set ALLOW_NON_DEBIAN11=1 to override."
  fi
fi

command -v systemctl >/dev/null 2>&1 || die "systemd/systemctl is required."
command -v awk >/dev/null 2>&1 || die "awk is required."
command -v grep >/dev/null 2>&1 || die "grep is required."
command -v sed >/dev/null 2>&1 || die "sed is required."
command -v mktemp >/dev/null 2>&1 || die "mktemp is required."
command -v install >/dev/null 2>&1 || die "install is required."
command -v sha256sum >/dev/null 2>&1 || [ -z "$REALITY_SCRIPT_SHA256" ] || die "sha256sum is required when REALITY_SCRIPT_SHA256 is set."

if [ -f "$MANIFEST" ]; then
  die "Existing install manifest found: $MANIFEST. Run uninstall first, or inspect the previous install state."
fi

if [ "$INSTALL_MOSDNS" -eq 1 ] && [ ! -f "$REPO_DIR/scripts/install-debian11.sh" ]; then
  die "Missing local mosdns installer: $REPO_DIR/scripts/install-debian11.sh"
fi

if [ "$INSTALL_REALITY" -eq 1 ] && [ -n "$REALITY_SCRIPT_PATH" ] && [ ! -f "$REALITY_SCRIPT_PATH" ]; then
  die "Reality script not found: $REALITY_SCRIPT_PATH"
fi

if [ "$INSTALL_REALITY" -eq 1 ] && [ -z "$REALITY_SCRIPT_PATH" ] && [ -z "$REALITY_INSTALL_URL" ] && [ ! -f "$REPO_DIR/scripts/install-xray-reality.sh" ]; then
  die "Missing local Reality installer: $REPO_DIR/scripts/install-xray-reality.sh"
fi

if [ "$INSTALL_HYSTERIA" -eq 1 ] && [ ! -f "$REPO_DIR/scripts/install-hysteria2.sh" ]; then
  die "Missing local Hysteria2 installer: $REPO_DIR/scripts/install-hysteria2.sh"
fi

free_kb="$(awk '/MemAvailable/ { print $2 }' /proc/meminfo 2>/dev/null || printf '0')"
if [ "${free_kb:-0}" -gt 0 ] && [ "$free_kb" -lt 131072 ]; then
  die "Available memory is below 128MB; installation is likely to fail."
fi

free_blocks="$(df -Pk / 2>/dev/null | awk 'NR == 2 { print $4 }')"
if [ "${free_blocks:-0}" -gt 0 ] && [ "$free_blocks" -lt 102400 ]; then
  die "Root filesystem has less than 100MB free."
fi

path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

service_exists() {
  systemctl list-unit-files "$1" --no-legend 2>/dev/null | awk 'NF { found=1 } END { exit found ? 0 : 1 }'
}

has_mosdns_before=0
if path_exists /etc/mosdns || path_exists /usr/local/bin/mosdns || service_exists mosdns.service; then
  has_mosdns_before=1
fi

has_xray_before=0
for p in \
  /usr/local/bin/xray \
  /usr/local/etc/xray \
  /etc/xray \
  /etc/systemd/system/xray.service \
  /lib/systemd/system/xray.service \
  /etc/systemd/system/hysteria2.service \
  /etc/hysteria \
  /usr/local/bin/hysteria \
  /usr/local/bin/hysteria2
do
  if path_exists "$p"; then
    has_xray_before=1
    break
  fi
done

if [ "$INSTALL_MOSDNS" -eq 1 ] && [ "$has_mosdns_before" -eq 1 ] && [ "$ALLOW_EXISTING_MOSDNS" -ne 1 ]; then
  die "Existing mosdns files/service detected. Re-run with --allow-existing-mosdns only if you accept takeover."
fi

if [ "$INSTALL_REALITY" -eq 1 ] && [ "$has_xray_before" -eq 1 ] && [ "$ALLOW_EXISTING_XRAY" -ne 1 ]; then
  die "Existing Xray/Hysteria files/service detected. Re-run with --allow-existing-xray only if you accept takeover."
fi

if [ "$INSTALL_MOSDNS" -eq 1 ] && command -v ss >/dev/null 2>&1; then
  port53_blockers="$(
    { ss -H -ltnup 2>/dev/null || true; ss -H -lnuap 2>/dev/null || true; } |
      awk '$5 ~ /(^|:)(127\.0\.0\.1|\[::1\]|0\.0\.0\.0|\[::\]|\*):53$/ { print }' |
      grep -v 'mosdns' || true
  )"
  if [ -n "$port53_blockers" ]; then
    printf '%s\n' "$port53_blockers" >&2
    die "Port 53 appears to be occupied. Stop the conflicting local DNS service or install mosdns manually on another listen address."
  fi
fi

if [ "$PREFLIGHT_ONLY" -eq 1 ]; then
  log "Preflight passed. No changes made."
  exit 0
fi

if [ "$YES" -ne 1 ]; then
  cat <<EOF
This will install:
  deployment: $DEPLOYMENT_MODE
  mosdns:     $INSTALL_MOSDNS
  Reality:    $INSTALL_REALITY
  Hysteria2:  $INSTALL_HYSTERIA
  protocol:   $REALITY_PROTOCOL

Safety defaults:
  - mosdns listens on 127.0.0.1:53 only.
  - /etc/resolv.conf is not modified.
  - Existing mosdns/Xray/Hysteria installs are refused unless explicitly allowed.
  - Failure after changes begin triggers best-effort rollback.
  - Installed state is recorded in $MANIFEST for uninstall.
EOF
  printf 'Continue? [y/N] '
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) die "Cancelled." ;;
  esac
fi

install -d -m 0755 "$STATE_DIR"
chmod 0755 "$STATE_DIR"
: >"$LOG_FILE"
chmod 0644 "$LOG_FILE"

tmp_dir="$(mktemp -d)"

quote() {
  printf '%q' "$1"
}

write_manifest() {
  {
    printf 'STACK_NAME=%s\n' "$(quote "$STACK_NAME")"
    printf 'INSTALLED_AT=%s\n' "$(quote "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    printf 'REPO_DIR=%s\n' "$(quote "$REPO_DIR")"
    printf 'LOG_FILE=%s\n' "$(quote "$LOG_FILE")"
    printf 'INSTALL_MOSDNS=%s\n' "$(quote "$INSTALL_MOSDNS")"
    printf 'INSTALL_REALITY=%s\n' "$(quote "$INSTALL_REALITY")"
    printf 'INSTALL_HYSTERIA=%s\n' "$(quote "$INSTALL_HYSTERIA")"
    printf 'DEPLOYMENT_MODE=%s\n' "$(quote "$DEPLOYMENT_MODE")"
    printf 'MOSDNS_PREEXISTING=%s\n' "$(quote "$has_mosdns_before")"
    printf 'XRAY_PREEXISTING=%s\n' "$(quote "$has_xray_before")"
    printf 'REALITY_INSTALL_URL=%s\n' "$(quote "$REALITY_INSTALL_URL")"
    printf 'REALITY_SCRIPT_SHA256=%s\n' "$(quote "$REALITY_SCRIPT_SHA256")"
    printf 'REALITY_PROTOCOL=%s\n' "$(quote "$REALITY_PROTOCOL")"
    printf 'HYSTERIA_PORT=%s\n' "$(quote "$HYSTERIA_PORT")"
  } >"$MANIFEST"
  chmod 0644 "$MANIFEST"
}

download_reality_script() {
  command -v curl >/dev/null 2>&1 || die "curl is required. Install mosdns first or run: apt-get install -y curl"

  if [ -n "$REALITY_SCRIPT_PATH" ]; then
    [ -f "$REALITY_SCRIPT_PATH" ] || die "Reality script not found: $REALITY_SCRIPT_PATH"
    printf '%s\n' "$REALITY_SCRIPT_PATH"
    return
  fi

  local out="$tmp_dir/debian11-Reality-install.sh"
  log "Downloading Reality installer: $REALITY_INSTALL_URL"
  curl -fsSL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 120 "$REALITY_INSTALL_URL" -o "$out"

  if [ -n "$REALITY_SCRIPT_SHA256" ]; then
    printf '%s  %s\n' "$REALITY_SCRIPT_SHA256" "$out" | sha256sum -c -
  else
    log "REALITY_SCRIPT_SHA256 is not set; downloaded script is not pinned."
  fi

  chmod 0755 "$out"
  printf '%s\n' "$out"
}

write_manifest
INSTALL_STARTED=1

if [ "$INSTALL_MOSDNS" -eq 1 ]; then
  log "Installing mosdns from local project."
  bash "$REPO_DIR/scripts/install-debian11.sh"
fi

if [ "$INSTALL_REALITY" -eq 1 ]; then
  args=(--protocol reality)
  [ -z "$REALITY_PORT" ] || args+=(--port "$REALITY_PORT")
  [ -z "$REALITY_DEST" ] || args+=(--dest "$REALITY_DEST")
  [ -z "$REALITY_SERVER_NAME" ] || args+=(--server-name "$REALITY_SERVER_NAME")

  if [ -n "$REALITY_SCRIPT_PATH" ] || [ -n "$REALITY_INSTALL_URL" ]; then
    reality_script="$(download_reality_script)"
  else
    reality_script="$REPO_DIR/scripts/install-xray-reality.sh"
  fi

  log "Running Reality installer: $reality_script"
  bash "$reality_script" "${args[@]}"
fi

if [ "$INSTALL_HYSTERIA" -eq 1 ]; then
  hargs=()
  [ -z "$HYSTERIA_PORT" ] || hargs+=(--port "$HYSTERIA_PORT")
  log "Running Hysteria2 installer."
  bash "$REPO_DIR/scripts/install-hysteria2.sh" "${hargs[@]}"
fi

systemctl daemon-reload || true

if [ "$INSTALL_MOSDNS" -eq 1 ]; then
  systemctl is-active --quiet mosdns || die "mosdns service is not active after install."
  if command -v dig >/dev/null 2>&1; then
    dig @127.0.0.1 google.com +tries=1 +time=3 +short >/dev/null || die "mosdns did not answer a test query on 127.0.0.1:53."
  fi
fi

if [ "$INSTALL_REALITY" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files xray.service --no-legend 2>/dev/null | awk 'NF { found=1 } END { exit found ? 0 : 1 }'; then
    systemctl is-active --quiet xray || die "xray service exists but is not active after install."
  fi
fi

if [ "$INSTALL_HYSTERIA" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
  systemctl is-active --quiet hysteria2 || die "hysteria2 service is not active after install."
fi

ROLLBACK_ON_FAILURE=0

log "Install complete."
log "Validate DNS: dig @127.0.0.1 google.com"
log "Uninstall: sudo bash $REPO_DIR/scripts/uninstall-reality-mosdns.sh"
