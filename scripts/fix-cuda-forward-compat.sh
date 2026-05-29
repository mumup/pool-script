#!/usr/bin/env bash
set -euo pipefail

# Fix:
#   cudaGetDeviceCount failed: forward compatibility was attempted on non supported HW
#
# Why this happens:
#   /usr/local/cuda-*/compat/libcuda.so.1 is loaded before the real NVIDIA
#   driver libcuda.so.1. Many consumer GPUs, including RTX 4090, cannot use
#   that CUDA forward-compatibility path.
#
# Usage:
#   sudo ./fix-cuda-forward-compat.sh
#   sudo ./fix-cuda-forward-compat.sh -- ./alpha-miner-beta-174 --pool ...

log() {
  printf '[cuda-fix] %s\n' "$*"
}

if [ "$(id -u)" -ne 0 ]; then
  log "Run as root: sudo $0"
  exit 1
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
changed=0

log "Checking ldconfig CUDA compat entries"

shopt -s nullglob
for conf in /etc/ld.so.conf /etc/ld.so.conf.d/*.conf; do
  [ -f "$conf" ] || continue

  if grep -Eq '/usr/local/cuda([^[:space:]]*)?/compat' "$conf"; then
    backup="${conf}.disabled-${timestamp}"
    log "Disabling $conf -> $backup"
    mv "$conf" "$backup"
    changed=1
  fi
done

if [ "$changed" -eq 1 ]; then
  log "Running ldconfig"
  ldconfig
else
  log "No /etc/ld.so.conf CUDA compat entry found"
fi

if printf '%s' "${LD_LIBRARY_PATH:-}" | grep -qE '/usr/local/cuda([^:]*)?/compat'; then
  log "Removing CUDA compat path from LD_LIBRARY_PATH for this process"
  export LD_LIBRARY_PATH="$(
    printf '%s' "$LD_LIBRARY_PATH" |
      tr ':' '\n' |
      grep -Ev '^/usr/local/cuda([^/]*)?/compat/?$' |
      paste -sd ':' -
  )"
fi

log "libcuda resolution after fix:"
ldconfig -p | grep 'libcuda.so.1' | head -5 || true

if ldconfig -p | grep 'libcuda.so.1' | head -1 | grep -q '/compat/'; then
  log "WARNING: libcuda still resolves to a compat path."
  log "Check LD_LIBRARY_PATH and /etc/ld.so.conf.d manually."
  exit 2
fi

if [ "${1:-}" = "--" ]; then
  shift
  log "Starting: $*"
  exec "$@"
fi

log "Done. Start your miner again."
