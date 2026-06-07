#!/usr/bin/env bash
set -euo pipefail

MOSDNS_VERSION="${MOSDNS_VERSION:-v5.3.4}"
INSTALL_DIR="${INSTALL_DIR:-/etc/mosdns}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
export DEBIAN_FRONTEND

log() {
  printf '[mosdns-install] %s\n' "$*" >&2
}

die() {
  printf '[mosdns-install] ERROR: %s\n' "$*" >&2
  exit 1
}

if [ "$(id -u)" -ne 0 ]; then
  die "Run as root: sudo bash scripts/install-debian11.sh"
fi

command -v systemctl >/dev/null 2>&1 || die "systemd/systemctl is required."
command -v apt-get >/dev/null 2>&1 || die "apt-get is required."
command -v curl >/dev/null 2>&1 || true

case "$(uname -m)" in
  x86_64|amd64) asset_arch="amd64" ;;
  aarch64|arm64) asset_arch="arm64" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

if command -v ss >/dev/null 2>&1; then
  port53_blockers="$(
    { ss -H -ltnup 2>/dev/null || true; ss -H -lnuap 2>/dev/null || true; } |
      awk '$5 ~ /(^|:)(127\.0\.0\.1|\[::1\]|0\.0\.0\.0|\[::\]|\*):53$/ { print }' |
      grep -v 'mosdns' || true
  )"
  if [ -n "$port53_blockers" ]; then
    printf '%s\n' "$port53_blockers" >&2
    die "Port 53 appears to be occupied. Stop the conflicting local DNS service or change mosdns listen address before starting."
  fi
fi

log "Installing required packages."
apt-get update
apt-get install -y ca-certificates curl unzip dnsutils

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

url="${MOSDNS_DOWNLOAD_URL:-https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VERSION}/mosdns-linux-${asset_arch}.zip}"
log "Downloading mosdns: $url"
curl -fsSL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 180 "$url" -o "$tmp_dir/mosdns.zip"
unzip -o "$tmp_dir/mosdns.zip" -d "$tmp_dir/mosdns"
[ -x "$tmp_dir/mosdns/mosdns" ] || die "Downloaded archive does not contain an executable mosdns binary."
install -m 0755 "$tmp_dir/mosdns/mosdns" /usr/local/bin/mosdns

install -d -m 0755 "$INSTALL_DIR/rules"
if [ -f "$INSTALL_DIR/config.yaml" ]; then
  cp -a "$INSTALL_DIR/config.yaml" "$INSTALL_DIR/config.yaml.bak.$(date +%Y%m%d%H%M%S)"
fi

install -m 0644 "$REPO_DIR/mosdns/config.yaml" "$INSTALL_DIR/config.yaml"
install -m 0644 "$REPO_DIR/mosdns/hosts.txt" "$INSTALL_DIR/hosts.txt"
install -m 0644 "$REPO_DIR/mosdns/rules/ads.common.txt" "$INSTALL_DIR/rules/ads.common.txt"
install -m 0644 "$REPO_DIR/mosdns/rules/ads.generated.txt" "$INSTALL_DIR/rules/ads.generated.txt"
install -m 0644 "$REPO_DIR/mosdns/rules/domestic.generated.txt" "$INSTALL_DIR/rules/domestic.generated.txt"

for f in ads.custom.txt domestic.custom.txt whitelist.txt; do
  if [ ! -f "$INSTALL_DIR/rules/$f" ]; then
    install -m 0644 "$REPO_DIR/mosdns/rules/$f" "$INSTALL_DIR/rules/$f"
  fi
done

install -m 0755 "$REPO_DIR/scripts/update-rules.sh" /usr/local/bin/mosdns-update-rules
install -m 0755 "$REPO_DIR/scripts/benchmark-dns.sh" /usr/local/bin/mosdns-benchmark
mosdns-update-rules || true

if [ -f /etc/systemd/system/mosdns.service ]; then
  cp -a /etc/systemd/system/mosdns.service "/etc/systemd/system/mosdns.service.bak.$(date +%Y%m%d%H%M%S)"
fi

cat >/etc/systemd/system/mosdns.service <<'SERVICE'
[Unit]
Description=mosdns DNS forwarder
Documentation=https://github.com/IrineSistiana/mosdns
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mosdns start -c /etc/mosdns/config.yaml -d /etc/mosdns
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/etc/mosdns /var/log

[Install]
WantedBy=multi-user.target
SERVICE

cat >/etc/logrotate.d/mosdns <<'LOGROTATE'
/var/log/mosdns.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
LOGROTATE

systemctl daemon-reload
systemctl enable --now mosdns
systemctl is-active --quiet mosdns || die "mosdns service failed to start."

echo "mosdns installed. Test with: dig @127.0.0.1 google.com"
