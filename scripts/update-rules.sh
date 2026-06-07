#!/usr/bin/env bash
set -euo pipefail

MOSDNS_DIR="${MOSDNS_DIR:-/etc/mosdns}"
RULE_DIR="$MOSDNS_DIR/rules"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$RULE_DIR"

download() {
  local url="$1"
  local out="$2"
  curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$out"
}

normalize_rules() {
  sed -E \
    -e 's/\r$//' \
    -e '/^[[:space:]]*$/d' \
    -e '/^[[:space:]]*#/d' \
    -e '/^[[:space:]]*regexp:/!s/[[:space:]]+#.*$//' \
    "$1" | awk '!seen[$0]++'
}

download \
  "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/reject-list.txt" \
  "$TMP_DIR/ads.txt"
normalize_rules "$TMP_DIR/ads.txt" > "$TMP_DIR/ads.generated.txt"

download \
  "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt" \
  "$TMP_DIR/domestic.txt"
normalize_rules "$TMP_DIR/domestic.txt" > "$TMP_DIR/domestic.generated.txt"

install -m 0644 "$TMP_DIR/ads.generated.txt" "$RULE_DIR/ads.generated.txt"
install -m 0644 "$TMP_DIR/domestic.generated.txt" "$RULE_DIR/domestic.generated.txt"

for f in ads.custom.txt domestic.custom.txt whitelist.txt; do
  [ -f "$RULE_DIR/$f" ] || : > "$RULE_DIR/$f"
done

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet mosdns; then
  systemctl restart mosdns
fi

echo "Rules updated:"
wc -l "$RULE_DIR/ads.generated.txt" "$RULE_DIR/domestic.generated.txt"
