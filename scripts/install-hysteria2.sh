#!/usr/bin/env bash
set -Eeuo pipefail

HYSTERIA_VERSION="${HYSTERIA_VERSION:-app/v2.6.3}"
HYSTERIA_DOWNLOAD_URL="${HYSTERIA_DOWNLOAD_URL:-}"
HYSTERIA_BIN="${HYSTERIA_BIN:-/usr/local/bin/hysteria2}"
HYSTERIA_DIR="${HYSTERIA_DIR:-/etc/hysteria}"
HYSTERIA_SERVICE="/etc/systemd/system/hysteria2.service"
PORT="${HYSTERIA_PORT:-}"

usage() {
  cat <<'USAGE'
Usage:
  sudo bash scripts/install-hysteria2.sh [options]

选项:
  --port PORT       UDP 监听端口。未指定时自动选择未占用高位端口。
  -h, --help        显示帮助。

Environment:
  HYSTERIA_VERSION       GitHub release tag. Default: app/v2.6.3.
  HYSTERIA_DOWNLOAD_URL  Optional binary mirror URL.
USAGE
}

log() {
  printf '[hysteria2-install] %s\n' "$*" >&2
}

die() {
  printf '[hysteria2-install] ERROR: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --port) shift; [ "$#" -gt 0 ] || die "Missing value for --port"; PORT="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift || true
done

[ "$(id -u)" -eq 0 ] || die "Run as root."

udp_port_is_free() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ! (ss -H -lunp 2>/dev/null | awk -v port=":$p" '$5 ~ port "$" { found=1 } END { exit found ? 0 : 1 }')
  else
    return 0
  fi
}

pick_high_udp_port() {
  local p
  for _ in $(seq 1 80); do
    p="$(od -An -N2 -tu2 /dev/urandom | awk '{ print 20000 + ($1 % 40000) }')"
    if udp_port_is_free "$p"; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

if [ -z "$PORT" ] || [ "$PORT" = "auto" ]; then
  PORT="$(pick_high_udp_port)" || die "Failed to choose a free high UDP port."
  log "Auto selected Hysteria2 UDP port: $PORT"
fi

case "$PORT" in
  *[!0-9]*|'') die "Invalid port: $PORT" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "Port out of range: $PORT"

command -v systemctl >/dev/null 2>&1 || die "systemd/systemctl is required."

case "$(uname -m)" in
  x86_64|amd64) asset="hysteria-linux-amd64" ;;
  aarch64|arm64) asset="hysteria-linux-arm64" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
apt-get update
apt-get install -y ca-certificates curl openssl

if command -v ss >/dev/null 2>&1; then
  blockers="$(ss -H -lunp 2>/dev/null | awk -v port=":$PORT" '$5 ~ port "$" { print }' | grep -v 'hysteria' || true)"
  if [ -n "$blockers" ]; then
    printf '%s\n' "$blockers" >&2
    die "UDP port $PORT appears to be occupied."
  fi
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

url="${HYSTERIA_DOWNLOAD_URL:-https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION}/${asset}}"
log "Downloading Hysteria2: $url"
curl -fsSL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 180 "$url" -o "$tmp_dir/hysteria2"
install -m 0755 "$tmp_dir/hysteria2" "$HYSTERIA_BIN"

install -d -m 0755 "$HYSTERIA_DIR"
password="$(openssl rand -hex 24)"

openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$HYSTERIA_DIR/server.key" \
  -out "$HYSTERIA_DIR/server.crt" \
  -days 3650 \
  -subj "/CN=bing.com" >/dev/null 2>&1
chmod 0600 "$HYSTERIA_DIR/server.key"

if [ -f "$HYSTERIA_DIR/config.yaml" ]; then
  cp -a "$HYSTERIA_DIR/config.yaml" "$HYSTERIA_DIR/config.yaml.bak.$(date +%Y%m%d%H%M%S)"
fi

cat >"$HYSTERIA_DIR/config.yaml" <<EOF
listen: :$PORT

tls:
  cert: $HYSTERIA_DIR/server.crt
  key: $HYSTERIA_DIR/server.key

auth:
  type: password
  password: $password

masquerade:
  type: proxy
  proxy:
    url: https://www.microsoft.com
    rewriteHost: true
EOF
chmod 0600 "$HYSTERIA_DIR/config.yaml"

cat >"$HYSTERIA_SERVICE" <<EOF
[Unit]
Description=Hysteria2 service
Documentation=https://v2.hysteria.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$HYSTERIA_BIN server -c $HYSTERIA_DIR/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hysteria2
systemctl is-active --quiet hysteria2 || die "hysteria2 service failed to start."
if command -v ss >/dev/null 2>&1; then
  listen_lines="$(ss -H -lunp 2>/dev/null | awk -v port=":$PORT" '$5 ~ port "$" { print }' || true)"
  if [ -n "$listen_lines" ]; then
    printf '%s\n' "$listen_lines" >&2
  else
    log "hysteria2 服务已启动，但 ss 未显示 UDP $PORT 监听；继续输出客户端链接，请用 systemctl/journalctl 复核。"
  fi
fi

server_ip="$(curl -fsS --connect-timeout 5 --max-time 10 https://api6.ipify.org 2>/dev/null || curl -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{ print $1 }')"
server_ip="${server_ip:-YOUR_SERVER_IP}"
link_host="$server_ip"
case "$server_ip" in
  *:*) link_host="[$server_ip]" ;;
esac
hy2_link="hy2://${password}@${link_host}:${PORT}?sni=bing.com&insecure=1#Hysteria2"

cat >"$HYSTERIA_DIR/client.txt" <<EOF
server: $server_ip:$PORT
auth: $password
tls:
  sni: bing.com
  insecure: true
EOF
chmod 0600 "$HYSTERIA_DIR/client.txt"

cat >"$HYSTERIA_DIR/client-link.txt" <<EOF
$hy2_link
EOF
chmod 0600 "$HYSTERIA_DIR/client-link.txt"

log "Hysteria2 installed."
log "Client config saved: $HYSTERIA_DIR/client.txt"
log "Client link saved: $HYSTERIA_DIR/client-link.txt"
log "请确认服务器防火墙和云厂商安全组已放行 UDP $PORT。"
echo
echo "Nekoray hy2://"
echo "$hy2_link"
