#!/usr/bin/env bash
set -uo pipefail

VERSION="1.0.0"
INTERVAL=""
NO_COLOR=0
RAW_QUERY=0

usage() {
  cat <<'EOF'
NVIDIA GPU mining diagnostic script

Usage:
  ./check_nvidia_gpu.sh [options]

Options:
  -w, --watch SECONDS   Refresh report every N seconds.
      --raw             Append raw nvidia-smi query output for deeper debugging.
      --no-color        Disable colored status labels.
  -h, --help            Show this help.

Checks:
  - Driver/CUDA/NVIDIA-SMI versions
  - GPU utilization, memory usage, power draw and power limits
  - Current/max/application clocks
  - Clock throttle reasons, including power cap and thermal slowdown
  - Temperature, fan, PCIe link, persistence mode and compute mode
  - Compute processes using each GPU
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--watch)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      INTERVAL="$2"
      shift 2
      ;;
    --raw)
      RAW_QUERY=1
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

if [[ -n "$INTERVAL" ]] && ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [[ "${INTERVAL:-0}" == "0" && -n "$INTERVAL" ]]; then
  echo "--watch must be a positive integer number of seconds." >&2
  exit 2
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: nvidia-smi was not found.

Install the NVIDIA Linux driver first, then rerun this script.
On Ubuntu/Debian, useful checks are:
  lspci | grep -i nvidia
  ubuntu-drivers devices
EOF
  exit 1
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

trim() {
  local value="$*"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

is_na() {
  [[ -z "${1:-}" || "$1" == "N/A" || "$1" == "[N/A]" || "$1" == "[Not Supported]" || "$1" == "Not Supported" || "$1" == "Not Active" || "$1" == *"deprecated"* ]]
}

num() {
  local value="${1:-}"
  awk -v v="$value" 'BEGIN {
    if (match(v, /-?[0-9]+([.][0-9]+)?/)) {
      print substr(v, RSTART, RLENGTH)
    } else {
      print ""
    }
  }'
}

ge() {
  awk -v a="${1:-}" -v b="${2:-}" 'BEGIN { exit !(a != "" && b != "" && a + 0 >= b + 0) }'
}

lt() {
  awk -v a="${1:-}" -v b="${2:-}" 'BEGIN { exit !(a != "" && b != "" && a + 0 < b + 0) }'
}

pct_ratio() {
  local used total
  used="$(num "${1:-}")"
  total="$(num "${2:-}")"
  awk -v u="$used" -v t="$total" 'BEGIN {
    if (u != "" && t != "" && t > 0) printf "%.1f", (u / t) * 100;
    else printf "N/A";
  }'
}

status() {
  local level="$1"
  local text="$2"
  case "$level" in
    ok) printf '%s%s%s' "$C_OK" "$text" "$C_RESET" ;;
    warn) printf '%s%s%s' "$C_WARN" "$text" "$C_RESET" ;;
    bad) printf '%s%s%s' "$C_BAD" "$text" "$C_RESET" ;;
    info) printf '%s%s%s' "$C_INFO" "$text" "$C_RESET" ;;
    *) printf '%s' "$text" ;;
  esac
}

smi_value() {
  local gpu="$1"
  local field="$2"
  local output
  output="$(nvidia-smi -i "$gpu" --query-gpu="$field" --format=csv,noheader,nounits 2>/dev/null | head -n 1 || true)"
  output="$(trim "$output")"
  if is_na "$output"; then
    printf 'N/A'
  else
    printf '%s' "$output"
  fi
}

smi_first_value() {
  local gpu="$1"
  shift
  local field output
  for field in "$@"; do
    output="$(smi_value "$gpu" "$field")"
    if ! is_na "$output"; then
      printf '%s' "$output"
      return
    fi
  done
  printf 'N/A'
}

driver_value() {
  local field="$1"
  local output
  output="$(nvidia-smi --query-gpu="$field" --format=csv,noheader,nounits 2>/dev/null | head -n 1 || true)"
  output="$(trim "$output")"
  if is_na "$output"; then
    printf 'N/A'
  else
    printf '%s' "$output"
  fi
}

print_pair() {
  local label="$1"
  local value="$2"
  printf '  %-24s %s\n' "$label:" "$value"
}

print_header() {
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  local smi_ver driver cuda
  smi_ver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | head -n 1 || true)"
  driver="$(driver_value driver_version)"
  cuda="$(nvidia-smi 2>/dev/null | awk -F 'CUDA Version: ' '/CUDA Version:/ { split($2, a, /[ |]/); print a[1]; exit }')"
  [[ -n "$cuda" ]] || cuda="N/A"

  printf '%s\n' "============================================================"
  printf '%s\n' "NVIDIA GPU Mining Diagnostic  v$VERSION"
  printf '%s\n' "Time: $now"
  printf '%s\n' "Host: $(hostname 2>/dev/null || echo N/A)"
  printf '%s\n' "NVIDIA Driver: $(trim "$driver")"
  printf '%s\n' "CUDA Version: $cuda"
  printf '%s\n' "nvidia-smi driver query: $(trim "$smi_ver")"
  printf '%s\n' "============================================================"
}

print_processes() {
  local gpu="$1"
  local uuid="$2"
  local rows
  rows="$(nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits 2>/dev/null | awk -F ', ' -v uuid="$uuid" '$1 == uuid {print}' || true)"

  if [[ -z "$rows" ]]; then
    print_pair "Compute processes" "none reported"
    return
  fi

  print_pair "Compute processes" ""
  printf '%s\n' "$rows" | while IFS=, read -r app_uuid pid pname mem; do
    app_uuid="$(trim "$app_uuid")"
    pid="$(trim "$pid")"
    pname="$(trim "$pname")"
    mem="$(trim "$mem")"
    [[ "$app_uuid" == "$uuid" ]] || continue
    printf '    pid=%-8s mem=%-8s MiB  %s\n' "$pid" "$mem" "$pname"
  done
}

active_reason() {
  local name="$1"
  local value="$2"
  if [[ "$value" == "Active" ]]; then
    printf '%s ' "$name"
  fi
}

print_gpu() {
  local gpu="$1"
  local index name uuid bus pstate persist compute_mode mig
  local util mem_util mem_total mem_used mem_free mem_pct
  local temp mem_temp fan power_draw power_limit enforced_limit default_limit min_limit max_limit power_pct
  local clock_g clock_sm clock_mem clock_vid max_g max_sm max_mem app_g app_mem default_app_g default_app_mem
  local throttle_active tr_idle tr_app tr_sw_power tr_hw_slow tr_hw_thermal tr_hw_brake tr_sw_thermal tr_sync
  local pcie_gen pcie_gen_max pcie_width pcie_width_max ecc

  index="$(smi_value "$gpu" index)"
  name="$(smi_value "$gpu" name)"
  uuid="$(smi_value "$gpu" uuid)"
  bus="$(smi_value "$gpu" pci.bus_id)"
  pstate="$(smi_value "$gpu" pstate)"
  persist="$(smi_value "$gpu" persistence_mode)"
  compute_mode="$(smi_value "$gpu" compute_mode)"
  mig="$(smi_value "$gpu" mig.mode.current)"
  ecc="$(smi_value "$gpu" ecc.mode.current)"

  util="$(smi_value "$gpu" utilization.gpu)"
  mem_util="$(smi_value "$gpu" utilization.memory)"
  mem_total="$(smi_value "$gpu" memory.total)"
  mem_used="$(smi_value "$gpu" memory.used)"
  mem_free="$(smi_value "$gpu" memory.free)"
  mem_pct="$(pct_ratio "$mem_used" "$mem_total")"

  temp="$(smi_value "$gpu" temperature.gpu)"
  mem_temp="$(smi_value "$gpu" temperature.memory)"
  fan="$(smi_value "$gpu" fan.speed)"
  power_draw="$(smi_first_value "$gpu" power.draw power.draw.average power.draw.instant)"
  power_limit="$(smi_value "$gpu" power.limit)"
  enforced_limit="$(smi_value "$gpu" enforced.power.limit)"
  default_limit="$(smi_value "$gpu" power.default_limit)"
  min_limit="$(smi_value "$gpu" power.min_limit)"
  max_limit="$(smi_value "$gpu" power.max_limit)"
  power_pct="$(pct_ratio "$power_draw" "$power_limit")"

  clock_g="$(smi_value "$gpu" clocks.current.graphics)"
  clock_sm="$(smi_value "$gpu" clocks.current.sm)"
  clock_mem="$(smi_value "$gpu" clocks.current.memory)"
  clock_vid="$(smi_value "$gpu" clocks.current.video)"
  max_g="$(smi_value "$gpu" clocks.max.graphics)"
  max_sm="$(smi_value "$gpu" clocks.max.sm)"
  max_mem="$(smi_value "$gpu" clocks.max.memory)"
  app_g="$(smi_value "$gpu" clocks.applications.graphics)"
  app_mem="$(smi_value "$gpu" clocks.applications.memory)"
  default_app_g="$(smi_value "$gpu" clocks.default_applications.graphics)"
  default_app_mem="$(smi_value "$gpu" clocks.default_applications.memory)"

  throttle_active="$(smi_value "$gpu" clocks_throttle_reasons.active)"
  tr_idle="$(smi_value "$gpu" clocks_throttle_reasons.gpu_idle)"
  tr_app="$(smi_value "$gpu" clocks_throttle_reasons.applications_clocks_setting)"
  tr_sw_power="$(smi_value "$gpu" clocks_throttle_reasons.sw_power_cap)"
  tr_hw_slow="$(smi_value "$gpu" clocks_throttle_reasons.hw_slowdown)"
  tr_hw_thermal="$(smi_value "$gpu" clocks_throttle_reasons.hw_thermal_slowdown)"
  tr_hw_brake="$(smi_value "$gpu" clocks_throttle_reasons.hw_power_brake_slowdown)"
  tr_sw_thermal="$(smi_value "$gpu" clocks_throttle_reasons.sw_thermal_slowdown)"
  tr_sync="$(smi_value "$gpu" clocks_throttle_reasons.sync_boost)"

  pcie_gen="$(smi_value "$gpu" pcie.link.gen.current)"
  pcie_gen_max="$(smi_value "$gpu" pcie.link.gen.max)"
  pcie_width="$(smi_value "$gpu" pcie.link.width.current)"
  pcie_width_max="$(smi_value "$gpu" pcie.link.width.max)"

  printf '\n%s\n' "GPU $index - $name"
  printf '%s\n' "------------------------------------------------------------"
  print_pair "UUID" "$uuid"
  print_pair "PCI Bus" "$bus"
  print_pair "P-State" "$pstate"
  print_pair "Persistence mode" "$persist"
  print_pair "Compute mode" "$compute_mode"
  print_pair "MIG mode" "$mig"
  print_pair "ECC mode" "$ecc"

  printf '\n'
  print_pair "GPU utilization" "${util}%"
  print_pair "Memory utilization" "${mem_util}%"
  print_pair "Memory used/total" "${mem_used} / ${mem_total} MiB (${mem_pct}%)"
  print_pair "Memory free" "${mem_free} MiB"

  printf '\n'
  print_pair "Power draw" "${power_draw} W"
  print_pair "Power limit" "${power_limit} W"
  print_pair "Enforced power limit" "${enforced_limit} W"
  print_pair "Default power limit" "${default_limit} W"
  print_pair "Min/Max power limit" "${min_limit} / ${max_limit} W"
  print_pair "Power limit usage" "${power_pct}%"

  printf '\n'
  print_pair "GPU temperature" "${temp} C"
  print_pair "Memory temperature" "${mem_temp} C"
  print_pair "Fan speed" "${fan}%"

  printf '\n'
  print_pair "Current clocks" "graphics=${clock_g} MHz, sm=${clock_sm} MHz, memory=${clock_mem} MHz, video=${clock_vid} MHz"
  print_pair "Max clocks" "graphics=${max_g} MHz, sm=${max_sm} MHz, memory=${max_mem} MHz"
  print_pair "Application clocks" "graphics=${app_g} MHz, memory=${app_mem} MHz"
  print_pair "Default app clocks" "graphics=${default_app_g} MHz, memory=${default_app_mem} MHz"
  print_pair "Throttle active mask" "$throttle_active"

  local reasons=""
  reasons+="$(active_reason gpu_idle "$tr_idle")"
  reasons+="$(active_reason app_clocks "$tr_app")"
  reasons+="$(active_reason sw_power_cap "$tr_sw_power")"
  reasons+="$(active_reason hw_slowdown "$tr_hw_slow")"
  reasons+="$(active_reason hw_thermal "$tr_hw_thermal")"
  reasons+="$(active_reason hw_power_brake "$tr_hw_brake")"
  reasons+="$(active_reason sw_thermal "$tr_sw_thermal")"
  reasons+="$(active_reason sync_boost "$tr_sync")"
  reasons="$(trim "$reasons")"
  [[ -n "$reasons" ]] || reasons="none"
  print_pair "Throttle reasons" "$reasons"

  printf '\n'
  print_pair "PCIe link" "Gen ${pcie_gen}/${pcie_gen_max}, Width x${pcie_width}/x${pcie_width_max}"
  print_processes "$gpu" "$uuid"

  printf '\n'
  print_pair "Mining hints" ""
  local util_n temp_n mem_temp_n power_pct_n
  util_n="$(num "$util")"
  temp_n="$(num "$temp")"
  mem_temp_n="$(num "$mem_temp")"
  power_pct_n="$(num "$power_pct")"

  if ge "$util_n" 95; then
    printf '    %s GPU is near full load (%s%%).\n' "$(status ok OK)" "$util_n"
  elif ge "$util_n" 50; then
    printf '    %s GPU load is moderate (%s%%); compare with expected miner hashrate.\n' "$(status warn WARN)" "$util_n"
  else
    printf '    %s GPU load is low (%s%%); miner may not be running, bound to another GPU, or waiting on DAG/network.\n' "$(status bad CHECK)" "${util_n:-N/A}"
  fi

  if [[ "$tr_sw_power" == "Active" ]] || ge "$power_pct_n" 95; then
    printf '    %s Power cap is likely limiting clocks; this can be intentional for efficiency.\n' "$(status warn WARN)"
  else
    printf '    %s No obvious software power-cap throttle.\n' "$(status ok OK)"
  fi

  if [[ "$tr_hw_thermal" == "Active" || "$tr_sw_thermal" == "Active" ]] || ge "$temp_n" 80 || ge "$mem_temp_n" 100; then
    printf '    %s Thermal limit risk; check airflow, fan curve, dust, pads and ambient temperature.\n' "$(status bad CHECK)"
  else
    printf '    %s No obvious thermal throttle.\n' "$(status ok OK)"
  fi

  if [[ "$tr_app" == "Active" ]]; then
    printf '    %s Application clocks are limiting frequency; verify locked clocks are intended.\n' "$(status warn WARN)"
  fi

  if ! is_na "$app_mem" && ! is_na "$default_app_mem"; then
    local app_mem_n default_app_mem_n
    app_mem_n="$(num "$app_mem")"
    default_app_mem_n="$(num "$default_app_mem")"
    if lt "$app_mem_n" "$default_app_mem_n"; then
      printf '    %s Memory application clock is below default; this may reduce hashrate.\n' "$(status warn WARN)"
    fi
  fi

  if [[ "$persist" != "Enabled" && "$persist" != "N/A" ]]; then
    printf '    %s Persistence mode is disabled; enabling it can reduce miner startup/driver latency.\n' "$(status info INFO)"
  fi
}

print_summary_table() {
  local count="$1"
  printf '\n%s\n' "Quick Summary"
  printf '%s\n' "------------------------------------------------------------"
  printf '%-4s %-24s %7s %8s %12s %12s %8s %8s %s\n' "GPU" "Name" "Util" "Temp" "Power" "Mem" "PState" "MemClk" "Throttle"
  for ((gpu=0; gpu<count; gpu++)); do
    local name util temp power_draw power_limit mem_used mem_total pstate mem_clock sw_power thermal app
    name="$(smi_value "$gpu" name)"
    util="$(smi_value "$gpu" utilization.gpu)"
    temp="$(smi_value "$gpu" temperature.gpu)"
    power_draw="$(smi_first_value "$gpu" power.draw power.draw.average power.draw.instant)"
    power_limit="$(smi_value "$gpu" power.limit)"
    mem_used="$(smi_value "$gpu" memory.used)"
    mem_total="$(smi_value "$gpu" memory.total)"
    pstate="$(smi_value "$gpu" pstate)"
    mem_clock="$(smi_value "$gpu" clocks.current.memory)"
    sw_power="$(smi_value "$gpu" clocks_throttle_reasons.sw_power_cap)"
    thermal="$(smi_value "$gpu" clocks_throttle_reasons.hw_thermal_slowdown)"
    app="$(smi_value "$gpu" clocks_throttle_reasons.applications_clocks_setting)"

    local throttle="none"
    [[ "$sw_power" == "Active" ]] && throttle="power"
    [[ "$thermal" == "Active" ]] && throttle="thermal"
    [[ "$app" == "Active" ]] && throttle="${throttle},appclk"
    throttle="${throttle#none,}"

    printf '%-4s %-24.24s %6s%% %7sC %6s/%-5sW %5s/%-5sM %-8s %6sM %s\n' \
      "$gpu" "$name" "$util" "$temp" "$power_draw" "$power_limit" "$mem_used" "$mem_total" "$pstate" "$mem_clock" "$throttle"
  done
}

run_once() {
  local count
  count="$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits 2>/dev/null | head -n 1 || true)"
  count="$(trim "$count")"

  if [[ -z "$count" || ! "$count" =~ ^[0-9]+$ || "$count" -eq 0 ]]; then
    echo "No NVIDIA GPUs were reported by nvidia-smi." >&2
    return 1
  fi

  print_header
  print_summary_table "$count"

  for ((gpu=0; gpu<count; gpu++)); do
    print_gpu "$gpu"
  done

  if [[ "$RAW_QUERY" -eq 1 ]]; then
    printf '\n%s\n' "Raw nvidia-smi:"
    printf '%s\n' "------------------------------------------------------------"
    nvidia-smi
  fi
}

if [[ -n "$INTERVAL" ]]; then
  while true; do
    clear
    run_once
    sleep "$INTERVAL"
  done
else
  run_once
fi
