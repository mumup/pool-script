#!/usr/bin/env bash

# Shared AlphaPool network helpers. Source this file from deployment scripts.

ALPHAPOOL_ENDPOINTS=(
  "US East|us1.alphapool.tech|5566 5567"
  "US West|us2.alphapool.tech|5566 5567"
  "Europe|eu1.alphapool.tech|5566 5567"
  "Russia / Eurasia|ru1.alphapool.tech|5566 5567"
  "Asia|sg1.alphapool.tech|5566 5567"
  "Europe 2|eu2.alphapool.tech|5566 5567"
)

alphapool_trim() {
  local value="$*"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

alphapool_require_network_tools() {
  local missing=0
  local tool

  for tool in bash timeout date awk; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      printf 'Missing required command: %s\n' "$tool" >&2
      missing=1
    fi
  done

  return "$missing"
}

alphapool_list_pool_ports() {
  local item region host ports port

  for item in "${ALPHAPOOL_ENDPOINTS[@]}"; do
    IFS='|' read -r region host ports <<< "$item"
    for port in $ports; do
      printf '%s\t%s\t%s\n' "$region" "$host" "$port"
    done
  done
}

alphapool_tcp_probe() {
  local host="$1"
  local port="$2"
  local timeout_seconds="${3:-3}"
  local start_ns end_ns latency_ms rc reason

  start_ns="$(date +%s%N)"
  if ALPHAPOOL_PROBE_HOST="$host" ALPHAPOOL_PROBE_PORT="$port" \
    timeout "${timeout_seconds}s" bash -c 'exec 3<>"/dev/tcp/${ALPHAPOOL_PROBE_HOST}/${ALPHAPOOL_PROBE_PORT}"' >/dev/null 2>&1; then
    end_ns="$(date +%s%N)"
    latency_ms="$(awk -v start="$start_ns" -v end="$end_ns" 'BEGIN { printf "%.1f", (end - start) / 1000000 }')"
    printf 'ok\t%s\tconnected\n' "$latency_ms"
    return 0
  fi

  rc=$?
  end_ns="$(date +%s%N)"
  latency_ms="$(awk -v start="$start_ns" -v end="$end_ns" 'BEGIN { printf "%.1f", (end - start) / 1000000 }')"

  if [[ "$rc" -eq 124 ]]; then
    reason="timeout"
  else
    reason="failed"
  fi

  printf 'fail\t%s\t%s\n' "$latency_ms" "$reason"
  return 1
}

alphapool_calc_latency_stats() {
  awk '
    NF {
      n += 1
      values[n] = $1 + 0
      sum += values[n]
      if (n == 1 || values[n] < min) min = values[n]
      if (n == 1 || values[n] > max) max = values[n]
    }
    END {
      if (n == 0) {
        printf "N/A\tN/A\tN/A\tN/A"
        exit
      }

      avg = sum / n
      for (i = 1; i <= n; i++) {
        variance += (values[i] - avg) * (values[i] - avg)
      }
      jitter = sqrt(variance / n)
      printf "%.1f\t%.1f\t%.1f\t%.1f", min, avg, max, jitter
    }
  '
}

alphapool_endpoint_status() {
  local attempts="$1"
  local success="$2"
  local avg_ms="$3"
  local jitter_ms="$4"

  awk -v attempts="$attempts" -v success="$success" -v avg="$avg_ms" -v jitter="$jitter_ms" 'BEGIN {
    if (success == 0) {
      print "DOWN"
    } else if (success < attempts) {
      print "UNSTABLE"
    } else if (avg != "N/A" && avg + 0 >= 500) {
      print "SLOW"
    } else if (avg != "N/A" && (avg + 0 >= 250 || jitter + 0 >= 100)) {
      print "WARN"
    } else {
      print "OK"
    }
  }'
}

alphapool_endpoint_score() {
  local attempts="$1"
  local success="$2"
  local avg_ms="$3"
  local jitter_ms="$4"

  awk -v attempts="$attempts" -v success="$success" -v avg="$avg_ms" -v jitter="$jitter_ms" 'BEGIN {
    if (success == 0 || avg == "N/A") {
      print "999999.0"
      exit
    }

    loss_pct = ((attempts - success) / attempts) * 100
    score = (avg + 0) + (jitter + 0) * 2 + loss_pct * 20
    printf "%.1f", score
  }'
}

alphapool_test_endpoint_tsv() {
  local region="$1"
  local host="$2"
  local port="$3"
  local attempts="${4:-5}"
  local timeout_seconds="${5:-3}"
  local i result probe_status latency_ms reason
  local success=0
  local latencies=()
  local min_ms avg_ms max_ms jitter_ms success_rate loss_pct status score

  for ((i = 1; i <= attempts; i++)); do
    result="$(alphapool_tcp_probe "$host" "$port" "$timeout_seconds" || true)"
    IFS=$'\t' read -r probe_status latency_ms reason <<< "$result"

    if [[ "$probe_status" == "ok" ]]; then
      success=$((success + 1))
      latencies+=("$latency_ms")
    fi
  done

  if [[ "$success" -gt 0 ]]; then
    IFS=$'\t' read -r min_ms avg_ms max_ms jitter_ms < <(printf '%s\n' "${latencies[@]}" | alphapool_calc_latency_stats)
  else
    min_ms="N/A"
    avg_ms="N/A"
    max_ms="N/A"
    jitter_ms="N/A"
  fi

  success_rate="$(awk -v success="$success" -v attempts="$attempts" 'BEGIN { printf "%.1f", (success / attempts) * 100 }')"
  loss_pct="$(awk -v success="$success" -v attempts="$attempts" 'BEGIN { printf "%.1f", ((attempts - success) / attempts) * 100 }')"
  status="$(alphapool_endpoint_status "$attempts" "$success" "$avg_ms" "$jitter_ms")"
  score="$(alphapool_endpoint_score "$attempts" "$success" "$avg_ms" "$jitter_ms")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$region" "$host" "$port" "$attempts" "$success" "$success_rate" "$loss_pct" \
    "$min_ms" "$avg_ms" "$max_ms" "$jitter_ms" "$status" "$score"
}

alphapool_best_result_from_tsv() {
  awk -F '\t' '
    $12 != "DOWN" {
      if (!found || $13 + 0 < best_score) {
        found = 1
        best_score = $13 + 0
        best = $0
      }
    }
    END {
      if (found) print best
    }
  '
}
