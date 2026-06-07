#!/usr/bin/env bash
set -euo pipefail

SERVER="${1:-127.0.0.1}"
PORT="${2:-53}"
JOBS="${JOBS:-32}"
ROUNDS="${ROUNDS:-3}"

if ! command -v dig >/dev/null 2>&1; then
  echo "dig is required. Install with: apt-get install -y dnsutils" >&2
  exit 1
fi

domains=(
  baidu.com qq.com taobao.com jd.com bilibili.com aliyun.com
  cloudflare.com google.com github.com youtube.com wikipedia.org openai.com
)

tmp_file="$(mktemp)"
sorted_file="$(mktemp)"
trap 'rm -f "$tmp_file" "$sorted_file"' EXIT

bench_one() {
  local server="$1" port="$2" domain="$3" qtype="$4"
  local start end elapsed status
  start="$(date +%s%3N)"
  if dig @"$server" -p "$port" "$domain" "$qtype" +tries=1 +time=2 +short >/dev/null; then
    status=ok
  else
    status=fail
  fi
  end="$(date +%s%3N)"
  elapsed=$((end - start))
  printf '%s %s %s %s\n' "$elapsed" "$status" "$domain" "$qtype"
}

export -f bench_one

for _ in $(seq 1 "$ROUNDS"); do
  for domain in "${domains[@]}"; do
    printf '%s A\n%s AAAA\n' "$domain" "$domain"
  done
done | xargs -n2 -P "$JOBS" bash -c 'bench_one "$0" "$1" "$2" "$3"' "$SERVER" "$PORT" >> "$tmp_file"

awk '$2 == "ok" { print $1 }' "$tmp_file" | sort -n > "$sorted_file"

ok_count="$(wc -l < "$sorted_file" | tr -d ' ')"
fail_count="$(awk '$2 != "ok" { fail++ } END { print fail + 0 }' "$tmp_file")"

if [ "$ok_count" -eq 0 ]; then
  echo "server=$SERVER port=$PORT ok=0 fail=$fail_count"
  exit 1
fi

p50_idx=$(( (ok_count * 50 + 99) / 100 ))
p90_idx=$(( (ok_count * 90 + 99) / 100 ))
p50="$(sed -n "${p50_idx}p" "$sorted_file")"
p90="$(sed -n "${p90_idx}p" "$sorted_file")"

awk -v ok="$ok_count" -v fail="$fail_count" -v p50="$p50" -v p90="$p90" '
  {
    sum += $1
    if (NR == 1 || $1 < min) min = $1
    if ($1 > max) max = $1
  }
  END {
    printf "queries=%d ok=%d fail=%d avg=%.1fms p50=%dms p90=%dms min=%dms max=%dms\n", ok + fail, ok, fail, sum / ok, p50, p90, min, max
  }
' "$sorted_file"
