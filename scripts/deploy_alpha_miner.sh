#!/usr/bin/env bash
set -uo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/alphapool_network.sh
source "$SCRIPT_DIR/lib/alphapool_network.sh"

REPO_OWNER="AlphaMine-Tech"
REPO_NAME="alpha-miner"
GITHUB_API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"

INSTALL_ROOT="/opt/alphapool/alpha-miner"
VERSIONS_DIR="$INSTALL_ROOT/versions"
CURRENT_LINK="$INSTALL_ROOT/current"
RUNNER_PATH="$INSTALL_ROOT/run-alpha-miner.sh"
SUPERVISOR_PATH="$INSTALL_ROOT/supervise.sh"
PID_FILE="$INSTALL_ROOT/alpha-miner-supervisor.pid"
ENV_DIR="/etc/alphapool"
ENV_FILE="$ENV_DIR/alpha-miner.env"
LOG_FILE="/alpha-miner.log"
SERVICE_NAME="alpha-miner.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

ACTION="deploy"
YES=0
NO_START=0

CLI_VERSION=""
CLI_ADDRESS=""
CLI_WORKER=""
CLI_POOL=""

INHERITED_VERSION="${ALPHAPOOL_VERSION:-}"
INHERITED_BIN="${ALPHAPOOL_BIN:-}"
INHERITED_POOL="${ALPHAPOOL_POOL:-}"
INHERITED_ADDRESS="${ALPHAPOOL_ADDRESS:-}"
INHERITED_WORKER="${ALPHAPOOL_WORKER:-}"
INHERITED_LOG="${ALPHAPOOL_LOG:-}"

VERSION_ROWS=()
VERSION_TAGS=()
VERSION_PRERELEASES=()
VERSION_PUBLISHED=()
VERSION_NAMES=()

usage() {
  cat <<'EOF'
Alpha Miner one-click deploy script

Usage:
  ./deploy_alpha_miner.sh [options]

Options:
      --version TAG       Use a specific Alpha Miner release tag.
      --address ADDRESS   Pearl/PRL address, for example prl1p...
      --worker NAME       Worker name, for example rig01.
      --pool HOST:PORT    Mining pool endpoint. Skips automatic pool selection.
      --yes               Non-interactive mode. Missing PRL address fails.
      --no-start          Install and save config, but do not start miner.
      --status            Show service/supervisor status and recent logs.
      --stop              Stop alpha-miner service and matching processes.
  -h, --help              Show this help.

Deployment layout:
  /opt/alphapool/alpha-miner/versions/<tag>/alpha-miner
  /opt/alphapool/alpha-miner/current
  /etc/alphapool/alpha-miner.env
  /alpha-miner.log
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      CLI_VERSION="$2"
      shift 2
      ;;
    --address)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      CLI_ADDRESS="$2"
      shift 2
      ;;
    --worker)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      CLI_WORKER="$2"
      shift 2
      ;;
    --pool)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      CLI_POOL="$2"
      shift 2
      ;;
    --yes)
      YES=1
      shift
      ;;
    --no-start)
      NO_START=1
      shift
      ;;
    --status)
      ACTION="status"
      shift
      ;;
    --stop)
      ACTION="stop"
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

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_OK=$'\033[32m'
  C_WARN=$'\033[33m'
  C_BAD=$'\033[31m'
  C_INFO=$'\033[36m'
else
  C_RESET=""
  C_OK=""
  C_WARN=""
  C_BAD=""
  C_INFO=""
fi

log_info() {
  printf '%s%s%s %s\n' "$C_INFO" "INFO" "$C_RESET" "$*" >&2
}

log_ok() {
  printf '%s%s%s %s\n' "$C_OK" "OK" "$C_RESET" "$*" >&2
}

log_warn() {
  printf '%s%s%s %s\n' "$C_WARN" "WARN" "$C_RESET" "$*" >&2
}

log_error() {
  printf '%s%s%s %s\n' "$C_BAD" "ERROR" "$C_RESET" "$*" >&2
}

die() {
  log_error "$*"
  exit 1
}

is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

as_root() {
  if is_root; then
    "$@"
  else
    sudo "$@"
  fi
}

as_root_bash() {
  local script="$1"
  if is_root; then
    bash -c "$script"
  else
    sudo bash -c "$script"
  fi
}

quote() {
  printf '%q' "$1"
}

ensure_root_access() {
  if is_root; then
    return 0
  fi

  command -v sudo >/dev/null 2>&1 || die "This deployment writes to /opt, /etc and /. Run as root or install sudo."

  if [[ "$YES" -eq 1 ]]; then
    sudo -n true 2>/dev/null || die "sudo requires a password. Rerun interactively or run as root."
  else
    sudo -v || die "sudo authentication failed."
  fi
}

have_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

http_get_to_file() {
  local url="$1"
  local output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 --output "$output" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$output" "$url"
  else
    return 127
  fi
}

http_get_stdout() {
  local url="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 15 "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O - "$url"
  else
    return 127
  fi
}

sha256_file() {
  local file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    return 127
  fi
}

require_deploy_tools() {
  local missing=0
  local tool

  for tool in bash awk sed grep mktemp install chmod mkdir ln kill sleep date hostname; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      printf 'Missing required command: %s\n' "$tool" >&2
      missing=1
    fi
  done

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    printf 'Missing required command: curl or wget\n' >&2
    missing=1
  fi

  alphapool_require_network_tools || missing=1
  return "$missing"
}

load_persisted_env() {
  local key value

  if [[ -r "$ENV_FILE" ]]; then
    while IFS='=' read -r key value; do
      [[ -n "$key" && "$key" != \#* ]] || continue
      case "$key" in
        ALPHAPOOL_VERSION) ALPHAPOOL_VERSION="$value" ;;
        ALPHAPOOL_BIN) ALPHAPOOL_BIN="$value" ;;
        ALPHAPOOL_POOL) ALPHAPOOL_POOL="$value" ;;
        ALPHAPOOL_ADDRESS) ALPHAPOOL_ADDRESS="$value" ;;
        ALPHAPOOL_WORKER) ALPHAPOOL_WORKER="$value" ;;
        ALPHAPOOL_LOG) ALPHAPOOL_LOG="$value" ;;
      esac
    done < "$ENV_FILE"
  fi

  [[ -n "$INHERITED_VERSION" ]] && ALPHAPOOL_VERSION="$INHERITED_VERSION"
  [[ -n "$INHERITED_BIN" ]] && ALPHAPOOL_BIN="$INHERITED_BIN"
  [[ -n "$INHERITED_POOL" ]] && ALPHAPOOL_POOL="$INHERITED_POOL"
  [[ -n "$INHERITED_ADDRESS" ]] && ALPHAPOOL_ADDRESS="$INHERITED_ADDRESS"
  [[ -n "$INHERITED_WORKER" ]] && ALPHAPOOL_WORKER="$INHERITED_WORKER"
  [[ -n "$INHERITED_LOG" ]] && ALPHAPOOL_LOG="$INHERITED_LOG"

  [[ -n "$CLI_VERSION" ]] && ALPHAPOOL_VERSION="$CLI_VERSION"
  [[ -n "$CLI_POOL" ]] && ALPHAPOOL_POOL="$CLI_POOL"
  [[ -n "$CLI_ADDRESS" ]] && ALPHAPOOL_ADDRESS="$CLI_ADDRESS"
  [[ -n "$CLI_WORKER" ]] && ALPHAPOOL_WORKER="$CLI_WORKER"
  ALPHAPOOL_LOG="${ALPHAPOOL_LOG:-$LOG_FILE}"
}

valid_tag() {
  [[ "$1" =~ ^v[A-Za-z0-9._-]+$ ]]
}

valid_prl_address() {
  [[ "$1" =~ ^prl[A-Za-z0-9]+$ ]]
}

valid_worker() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != -* ]]
}

valid_pool() {
  local value="$1"
  local port

  [[ "$value" =~ ^[A-Za-z0-9._-]+:([0-9]{1,5})$ ]] || return 1
  port="${BASH_REMATCH[1]}"
  [[ "$port" -ge 1 && "$port" -le 65535 ]]
}

valid_abs_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != *"//"* ]]
}

sanitize_worker_default() {
  local value
  value="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
  value="$(printf '%s' "$value" | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-//; s/-$//')"
  [[ -n "$value" ]] || value="rig01"
  printf '%s' "$value"
}

prompt_value() {
  local label="$1"
  local default_value="$2"
  local value

  if [[ "$YES" -eq 1 || ! -t 0 ]]; then
    printf '%s' "$default_value"
    return 0
  fi

  if [[ -n "$default_value" ]]; then
    printf '%s [%s]: ' "$label" "$default_value" >&2
  else
    printf '%s: ' "$label" >&2
  fi

  IFS= read -r value
  if [[ -z "$value" ]]; then
    value="$default_value"
  fi

  printf '%s' "$value"
}

parse_releases_json() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
try:
    releases = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for release in releases:
    tag = release.get("tag_name") or ""
    if not tag.startswith("v"):
        continue
    name = (release.get("name") or tag).replace("\t", " ").replace("\n", " ")
    prerelease = "true" if release.get("prerelease") else "false"
    published = release.get("published_at") or ""
    print("\t".join([tag, prerelease, published, name]))
'
  else
    awk -F '"' '
      /^[[:space:]]*"tag_name":/ { tag=$4; name=""; pre="false"; pub="" }
      /^[[:space:]]*"name":/ && tag != "" && name == "" { name=$4 }
      /^[[:space:]]*"prerelease":/ && tag != "" { pre=($0 ~ /true/ ? "true" : "false") }
      /^[[:space:]]*"published_at":/ && tag != "" {
        pub=$4
        if (tag ~ /^v/) {
          if (name == "") name=tag
          print tag "\t" pre "\t" pub "\t" name
        }
        tag=""; name=""; pre="false"; pub=""
      }
    '
  fi
}

parse_tags_json() {
  awk -F '"' '
    /^[[:space:]]*"name":/ {
      tag=$4
      if (tag ~ /^v/) {
        pre=(tag ~ /(beta|alpha|rc|pre)/ ? "true" : "false")
        print tag "\t" pre "\t\t" tag
      }
    }
  '
}

load_versions() {
  local tmp line tag pre published name

  tmp="$(mktemp)"
  if http_get_to_file "${GITHUB_API}/releases?per_page=50" "$tmp"; then
    while IFS=$'\t' read -r tag pre published name; do
      [[ -n "$tag" ]] || continue
      VERSION_ROWS+=("$tag"$'\t'"$pre"$'\t'"$published"$'\t'"$name")
      VERSION_TAGS+=("$tag")
      VERSION_PRERELEASES+=("$pre")
      VERSION_PUBLISHED+=("$published")
      VERSION_NAMES+=("$name")
    done < <(parse_releases_json < "$tmp")
  fi

  if [[ "${#VERSION_ROWS[@]}" -eq 0 ]]; then
    log_warn "Could not parse releases API; falling back to tags API."
    : > "$tmp"
    http_get_to_file "${GITHUB_API}/tags?per_page=50" "$tmp" || {
      rm -f "$tmp"
      die "Could not fetch Alpha Miner tags from GitHub."
    }

    while IFS=$'\t' read -r tag pre published name; do
      [[ -n "$tag" ]] || continue
      VERSION_ROWS+=("$tag"$'\t'"$pre"$'\t'"$published"$'\t'"$name")
      VERSION_TAGS+=("$tag")
      VERSION_PRERELEASES+=("$pre")
      VERSION_PUBLISHED+=("$published")
      VERSION_NAMES+=("$name")
    done < <(parse_tags_json < "$tmp")
  fi

  rm -f "$tmp"
  [[ "${#VERSION_ROWS[@]}" -gt 0 ]] || die "No deployable v* Alpha Miner versions were found."
}

tag_in_version_list() {
  local wanted="$1"
  local tag
  for tag in "${VERSION_TAGS[@]}"; do
    [[ "$tag" == "$wanted" ]] && return 0
  done
  return 1
}

latest_stable_version() {
  local i
  for ((i = 0; i < ${#VERSION_TAGS[@]}; i++)); do
    if [[ "${VERSION_PRERELEASES[$i]}" != "true" && "${VERSION_TAGS[$i]}" != *beta* && "${VERSION_TAGS[$i]}" != *alpha* && "${VERSION_TAGS[$i]}" != *rc* ]]; then
      printf '%s' "${VERSION_TAGS[$i]}"
      return 0
    fi
  done

  printf '%s' "${VERSION_TAGS[0]}"
}

select_version() {
  local default_version selected choice i label

  load_versions

  default_version="${ALPHAPOOL_VERSION:-}"
  if [[ -z "$default_version" ]] || ! tag_in_version_list "$default_version"; then
    default_version="$(latest_stable_version)"
  fi

  if [[ -n "$CLI_VERSION" ]]; then
    valid_tag "$CLI_VERSION" || die "Invalid version tag: $CLI_VERSION"
    ALPHAPOOL_VERSION="$CLI_VERSION"
    return 0
  fi

  if [[ "$YES" -eq 1 || ! -t 0 ]]; then
    ALPHAPOOL_VERSION="$default_version"
    return 0
  fi

  printf '\nAvailable Alpha Miner versions:\n'
  for ((i = 0; i < ${#VERSION_TAGS[@]}; i++)); do
    label="stable"
    [[ "${VERSION_PRERELEASES[$i]}" == "true" || "${VERSION_TAGS[$i]}" == *beta* ]] && label="beta"
    if [[ "${VERSION_TAGS[$i]}" == "$default_version" ]]; then
      printf '  %2d) %-18s %-8s %s  default\n' "$((i + 1))" "${VERSION_TAGS[$i]}" "$label" "${VERSION_NAMES[$i]}"
    else
      printf '  %2d) %-18s %-8s %s\n' "$((i + 1))" "${VERSION_TAGS[$i]}" "$label" "${VERSION_NAMES[$i]}"
    fi
  done

  printf 'Select version [%s]: ' "$default_version" >&2
  IFS= read -r choice
  if [[ -z "$choice" ]]; then
    selected="$default_version"
  elif [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#VERSION_TAGS[@]}" ]]; then
    selected="${VERSION_TAGS[$((choice - 1))]}"
  else
    selected="$choice"
  fi

  valid_tag "$selected" || die "Invalid version tag: $selected"
  ALPHAPOOL_VERSION="$selected"
}

parse_asset_info_json() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
try:
    release = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for asset in release.get("assets", []):
    if asset.get("name") == "alpha-miner":
        digest = asset.get("digest") or ""
        if digest.startswith("sha256:"):
            digest = digest.split(":", 1)[1]
        print("{}\t{}".format(asset.get("browser_download_url") or "", digest))
        sys.exit(0)
sys.exit(2)
'
  else
    awk -F '"' '
      /^[[:space:]]*"name": "alpha-miner"/ { in_asset=1 }
      in_asset && /^[[:space:]]*"digest":/ {
        digest=$4
        sub(/^sha256:/, "", digest)
      }
      in_asset && /^[[:space:]]*"browser_download_url":/ {
        print $4 "\t" digest
        exit
      }
    '
  fi
}

get_release_asset_info() {
  local tag="$1"
  local tmp info url digest

  tmp="$(mktemp)"
  http_get_to_file "${GITHUB_API}/releases/tags/${tag}" "$tmp" || {
    rm -f "$tmp"
    die "Could not fetch GitHub release for tag $tag. The tag may not have release assets."
  }

  info="$(parse_asset_info_json < "$tmp" || true)"
  rm -f "$tmp"

  IFS=$'\t' read -r url digest <<< "$info"
  [[ -n "$url" ]] || die "Release $tag does not contain a Linux asset named exactly 'alpha-miner'."

  ALPHAPOOL_ASSET_URL="$url"
  ALPHAPOOL_ASSET_SHA256="$digest"
}

download_and_install_miner() {
  local tag="$1"
  local version_dir="$VERSIONS_DIR/$tag"
  local tmp_bin actual_sha expected_sha

  get_release_asset_info "$tag"
  log_info "Downloading alpha-miner $tag"

  tmp_bin="$(mktemp)"
  http_get_to_file "$ALPHAPOOL_ASSET_URL" "$tmp_bin" || {
    rm -f "$tmp_bin"
    die "Download failed: $ALPHAPOOL_ASSET_URL"
  }

  if [[ -n "${ALPHAPOOL_ASSET_SHA256:-}" ]]; then
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || {
      rm -f "$tmp_bin"
      die "Release provides SHA256 digest but neither sha256sum nor shasum is installed."
    }
    expected_sha="$(printf '%s' "$ALPHAPOOL_ASSET_SHA256" | tr '[:upper:]' '[:lower:]')"
    actual_sha="$(sha256_file "$tmp_bin" | tr '[:upper:]' '[:lower:]')"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
      rm -f "$tmp_bin"
      die "SHA256 mismatch for $tag. expected=$expected_sha actual=$actual_sha"
    fi
    log_ok "SHA256 verified"
  else
    log_warn "No SHA256 digest was provided by the GitHub release; continuing without checksum verification."
  fi

  as_root mkdir -p "$version_dir"
  as_root install -m 0755 "$tmp_bin" "$version_dir/alpha-miner"
  as_root ln -sfnT "$version_dir" "$CURRENT_LINK"
  rm -f "$tmp_bin"

  ALPHAPOOL_BIN="$CURRENT_LINK/alpha-miner"
}

write_runtime_scripts() {
  local tmp_runner tmp_supervisor

  tmp_runner="$(mktemp)"
  cat > "$tmp_runner" <<EOF
#!/usr/bin/env bash
set -uo pipefail

ENV_FILE="$ENV_FILE"
if [[ ! -r "\$ENV_FILE" ]]; then
  echo "Missing environment file: \$ENV_FILE" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "\$ENV_FILE"

: "\${ALPHAPOOL_BIN:?missing ALPHAPOOL_BIN}"
: "\${ALPHAPOOL_POOL:?missing ALPHAPOOL_POOL}"
: "\${ALPHAPOOL_ADDRESS:?missing ALPHAPOOL_ADDRESS}"
: "\${ALPHAPOOL_WORKER:?missing ALPHAPOOL_WORKER}"
: "\${ALPHAPOOL_LOG:?missing ALPHAPOOL_LOG}"

cd "\$(dirname "\$ALPHAPOOL_BIN")"
exec "\$ALPHAPOOL_BIN" \\
  --pool "stratum+tcp://\${ALPHAPOOL_POOL}" \\
  --address "\$ALPHAPOOL_ADDRESS" \\
  --worker "\$ALPHAPOOL_WORKER" >> "\$ALPHAPOOL_LOG" 2>&1
EOF

  tmp_supervisor="$(mktemp)"
  cat > "$tmp_supervisor" <<EOF
#!/usr/bin/env bash
set -uo pipefail

RUNNER="$RUNNER_PATH"
ENV_FILE="$ENV_FILE"
DEFAULT_LOG="$LOG_FILE"

while true; do
  log_file="\$DEFAULT_LOG"
  if [[ -r "\$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "\$ENV_FILE"
    log_file="\${ALPHAPOOL_LOG:-\$DEFAULT_LOG}"
  fi

  printf '[%s] supervisor starting alpha-miner\\n' "\$(date '+%Y-%m-%d %H:%M:%S %Z')" >> "\$log_file"
  "\$RUNNER"
  rc=\$?
  printf '[%s] alpha-miner exited rc=%s; restarting in 10s\\n' "\$(date '+%Y-%m-%d %H:%M:%S %Z')" "\$rc" >> "\$log_file"
  sleep 10
done
EOF

  as_root mkdir -p "$INSTALL_ROOT"
  as_root install -m 0755 "$tmp_runner" "$RUNNER_PATH"
  as_root install -m 0755 "$tmp_supervisor" "$SUPERVISOR_PATH"
  rm -f "$tmp_runner" "$tmp_supervisor"
}

write_env_file() {
  local tmp_env

  valid_tag "$ALPHAPOOL_VERSION" || die "Invalid ALPHAPOOL_VERSION: $ALPHAPOOL_VERSION"
  valid_pool "$ALPHAPOOL_POOL" || die "Invalid ALPHAPOOL_POOL: $ALPHAPOOL_POOL"
  valid_prl_address "$ALPHAPOOL_ADDRESS" || die "Invalid ALPHAPOOL_ADDRESS. It must be non-empty, contain no spaces, and start with prl."
  valid_worker "$ALPHAPOOL_WORKER" || die "Invalid ALPHAPOOL_WORKER. It must be non-empty and contain no spaces."
  valid_abs_path "$ALPHAPOOL_BIN" || die "Invalid ALPHAPOOL_BIN path: $ALPHAPOOL_BIN"
  valid_abs_path "$ALPHAPOOL_LOG" || die "Invalid ALPHAPOOL_LOG path: $ALPHAPOOL_LOG"

  tmp_env="$(mktemp)"
  cat > "$tmp_env" <<EOF
ALPHAPOOL_VERSION=$ALPHAPOOL_VERSION
ALPHAPOOL_BIN=$ALPHAPOOL_BIN
ALPHAPOOL_POOL=$ALPHAPOOL_POOL
ALPHAPOOL_ADDRESS=$ALPHAPOOL_ADDRESS
ALPHAPOOL_WORKER=$ALPHAPOOL_WORKER
ALPHAPOOL_LOG=$ALPHAPOOL_LOG
EOF

  as_root mkdir -p "$ENV_DIR"
  as_root install -m 0644 "$tmp_env" "$ENV_FILE"
  as_root touch "$ALPHAPOOL_LOG"
  as_root chmod 0644 "$ALPHAPOOL_LOG"
  rm -f "$tmp_env"
}

print_pool_table() {
  local rows_name="$1"
  local -n rows_ref="$rows_name"
  local line region host port attempts success success_rate loss_pct min_ms avg_ms max_ms jitter_ms status score

  printf '\n%-18s %-24s %-5s %7s %8s %9s %9s\n' "Region" "Host" "Port" "Success" "Loss" "Avg(ms)" "Status"
  printf '%s\n' "--------------------------------------------------------------------------------"
  for line in "${rows_ref[@]}"; do
    IFS=$'\t' read -r region host port attempts success success_rate loss_pct min_ms avg_ms max_ms jitter_ms status score <<< "$line"
    printf '%-18s %-24s %-5s %3s/%-3s %7s%% %9s %9s\n' \
      "$region" "$host" "$port" "$success" "$attempts" "$loss_pct" "$avg_ms" "$status"
  done
}

detect_best_pool() {
  local rows=()
  local region host port line best
  local best_region best_host best_port best_attempts best_success best_success_rate best_loss best_min best_avg best_max best_jitter best_status best_score

  log_info "Testing AlphaPool endpoints on configured mining ports"
  while IFS=$'\t' read -r region host port; do
    line="$(alphapool_test_endpoint_tsv "$region" "$host" "$port" 5 3)"
    rows+=("$line")
  done < <(alphapool_list_pool_ports)

  print_pool_table rows >&2
  best="$(printf '%s\n' "${rows[@]}" | alphapool_best_result_from_tsv || true)"

  if [[ -z "$best" ]]; then
    log_warn "No reachable AlphaPool endpoint was found; using fallback us2.alphapool.tech:5566."
    printf '%s' "us2.alphapool.tech:5566"
    return 0
  fi

  IFS=$'\t' read -r best_region best_host best_port best_attempts best_success best_success_rate best_loss best_min best_avg best_max best_jitter best_status best_score <<< "$best"
  log_ok "Fastest reachable pool: ${best_host}:${best_port} avg=${best_avg}ms success=${best_success_rate}% status=${best_status}"
  printf '%s:%s' "$best_host" "$best_port"
}

select_pool() {
  local detected_pool default_pool selected_pool

  if [[ -n "$CLI_POOL" ]]; then
    valid_pool "$CLI_POOL" || die "Invalid pool: $CLI_POOL"
    ALPHAPOOL_POOL="$CLI_POOL"
    return 0
  fi

  detected_pool="$(detect_best_pool)"
  default_pool="${ALPHAPOOL_POOL:-$detected_pool}"

  if [[ -n "${ALPHAPOOL_POOL:-}" && "$ALPHAPOOL_POOL" != "$detected_pool" ]]; then
    log_info "Saved pool: $ALPHAPOOL_POOL; fastest now: $detected_pool"
  fi

  selected_pool="$(prompt_value "Pool endpoint" "$default_pool")"
  valid_pool "$selected_pool" || die "Invalid pool endpoint: $selected_pool"
  ALPHAPOOL_POOL="$selected_pool"
}

select_address() {
  local selected

  selected="$(prompt_value "Pearl/PRL address" "${ALPHAPOOL_ADDRESS:-}")"
  valid_prl_address "$selected" || die "Invalid Pearl/PRL address. It must start with prl and contain no spaces."
  ALPHAPOOL_ADDRESS="$selected"
}

select_worker() {
  local default_worker selected

  default_worker="${ALPHAPOOL_WORKER:-$(sanitize_worker_default)}"
  selected="$(prompt_value "Worker name" "$default_worker")"
  valid_worker "$selected" || die "Invalid worker name. It must be non-empty and contain no spaces."
  ALPHAPOOL_WORKER="$selected"
}

find_alpha_pids() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -af 'alpha-miner' 2>/dev/null || true
  else
    ps -eo pid=,args= 2>/dev/null | grep '[a]lpha-miner' || true
  fi | awk -v self="$$" '
    {
      pid=$1
      $1=""
      cmd=$0
      if (pid != self &&
          cmd ~ /alpha-miner/ &&
          cmd !~ /deploy_alpha_miner.sh/ &&
          cmd !~ /check_pool_latency.sh/ &&
          cmd !~ /pgrep -af/) {
        print pid
      }
    }
  ' | sort -u
}

pid_alive() {
  local pid="$1"
  as_root kill -0 "$pid" >/dev/null 2>&1
}

stop_systemd_service() {
  if command -v systemctl >/dev/null 2>&1; then
    as_root systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
}

stop_existing_miner() {
  local pids=()
  local alive=()
  local pid i

  log_info "Stopping existing alpha-miner service/processes if present"
  stop_systemd_service

  mapfile -t pids < <(find_alpha_pids)
  if [[ "${#pids[@]}" -eq 0 ]]; then
    log_ok "No running alpha-miner process found"
    return 0
  fi

  log_info "Sending TERM to alpha-miner PIDs: ${pids[*]}"
  as_root kill -TERM "${pids[@]}" >/dev/null 2>&1 || true

  for ((i = 0; i < 10; i++)); do
    alive=()
    for pid in "${pids[@]}"; do
      pid_alive "$pid" && alive+=("$pid")
    done
    [[ "${#alive[@]}" -eq 0 ]] && break
    sleep 1
  done

  if [[ "${#alive[@]}" -gt 0 ]]; then
    log_warn "Forcing alpha-miner PIDs: ${alive[*]}"
    as_root kill -KILL "${alive[@]}" >/dev/null 2>&1 || true
  fi

  log_ok "Old alpha-miner processes stopped"
}

install_systemd_service() {
  local tmp_service

  tmp_service="$(mktemp)"
  cat > "$tmp_service" <<EOF
[Unit]
Description=Alpha Miner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=$RUNNER_PATH
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  as_root install -m 0644 "$tmp_service" "$SERVICE_PATH"
  rm -f "$tmp_service"
  as_root systemctl daemon-reload
  as_root systemctl enable "$SERVICE_NAME" >/dev/null
}

start_systemd_service() {
  install_systemd_service
  as_root systemctl restart "$SERVICE_NAME"
  log_ok "Started systemd service $SERVICE_NAME"
}

start_fallback_supervisor() {
  local q_supervisor q_pid

  q_supervisor="$(quote "$SUPERVISOR_PATH")"
  q_pid="$(quote "$PID_FILE")"
  as_root_bash "nohup $q_supervisor >/dev/null 2>&1 & echo \$! > $q_pid"
  log_ok "Started nohup supervisor"
}

start_miner() {
  if have_systemd; then
    start_systemd_service
  else
    log_warn "systemd is not available; falling back to nohup loop supervisor. This fallback does not enable boot-time autostart."
    start_fallback_supervisor
  fi
}

show_status() {
  local pids

  load_persisted_env

  printf 'Alpha Miner deploy script v%s\n' "$VERSION"
  printf 'Config: %s\n' "$ENV_FILE"
  printf 'Version: %s\n' "${ALPHAPOOL_VERSION:-N/A}"
  printf 'Binary: %s\n' "${ALPHAPOOL_BIN:-N/A}"
  printf 'Pool: %s\n' "${ALPHAPOOL_POOL:-N/A}"
  printf 'Worker: %s\n' "${ALPHAPOOL_WORKER:-N/A}"
  printf 'Log: %s\n' "${ALPHAPOOL_LOG:-$LOG_FILE}"
  printf '\n'

  if command -v systemctl >/dev/null 2>&1 && [[ -f "$SERVICE_PATH" ]]; then
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    printf '\n'
  fi

  if [[ -r "$PID_FILE" ]]; then
    printf 'Fallback supervisor PID file: %s -> %s\n' "$PID_FILE" "$(cat "$PID_FILE" 2>/dev/null || true)"
  fi

  pids="$(find_alpha_pids | tr '\n' ' ')"
  if [[ -n "$pids" ]]; then
    printf 'Matching alpha-miner PIDs: %s\n' "$pids"
  else
    printf 'Matching alpha-miner PIDs: none\n'
  fi

  printf '\nRecent log lines:\n'
  if [[ -r "${ALPHAPOOL_LOG:-$LOG_FILE}" ]]; then
    tail -n 40 "${ALPHAPOOL_LOG:-$LOG_FILE}" || true
  else
    printf 'Log file is not readable: %s\n' "${ALPHAPOOL_LOG:-$LOG_FILE}"
  fi
}

deploy() {
  require_deploy_tools || die "Missing required tools."
  ensure_root_access
  load_persisted_env

  select_version
  select_address
  select_worker
  select_pool

  download_and_install_miner "$ALPHAPOOL_VERSION"
  write_runtime_scripts
  write_env_file
  stop_existing_miner

  if [[ "$NO_START" -eq 1 ]]; then
    log_ok "Installed and saved config. Miner was not started because --no-start was set."
  else
    start_miner
  fi

  printf '\nDeployment summary:\n'
  printf '  Version: %s\n' "$ALPHAPOOL_VERSION"
  printf '  Binary:  %s\n' "$ALPHAPOOL_BIN"
  printf '  Pool:    %s\n' "$ALPHAPOOL_POOL"
  printf '  Worker:  %s\n' "$ALPHAPOOL_WORKER"
  printf '  Log:     %s\n' "$ALPHAPOOL_LOG"
  if have_systemd; then
    printf '  Status:  systemctl status %s\n' "$SERVICE_NAME"
  else
    printf '  Status:  %s --status\n' "$0"
  fi
}

case "$ACTION" in
  deploy)
    deploy
    ;;
  status)
    show_status
    ;;
  stop)
    ensure_root_access
    load_persisted_env
    stop_existing_miner
    ;;
  *)
    die "Unsupported action: $ACTION"
    ;;
esac
