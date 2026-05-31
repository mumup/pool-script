#!/bin/sh
set -eu

BASE_URL="${BASE_URL:-https://pearlhash.xyz}"
OUT_FILE="${OUT_FILE:-pearl-miner}"
MODE="${1:-link}"
UA="${UA:-Mozilla/5.0 pearl-miner-link-fetcher/1.0}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

usage() {
  cat <<'EOF'
Usage:
  ./get-pearlhash-miner-url.sh          Print the latest Pearl miner download URL
  ./get-pearlhash-miner-url.sh link     Print the latest Pearl miner download URL
  ./get-pearlhash-miner-url.sh check    Print URL after validating it
  ./get-pearlhash-miner-url.sh download Download to ./pearl-miner or $OUT_FILE

Environment:
  BASE_URL  Default: https://pearlhash.xyz
  OUT_FILE  Default: pearl-miner
  UA        Custom User-Agent
EOF
}

fetch() {
  curl -fsSL \
    --retry 3 \
    --retry-delay 1 \
    --connect-timeout 10 \
    --max-time 30 \
    -A "$UA" \
    "$1"
}

extract_urls() {
  awk -v base="$BASE_URL" '
    {
      line = $0
      while (match(line, /(https:\/\/pearlhash\.xyz)?\/downloads\/pearl-miner-v[0-9]+/)) {
        url = substr(line, RSTART, RLENGTH)
        if (url ~ /^\//) url = base url
        print url
        line = substr(line, RSTART + RLENGTH)
      }
    }
  '
}

extract_chunks() {
  awk -v base="$BASE_URL" '
    {
      line = $0
      while (match(line, /\/_next\/static\/chunks\/[^"'\''<> ]+\.js/)) {
        path = substr(line, RSTART, RLENGTH)
        print base path
        line = substr(line, RSTART + RLENGTH)
      }
    }
  '
}

latest_url() {
  awk '
    {
      url = $0
      version = url
      sub(/^.*pearl-miner-v/, "", version)
      sub(/[^0-9].*$/, "", version)
      if (version + 0 > best_version) {
        best_version = version + 0
        best_url = url
      }
    }
    END {
      if (best_url != "") print best_url
    }
  '
}

validate_url() {
  url="$1"
  code="$(
    curl -sS -L \
      --retry 2 \
      --connect-timeout 10 \
      --max-time 20 \
      -A "$UA" \
      -H 'Range: bytes=0-0' \
      -o /dev/null \
      -w '%{http_code}' \
      "$url"
  )"

  case "$code" in
    200|206) return 0 ;;
    *) echo "Download URL failed validation: $url returned HTTP $code" >&2; return 1 ;;
  esac
}

find_url_from_homepage() {
  fetch "$BASE_URL/" | extract_urls | sort -u | latest_url
}

find_url_from_chunks() {
  html="$tmpdir/home.html"
  fetch "$BASE_URL/" > "$html"

  extract_chunks < "$html" |
    sort -u |
    while IFS= read -r chunk_url; do
      fetch "$chunk_url" 2>/dev/null | extract_urls || true
    done |
    sort -u |
    latest_url
}

find_url() {
  url="$(find_url_from_homepage || true)"
  if [ -n "$url" ]; then
    printf '%s\n' "$url"
    return 0
  fi

  url="$(find_url_from_chunks || true)"
  if [ -n "$url" ]; then
    printf '%s\n' "$url"
    return 0
  fi

  echo "Could not find a Pearl miner download URL from $BASE_URL" >&2
  return 1
}

case "$MODE" in
  link)
    find_url
    ;;
  check)
    url="$(find_url)"
    validate_url "$url"
    printf '%s\n' "$url"
    ;;
  download)
    url="$(find_url)"
    validate_url "$url"
    curl -fL \
      --retry 3 \
      --connect-timeout 10 \
      --max-time 300 \
      -A "$UA" \
      -o "$OUT_FILE" \
      "$url"
    chmod +x "$OUT_FILE"
    printf 'Downloaded %s -> %s\n' "$url" "$OUT_FILE"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
