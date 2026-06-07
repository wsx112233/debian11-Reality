#!/usr/bin/env bash
set -Eeuo pipefail

XRAY_VERSION="${XRAY_VERSION:-v25.1.1}"
XRAY_DOWNLOAD_URL="${XRAY_DOWNLOAD_URL:-}"
XRAY_ZIP_SHA256="${XRAY_ZIP_SHA256:-}"
XRAY_CONFIG_DIR="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_SERVICE="/etc/systemd/system/xray.service"

PROTOCOL="reality"
PORT="${REALITY_PORT:-443}"
DEST="${REALITY_DEST:-www.microsoft.com:443}"
SERVER_NAME="${REALITY_SERVER_NAME:-www.microsoft.com}"
FLOW="${REALITY_FLOW:-xtls-rprx-vision}"

usage() {
  cat <<'USAGE'
Usage:
  sudo bash scripts/install-xray-reality.sh [options]

Options:
  --protocol reality       Only reality is supported.
  --port PORT              Listening port. Default: 443.
  --dest HOST:PORT         Reality dest. Default: www.microsoft.com:443.
  --server-name NAME       Reality serverName. Default: www.microsoft.com.
  -h, --help               Show this help.

Environment:
  XRAY_VERSION             Xray-core release tag. Default: v25.1.1.
  XRAY_DOWNLOAD_URL        Optional Xray zip mirror URL.
  XRAY_ZIP_SHA256          Optional sha256 for the downloaded zip.
USAGE
}

log() {
  printf '[xray-reality-install] %s\n' "$*" >&2
}

die() {
  printf '[xray-reality-install] ERROR: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --protocol) shift; [ "$#" -gt 0 ] || die "Missing value for --protocol"; PROTOCOL="$1" ;;
    --port) shift; [ "$#" -gt 0 ] || die "Missing value for --port"; PORT="$1" ;;
    --dest) shift; [ "$#" -gt 0 ] || die "Missing value for --dest"; DEST="$1" ;;
    --server-name) shift; [ "$#" -gt 0 ] || die "Missing value for --server-name"; SERVER_NAME="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift || true
done

[ "$(id -u)" -eq 0 ] || die "Run as root."
[ "$PROTOCOL" = "reality" ] || die "Only --protocol reality is supported by this local installer."

case "$PORT" in
  *[!0-9]*|'') die "Invalid port: $PORT" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "Port out of range: $PORT"

case "$DEST" in
  *:*) ;;
  *) die "--dest must be HOST:PORT" ;;
esac

command -v systemctl >/dev/null 2>&1 || die "systemd/systemctl is required."
command -v curl >/dev/null 2>&1 || true
command -v unzip >/dev/null 2>&1 || true

if command -v ss >/dev/null 2>&1; then
  blockers="$(
    { ss -H -ltnp 2>/dev/null || true; ss -H -lunp 2>/dev/null || true; } |
      awk -v port=":$PORT" '$5 ~ port "$" { print }' |
      grep -v 'xray' || true
  )"
  if [ -n "$blockers" ]; then
    printf '%s\n' "$blockers" >&2
    die "Port $PORT appears to be occupied."
  fi
fi

case "$(uname -m)" in
  x86_64|amd64) asset="Xray-linux-64.zip" ;;
  aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
apt-get update
apt-get install -y ca-certificates curl unzip

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

url="${XRAY_DOWNLOAD_URL:-https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${asset}}"
log "Downloading Xray: $url"
curl -fsSL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 180 "$url" -o "$tmp_dir/xray.zip"

if [ -n "$XRAY_ZIP_SHA256" ]; then
  printf '%s  %s\n' "$XRAY_ZIP_SHA256" "$tmp_dir/xray.zip" | sha256sum -c -
fi

unzip -o "$tmp_dir/xray.zip" -d "$tmp_dir/xray"
[ -x "$tmp_dir/xray/xray" ] || die "Downloaded archive does not contain an executable xray binary."

install -m 0755 "$tmp_dir/xray/xray" "$XRAY_BIN"
install -d -m 0755 "$XRAY_CONFIG_DIR"

uuid="$("$XRAY_BIN" uuid)"
x25519="$("$XRAY_BIN" x25519)"
private_key="$(printf '%s\n' "$x25519" | awk -F': ' '/Private key/ { print $2 }')"
public_key="$(printf '%s\n' "$x25519" | awk -F': ' '/Public key/ { print $2 }')"
short_id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"

[ -n "$uuid" ] || die "Failed to generate UUID."
[ -n "$private_key" ] || die "Failed to generate Reality private key."
[ -n "$public_key" ] || die "Failed to generate Reality public key."
[ -n "$short_id" ] || die "Failed to generate Reality shortId."

if [ -f "$XRAY_CONFIG_DIR/config.json" ]; then
  cp -a "$XRAY_CONFIG_DIR/config.json" "$XRAY_CONFIG_DIR/config.json.bak.$(date +%Y%m%d%H%M%S)"
fi

cat >"$XRAY_CONFIG_DIR/config.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "reality-in",
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "flow": "$FLOW"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST",
          "xver": 0,
          "serverNames": [
            "$SERVER_NAME"
          ],
          "privateKey": "$private_key",
          "shortIds": [
            "$short_id"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF
chmod 0600 "$XRAY_CONFIG_DIR/config.json"

cat >"$XRAY_SERVICE" <<SERVICE
[Unit]
Description=Xray Reality service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG_DIR/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now xray
systemctl is-active --quiet xray || die "xray service failed to start."

server_ip="$(curl -fsS --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{ print $1 }')"
server_ip="${server_ip:-YOUR_SERVER_IP}"
client_link="vless://${uuid}@${server_ip}:${PORT}?encryption=none&flow=${FLOW}&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#Reality"

cat >"$XRAY_CONFIG_DIR/client-link.txt" <<EOF
$client_link
EOF
chmod 0600 "$XRAY_CONFIG_DIR/client-link.txt"

log "Xray Reality installed."
log "Client link saved: $XRAY_CONFIG_DIR/client-link.txt"
echo
echo "Nekoray vless://"
echo "$client_link"
