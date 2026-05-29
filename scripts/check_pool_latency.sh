#!/usr/bin/env bash
set -uo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/alphapool_network.sh
source "$SCRIPT_DIR/lib/alphapool_network.sh"

ATTEMPTS=5
TIMEOUT_SECONDS=3
PORT_FILTER="all"
REGION_FILTER=""
OUTPUT_MODE="human"
BEST_ONLY=0
WATCH_INTERVAL=""
NO_COLOR=0
LIST_ONLY=0
RESULT_ROWS=()

usage() {
  cat <<'EOF'
AlphaPool mining pool latency and stability checker

Usage:
  ./check_pool_latency.sh [options]

Options:
  -a, --attempts N       Probe attempts per endpoint. Default: 5.
  -t, --timeout SEC      TCP connect timeout per attempt. Default: 3.
  -p, --port PORT        Test only one configured port, for example 5566. Default: all.
  -r, --region TEXT      Filter by region or hostname text, for example Asia or sg1.
  -w, --watch SECONDS    Refresh human report every N seconds.
      --json             Output machine-readable JSON.
      --env              Output shell variables for the best endpoint.
      --best-only        Output only the best endpoint/recommendation.
      --list             List configured endpoints and exit.
      --no-color         Disable colored status labels.
  -h, --help             Show this help.

Reuse examples:
  eval "$(./check_pool_latency.sh --env)"
  ./check_pool_latency.sh --json --attempts 8

The probe uses TCP connect timing to the real mining ports, which is more
useful for miner deployment than ICMP ping.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--attempts)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      ATTEMPTS="$2"
      shift 2
      ;;
    -t|--timeout)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    -p|--port)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      PORT_FILTER="$2"
      shift 2
      ;;
    -r|--region)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      REGION_FILTER="$2"
      shift 2
      ;;
    -w|--watch)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      WATCH_INTERVAL="$2"
      shift 2
      ;;
    --json)
      OUTPUT_MODE="json"
      shift
      ;;
    --env)
      OUTPUT_MODE="env"
      BEST_ONLY=1
      shift
      ;;
    --best-only)
      BEST_ONLY=1
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --no-color)
      NO_COLOR=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! [[ "$ATTEMPTS" =~ ^[0-9]+$ ]] || [[ "$ATTEMPTS" -lt 1 ]]; then
  echo "--attempts must be a positive integer." >&2
  exit 2
fi

if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || awk -v v="$TIMEOUT_SECONDS" 'BEGIN { exit !(v + 0 <= 0) }'; then
  echo "--timeout must be a positive number of seconds." >&2
  exit 2
fi

if [[ "$PORT_FILTER" != "all" ]] && ! [[ "$PORT_FILTER" =~ ^[0-9]+$ ]]; then
  echo "--port must be all or a numeric port." >&2
  exit 2
fi

if [[ -n "$WATCH_INTERVAL" ]]; then
  if ! [[ "$WATCH_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$WATCH_INTERVAL" -lt 1 ]]; then
    echo "--watch must be a positive integer number of seconds." >&2
    exit 2
  fi

  if [[ "$OUTPUT_MODE" != "human" ]]; then
    echo "--watch can only be used with human output." >&2
    exit 2
  fi
fi

if [[ -t 1 && "$NO_COLOR" -eq 0 ]]; then
  C_RESET=$'\033[0m'
  C_OK=$'\033[32m'
  C_WARN=$'\033[33m'
  C_BAD=$'\033[31m'
  C_INFO=$'\033[36m'
  C_DIM=$'\033[2m'
else
  C_RESET=""
  C_OK=""
  C_WARN=""
  C_BAD=""
  C_INFO=""
  C_DIM=""
fi

lower() {
  tr '[:upper:]' '[:lower:]'
}

matches_filter() {
  local region="$1"
  local host="$2"
  local port="$3"
  local region_l host_l filter_l

  if [[ "$PORT_FILTER" != "all" && "$port" != "$PORT_FILTER" ]]; then
    return 1
  fi

  if [[ -n "$REGION_FILTER" ]]; then
    region_l="$(printf '%s' "$region" | lower)"
    host_l="$(printf '%s' "$host" | lower)"
    filter_l="$(printf '%s' "$REGION_FILTER" | lower)"

    if [[ "$region_l" != *"$filter_l"* && "$host_l" != *"$filter_l"* ]]; then
      return 1
    fi
  fi

  return 0
}

status_text() {
  local value="$1"
  case "$value" in
    OK) printf '%s%s%s' "$C_OK" "$value" "$C_RESET" ;;
    WARN|SLOW|UNSTABLE) printf '%s%s%s' "$C_WARN" "$value" "$C_RESET" ;;
    DOWN) printf '%s%s%s' "$C_BAD" "$value" "$C_RESET" ;;
    *) printf '%s%s%s' "$C_INFO" "$value" "$C_RESET" ;;
  esac
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

json_number_or_null() {
  local value="$1"
  if [[ "$value" == "N/A" || -z "$value" ]]; then
    printf 'null'
  else
    printf '%s' "$value"
  fi
}

print_list() {
  local region host port
  printf '%-18s %-24s %s\n' "Region" "Host" "Port"
  printf '%-18s %-24s %s\n' "------" "----" "----"
  while IFS=$'\t' read -r region host port; do
    matches_filter "$region" "$host" "$port" || continue
    printf '%-18s %-24s %s\n' "$region" "$host" "$port"
  done < <(alphapool_list_pool_ports)
}

collect_results() {
  local region host port line

  RESULT_ROWS=()
  while IFS=$'\t' read -r region host port; do
    matches_filter "$region" "$host" "$port" || continue
    line="$(alphapool_test_endpoint_tsv "$region" "$host" "$port" "$ATTEMPTS" "$TIMEOUT_SECONDS")"
    RESULT_ROWS+=("$line")
  done < <(alphapool_list_pool_ports)
}

best_result() {
  if [[ "${#RESULT_ROWS[@]}" -eq 0 ]]; then
    return 1
  fi
  printf '%s\n' "${RESULT_ROWS[@]}" | alphapool_best_result_from_tsv
}

print_human() {
  local generated_at region host port attempts success success_rate loss_pct min_ms avg_ms max_ms jitter_ms status score
  local best best_region best_host best_port best_attempts best_success best_success_rate best_loss best_min best_avg best_max best_jitter best_status best_score

  generated_at="$(date '+%Y-%m-%d %H:%M:%S %Z')"

  if [[ "$BEST_ONLY" -eq 0 ]]; then
    printf '%s\n' "============================================================"
    printf '%s\n' "AlphaPool Mining Pool Latency Check  v$VERSION"
    printf '%s\n' "Time: $generated_at"
    printf '%s\n' "Attempts: $ATTEMPTS per endpoint, timeout: ${TIMEOUT_SECONDS}s"
    printf '%s\n' "============================================================"
    printf '%-18s %-24s %-5s %7s %8s %9s %9s %9s %9s %s\n' \
      "Region" "Host" "Port" "Success" "Loss" "Avg(ms)" "Min(ms)" "Max(ms)" "Jitter" "Status"
    printf '%s\n' "------------------------------------------------------------------------------------------------------------------------"

    for line in "${RESULT_ROWS[@]}"; do
      IFS=$'\t' read -r region host port attempts success success_rate loss_pct min_ms avg_ms max_ms jitter_ms status score <<< "$line"
      printf '%-18s %-24s %-5s %3s/%-3s %7s%% %9s %9s %9s %9s %s\n' \
        "$region" "$host" "$port" "$success" "$attempts" "$loss_pct" "$avg_ms" "$min_ms" "$max_ms" "$jitter_ms" "$(status_text "$status")"
    done
  fi

  best="$(best_result || true)"
  if [[ -z "$best" ]]; then
    printf '\n%s No reachable AlphaPool endpoint was found.\n' "$(status_text DOWN)"
    return 1
  fi

  IFS=$'\t' read -r best_region best_host best_port best_attempts best_success best_success_rate best_loss best_min best_avg best_max best_jitter best_status best_score <<< "$best"

  if [[ "$BEST_ONLY" -eq 0 ]]; then
    printf '\n'
  fi
  printf '%s Best endpoint: %s %s:%s  avg=%sms jitter=%sms success=%s%% status=%s\n' \
    "$(status_text OK)" "$best_region" "$best_host" "$best_port" "$best_avg" "$best_jitter" "$best_success_rate" "$(status_text "$best_status")"
}

print_json_object() {
  local line="$1"
  local region host port attempts success success_rate loss_pct min_ms avg_ms max_ms jitter_ms status score

  IFS=$'\t' read -r region host port attempts success success_rate loss_pct min_ms avg_ms max_ms jitter_ms status score <<< "$line"
  printf '{"region":"%s","host":"%s","port":%s,"attempts":%s,"success":%s,"success_rate":%s,"loss_pct":%s,"min_ms":%s,"avg_ms":%s,"max_ms":%s,"jitter_ms":%s,"status":"%s","score":%s}' \
    "$(json_escape "$region")" "$(json_escape "$host")" "$port" "$attempts" "$success" "$success_rate" "$loss_pct" \
    "$(json_number_or_null "$min_ms")" "$(json_number_or_null "$avg_ms")" "$(json_number_or_null "$max_ms")" "$(json_number_or_null "$jitter_ms")" \
    "$(json_escape "$status")" "$score"
}

print_json() {
  local generated_at best line first=1

  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  best="$(best_result || true)"

  if [[ "$BEST_ONLY" -eq 1 ]]; then
    if [[ -z "$best" ]]; then
      printf 'null\n'
      return 1
    fi
    print_json_object "$best"
    printf '\n'
    return 0
  fi

  printf '{"generated_at":"%s","attempts":%s,"timeout_seconds":%s,"results":[' "$generated_at" "$ATTEMPTS" "$TIMEOUT_SECONDS"
  for line in "${RESULT_ROWS[@]}"; do
    if [[ "$first" -eq 0 ]]; then
      printf ','
    fi
    first=0
    print_json_object "$line"
  done
  printf '],"best":'
  if [[ -n "$best" ]]; then
    print_json_object "$best"
  else
    printf 'null'
  fi
  printf '}\n'
}

print_env() {
  local best region host port attempts success success_rate loss_pct min_ms avg_ms max_ms jitter_ms status score

  best="$(best_result || true)"
  if [[ -z "$best" ]]; then
    echo "No reachable AlphaPool endpoint was found." >&2
    return 1
  fi

  IFS=$'\t' read -r region host port attempts success success_rate loss_pct min_ms avg_ms max_ms jitter_ms status score <<< "$best"

  printf 'ALPHAPOOL_REGION=%q\n' "$region"
  printf 'ALPHAPOOL_HOST=%q\n' "$host"
  printf 'ALPHAPOOL_PORT=%q\n' "$port"
  printf 'ALPHAPOOL_POOL=%q\n' "${host}:${port}"
  printf 'ALPHAPOOL_SUCCESS_RATE=%q\n' "$success_rate"
  printf 'ALPHAPOOL_AVG_MS=%q\n' "$avg_ms"
  printf 'ALPHAPOOL_JITTER_MS=%q\n' "$jitter_ms"
  printf 'ALPHAPOOL_STATUS=%q\n' "$status"
}

run_once() {
  alphapool_require_network_tools || return 1
  collect_results

  if [[ "${#RESULT_ROWS[@]}" -eq 0 ]]; then
    echo "No endpoints matched the selected filters." >&2
    return 1
  fi

  case "$OUTPUT_MODE" in
    human) print_human ;;
    json) print_json ;;
    env) print_env ;;
    *) echo "Unsupported output mode: $OUTPUT_MODE" >&2; return 2 ;;
  esac
}

if [[ "$LIST_ONLY" -eq 1 ]]; then
  print_list
  exit 0
fi

if [[ -n "$WATCH_INTERVAL" ]]; then
  while true; do
    clear
    run_once
    sleep "$WATCH_INTERVAL"
  done
else
  run_once
fi
