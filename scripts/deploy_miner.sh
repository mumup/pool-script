#!/usr/bin/env bash
set -uo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/alphapool_network.sh
source "$SCRIPT_DIR/lib/alphapool_network.sh"

ALPHA_REPO_OWNER="AlphaMine-Tech"
ALPHA_REPO_NAME="alpha-miner"
ALPHA_GITHUB_API="https://api.github.com/repos/${ALPHA_REPO_OWNER}/${ALPHA_REPO_NAME}"
PEARLHASH_URL_SCRIPT="$SCRIPT_DIR/lib/get-pearlhash-miner-url.sh"

INSTALL_ROOT="/opt/pearl-miner"
VERSIONS_DIR="$INSTALL_ROOT/versions"
CURRENT_LINK="$INSTALL_ROOT/current"
RUNNER_PATH="$INSTALL_ROOT/run-miner.sh"
SUPERVISOR_PATH="$INSTALL_ROOT/supervise.sh"
PID_FILE="$INSTALL_ROOT/miner-supervisor.pid"
CUDA_FIX_SCRIPT="$SCRIPT_DIR/fix-cuda-forward-compat.sh"
ENV_DIR="/etc/pearl-miner"
ENV_FILE="$ENV_DIR/miner.env"
OLD_ENV_FILE="/etc/alphapool/alpha-miner.env"
LOG_FILE="/pearl-miner.log"
SERVICE_NAME="pearl-miner.service"
OLD_SERVICE_NAME="alpha-miner.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

ACTION="deploy"
YES=0
NO_START=0

CLI_PROVIDER=""
CLI_VERSION=""
CLI_ADDRESS=""
CLI_WORKER=""
CLI_POOL=""

INHERITED_PROVIDER="${PEARL_MINER_PROVIDER:-}"
INHERITED_VERSION="${PEARL_MINER_VERSION:-}"
INHERITED_BIN="${PEARL_MINER_BIN:-}"
INHERITED_POOL="${PEARL_MINER_POOL:-}"
INHERITED_ADDRESS="${PEARL_MINER_ADDRESS:-}"
INHERITED_WORKER="${PEARL_MINER_WORKER:-}"
INHERITED_LOG="${PEARL_MINER_LOG:-}"

PEARLHASH_ENDPOINTS=(
  "EU/US|84.32.220.219|9000"
  "Asia|129.226.55.135|9000"
)

VERSION_ROWS=()
VERSION_TAGS=()
VERSION_PRERELEASES=()
VERSION_PUBLISHED=()
VERSION_NAMES=()

PEARL_MINER_DOWNLOAD_URL=""
PEARL_MINER_DOWNLOAD_SHA256=""

usage() {
  cat <<'EOF'
PRL miner one-click deploy script

Usage:
  ./deploy_miner.sh [options]

Options:
      --provider NAME     Mining provider: alphapool or pearlhash.
      --version TAG       Use a specific AlphaPool release tag. For PearlHash, assert latest URL version.
      --address ADDRESS   Pearl/PRL address, for example prl1p...
      --worker NAME       Worker name, for example rig01.
      --pool HOST:PORT    Mining pool endpoint. Skips automatic pool selection.
      --yes               Non-interactive mode. Missing PRL address fails.
      --no-start          Install and save config, but do not start miner.
      --status            Show service/supervisor status and recent logs.
      --stop              Stop miner services and matching processes.
  -h, --help              Show this help.

Deployment layout:
  /opt/pearl-miner/versions/<provider>-<version>/
  /opt/pearl-miner/current
  /etc/pearl-miner/miner.env
  /pearl-miner.log

CUDA compatibility:
  Runs scripts/fix-cuda-forward-compat.sh before starting the miner when present.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      CLI_PROVIDER="$2"
      shift 2
      ;;
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

  if [[ -f "$PEARLHASH_URL_SCRIPT" ]] && ! command -v curl >/dev/null 2>&1; then
    printf 'Missing required command for PearlHash URL helper: curl\n' >&2
    missing=1
  fi

  alphapool_require_network_tools || missing=1

  if [[ -f "$CUDA_FIX_SCRIPT" ]]; then
    for tool in ldconfig paste tr mv head; do
      if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Missing required command for CUDA compatibility fix: %s\n' "$tool" >&2
        missing=1
      fi
    done
  fi

  return "$missing"
}

load_persisted_env() {
  local key value
  local loaded_new=0

  if [[ -r "$ENV_FILE" ]]; then
    loaded_new=1
    while IFS='=' read -r key value; do
      [[ -n "$key" && "$key" != \#* ]] || continue
      case "$key" in
        PEARL_MINER_PROVIDER) PEARL_MINER_PROVIDER="$value" ;;
        PEARL_MINER_VERSION) PEARL_MINER_VERSION="$value" ;;
        PEARL_MINER_BIN) PEARL_MINER_BIN="$value" ;;
        PEARL_MINER_POOL) PEARL_MINER_POOL="$value" ;;
        PEARL_MINER_ADDRESS) PEARL_MINER_ADDRESS="$value" ;;
        PEARL_MINER_WORKER) PEARL_MINER_WORKER="$value" ;;
        PEARL_MINER_LOG) PEARL_MINER_LOG="$value" ;;
      esac
    done < "$ENV_FILE"
  fi

  if [[ "$loaded_new" -eq 0 && -r "$OLD_ENV_FILE" ]]; then
    while IFS='=' read -r key value; do
      [[ -n "$key" && "$key" != \#* ]] || continue
      case "$key" in
        ALPHAPOOL_VERSION) PEARL_MINER_VERSION="${PEARL_MINER_VERSION:-$value}" ;;
        ALPHAPOOL_POOL) PEARL_MINER_POOL="${PEARL_MINER_POOL:-$value}" ;;
        ALPHAPOOL_ADDRESS) PEARL_MINER_ADDRESS="${PEARL_MINER_ADDRESS:-$value}" ;;
        ALPHAPOOL_WORKER) PEARL_MINER_WORKER="${PEARL_MINER_WORKER:-$value}" ;;
      esac
    done < "$OLD_ENV_FILE"
    PEARL_MINER_PROVIDER="${PEARL_MINER_PROVIDER:-alphapool}"
  fi

  [[ -n "$INHERITED_PROVIDER" ]] && PEARL_MINER_PROVIDER="$INHERITED_PROVIDER"
  [[ -n "$INHERITED_VERSION" ]] && PEARL_MINER_VERSION="$INHERITED_VERSION"
  [[ -n "$INHERITED_BIN" ]] && PEARL_MINER_BIN="$INHERITED_BIN"
  [[ -n "$INHERITED_POOL" ]] && PEARL_MINER_POOL="$INHERITED_POOL"
  [[ -n "$INHERITED_ADDRESS" ]] && PEARL_MINER_ADDRESS="$INHERITED_ADDRESS"
  [[ -n "$INHERITED_WORKER" ]] && PEARL_MINER_WORKER="$INHERITED_WORKER"
  [[ -n "$INHERITED_LOG" ]] && PEARL_MINER_LOG="$INHERITED_LOG"

  [[ -n "$CLI_VERSION" ]] && PEARL_MINER_VERSION="$CLI_VERSION"
  [[ -n "$CLI_POOL" ]] && PEARL_MINER_POOL="$CLI_POOL"
  [[ -n "$CLI_ADDRESS" ]] && PEARL_MINER_ADDRESS="$CLI_ADDRESS"
  [[ -n "$CLI_WORKER" ]] && PEARL_MINER_WORKER="$CLI_WORKER"
  PEARL_MINER_LOG="${PEARL_MINER_LOG:-$LOG_FILE}"
}

valid_provider() {
  [[ "$1" == "alphapool" || "$1" == "pearlhash" ]]
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

select_provider() {
  local selected choice default_provider previous_provider

  previous_provider="${PEARL_MINER_PROVIDER:-}"
  if [[ -n "$CLI_PROVIDER" ]]; then
    valid_provider "$CLI_PROVIDER" || die "Invalid provider: $CLI_PROVIDER"
    PEARL_MINER_PROVIDER="$CLI_PROVIDER"
    if [[ -n "$previous_provider" && "$previous_provider" != "$PEARL_MINER_PROVIDER" ]]; then
      PEARL_MINER_VERSION=""
      PEARL_MINER_BIN=""
      [[ -z "$CLI_POOL" ]] && PEARL_MINER_POOL=""
    fi
    return 0
  fi

  default_provider="${PEARL_MINER_PROVIDER:-alphapool}"
  valid_provider "$default_provider" || die "Invalid saved provider: $default_provider"

  if [[ "$YES" -eq 1 || ! -t 0 ]]; then
    PEARL_MINER_PROVIDER="$default_provider"
    return 0
  fi

  printf '\nAvailable mining providers:\n' >&2
  printf '  1) alphapool   AlphaPool stratum pool\n' >&2
  printf '  2) pearlhash   PearlHash pool\n' >&2
  printf 'Select provider [%s]: ' "$default_provider" >&2
  IFS= read -r choice

  case "$choice" in
    "") selected="$default_provider" ;;
    1|alphapool|AlphaPool|ALPHAPOOL) selected="alphapool" ;;
    2|pearlhash|PearlHash|PEARLHASH) selected="pearlhash" ;;
    *) die "Invalid provider selection: $choice" ;;
  esac

  PEARL_MINER_PROVIDER="$selected"
  if [[ -n "$previous_provider" && "$previous_provider" != "$PEARL_MINER_PROVIDER" ]]; then
    PEARL_MINER_VERSION=""
    PEARL_MINER_BIN=""
    [[ -z "$CLI_POOL" ]] && PEARL_MINER_POOL=""
  fi
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
  if http_get_to_file "${ALPHA_GITHUB_API}/releases?per_page=50" "$tmp"; then
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
    http_get_to_file "${ALPHA_GITHUB_API}/tags?per_page=50" "$tmp" || {
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

  if [[ "$PEARL_MINER_PROVIDER" == "pearlhash" ]]; then
    select_pearlhash_version
    return 0
  fi

  load_versions

  default_version="${PEARL_MINER_VERSION:-}"
  if [[ -z "$default_version" ]] || ! tag_in_version_list "$default_version"; then
    default_version="$(latest_stable_version)"
  fi

  if [[ -n "$CLI_VERSION" ]]; then
    valid_tag "$CLI_VERSION" || die "Invalid version tag: $CLI_VERSION"
    PEARL_MINER_VERSION="$CLI_VERSION"
    return 0
  fi

  if [[ "$YES" -eq 1 || ! -t 0 ]]; then
    PEARL_MINER_VERSION="$default_version"
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
  PEARL_MINER_VERSION="$selected"
}

parse_pearlhash_version_from_url() {
  local url="$1"
  local version

  version="$(printf '%s' "$url" | sed -n 's/^.*pearl-miner-v\([0-9][0-9]*\).*$/v\1/p')"
  [[ -n "$version" ]] || return 1
  printf '%s' "$version"
}

select_pearlhash_version() {
  local url version

  [[ -x "$PEARLHASH_URL_SCRIPT" || -f "$PEARLHASH_URL_SCRIPT" ]] || die "PearlHash URL helper not found: $PEARLHASH_URL_SCRIPT"
  url="$(bash "$PEARLHASH_URL_SCRIPT" check)" || die "Could not get PearlHash miner download URL."
  version="$(parse_pearlhash_version_from_url "$url")" || die "Could not parse PearlHash miner version from URL: $url"

  if [[ -n "$CLI_VERSION" && "$CLI_VERSION" != "$version" ]]; then
    die "PearlHash only exposes latest $version, but --version requested $CLI_VERSION."
  fi

  PEARL_MINER_DOWNLOAD_URL="$url"
  PEARL_MINER_VERSION="$version"
  log_ok "PearlHash miner latest version: $version"
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
  http_get_to_file "${ALPHA_GITHUB_API}/releases/tags/${tag}" "$tmp" || {
    rm -f "$tmp"
    die "Could not fetch GitHub release for tag $tag. The tag may not have release assets."
  }

  info="$(parse_asset_info_json < "$tmp" || true)"
  rm -f "$tmp"

  IFS=$'\t' read -r url digest <<< "$info"
  [[ -n "$url" ]] || die "Release $tag does not contain a Linux asset named exactly 'alpha-miner'."

  PEARL_MINER_DOWNLOAD_URL="$url"
  PEARL_MINER_DOWNLOAD_SHA256="$digest"
}

download_and_install_miner() {
  local tag="$1"
  local version_dir="$VERSIONS_DIR/${PEARL_MINER_PROVIDER}-${tag}"
  local tmp_bin actual_sha expected_sha
  local installed_name

  if [[ "$PEARL_MINER_PROVIDER" == "alphapool" ]]; then
    get_release_asset_info "$tag"
    installed_name="alpha-miner"
    log_info "Downloading AlphaPool alpha-miner $tag"
  else
    [[ -n "$PEARL_MINER_DOWNLOAD_URL" ]] || select_pearlhash_version
    PEARL_MINER_DOWNLOAD_SHA256=""
    installed_name="pearl-miner"
    log_info "Downloading PearlHash pearl-miner $tag"
  fi

  tmp_bin="$(mktemp)"
  http_get_to_file "$PEARL_MINER_DOWNLOAD_URL" "$tmp_bin" || {
    rm -f "$tmp_bin"
    die "Download failed: $PEARL_MINER_DOWNLOAD_URL"
  }

  if [[ -n "${PEARL_MINER_DOWNLOAD_SHA256:-}" ]]; then
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || {
      rm -f "$tmp_bin"
      die "Release provides SHA256 digest but neither sha256sum nor shasum is installed."
    }
    expected_sha="$(printf '%s' "$PEARL_MINER_DOWNLOAD_SHA256" | tr '[:upper:]' '[:lower:]')"
    actual_sha="$(sha256_file "$tmp_bin" | tr '[:upper:]' '[:lower:]')"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
      rm -f "$tmp_bin"
      die "SHA256 mismatch for $tag. expected=$expected_sha actual=$actual_sha"
    fi
    log_ok "SHA256 verified"
  else
    log_warn "No SHA256 digest is available for this miner download; continuing after URL validation."
  fi

  as_root mkdir -p "$version_dir"
  as_root install -m 0755 "$tmp_bin" "$version_dir/$installed_name"
  as_root ln -sfnT "$version_dir" "$CURRENT_LINK"
  rm -f "$tmp_bin"

  PEARL_MINER_BIN="$CURRENT_LINK/$installed_name"
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

: "\${PEARL_MINER_PROVIDER:?missing PEARL_MINER_PROVIDER}"
: "\${PEARL_MINER_BIN:?missing PEARL_MINER_BIN}"
: "\${PEARL_MINER_POOL:?missing PEARL_MINER_POOL}"
: "\${PEARL_MINER_ADDRESS:?missing PEARL_MINER_ADDRESS}"
: "\${PEARL_MINER_WORKER:?missing PEARL_MINER_WORKER}"
: "\${PEARL_MINER_LOG:?missing PEARL_MINER_LOG}"

cd "\$(dirname "\$PEARL_MINER_BIN")"
case "\$PEARL_MINER_PROVIDER" in
  alphapool)
    exec "\$PEARL_MINER_BIN" \\
      --pool "stratum+tcp://\${PEARL_MINER_POOL}" \\
      --address "\$PEARL_MINER_ADDRESS" \\
      --worker "\$PEARL_MINER_WORKER" >> "\$PEARL_MINER_LOG" 2>&1
    ;;
  pearlhash)
    exec "\$PEARL_MINER_BIN" \\
      --host "\$PEARL_MINER_POOL" \\
      --user "\$PEARL_MINER_ADDRESS" \\
      --worker "\$PEARL_MINER_WORKER" >> "\$PEARL_MINER_LOG" 2>&1
    ;;
  *)
    echo "Unsupported provider: \$PEARL_MINER_PROVIDER" >&2
    exit 2
    ;;
esac
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
    log_file="\${PEARL_MINER_LOG:-\$DEFAULT_LOG}"
  fi

  printf '[%s] supervisor starting miner\\n' "\$(date '+%Y-%m-%d %H:%M:%S %Z')" >> "\$log_file"
  "\$RUNNER"
  rc=\$?
  printf '[%s] miner exited rc=%s; restarting in 10s\\n' "\$(date '+%Y-%m-%d %H:%M:%S %Z')" "\$rc" >> "\$log_file"
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

  valid_provider "$PEARL_MINER_PROVIDER" || die "Invalid PEARL_MINER_PROVIDER: $PEARL_MINER_PROVIDER"
  valid_tag "$PEARL_MINER_VERSION" || die "Invalid PEARL_MINER_VERSION: $PEARL_MINER_VERSION"
  valid_pool "$PEARL_MINER_POOL" || die "Invalid PEARL_MINER_POOL: $PEARL_MINER_POOL"
  valid_prl_address "$PEARL_MINER_ADDRESS" || die "Invalid PEARL_MINER_ADDRESS. It must be non-empty, contain no spaces, and start with prl."
  valid_worker "$PEARL_MINER_WORKER" || die "Invalid PEARL_MINER_WORKER. It must be non-empty and contain no spaces."
  valid_abs_path "$PEARL_MINER_BIN" || die "Invalid PEARL_MINER_BIN path: $PEARL_MINER_BIN"
  valid_abs_path "$PEARL_MINER_LOG" || die "Invalid PEARL_MINER_LOG path: $PEARL_MINER_LOG"

  tmp_env="$(mktemp)"
  cat > "$tmp_env" <<EOF
PEARL_MINER_PROVIDER=$PEARL_MINER_PROVIDER
PEARL_MINER_VERSION=$PEARL_MINER_VERSION
PEARL_MINER_BIN=$PEARL_MINER_BIN
PEARL_MINER_POOL=$PEARL_MINER_POOL
PEARL_MINER_ADDRESS=$PEARL_MINER_ADDRESS
PEARL_MINER_WORKER=$PEARL_MINER_WORKER
PEARL_MINER_LOG=$PEARL_MINER_LOG
EOF

  as_root mkdir -p "$ENV_DIR"
  as_root install -m 0644 "$tmp_env" "$ENV_FILE"
  as_root touch "$PEARL_MINER_LOG"
  as_root chmod 0644 "$PEARL_MINER_LOG"
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

list_provider_pool_ports() {
  local item region host ports port

  case "$PEARL_MINER_PROVIDER" in
    alphapool)
      alphapool_list_pool_ports
      ;;
    pearlhash)
      pool_list_ports_from_entries "${PEARLHASH_ENDPOINTS[@]}"
      ;;
    *)
      die "Unsupported provider: $PEARL_MINER_PROVIDER"
      ;;
  esac
}

provider_display_name() {
  case "$PEARL_MINER_PROVIDER" in
    alphapool) printf 'AlphaPool' ;;
    pearlhash) printf 'PearlHash' ;;
    *) printf '%s' "$PEARL_MINER_PROVIDER" ;;
  esac
}

provider_fallback_pool() {
  case "$PEARL_MINER_PROVIDER" in
    alphapool) printf 'us2.alphapool.tech:5566' ;;
    pearlhash) printf '129.226.55.135:9000' ;;
    *) return 1 ;;
  esac
}

detect_best_pool() {
  local rows=()
  local region host port line best
  local best_region best_host best_port best_attempts best_success best_success_rate best_loss best_min best_avg best_max best_jitter best_status best_score
  local provider_name fallback_pool

  provider_name="$(provider_display_name)"
  log_info "Testing $provider_name endpoints on configured mining ports"
  while IFS=$'\t' read -r region host port; do
    line="$(pool_test_endpoint_tsv "$region" "$host" "$port" 5 3)"
    rows+=("$line")
  done < <(list_provider_pool_ports)

  print_pool_table rows >&2
  best="$(printf '%s\n' "${rows[@]}" | pool_best_result_from_tsv || true)"

  if [[ -z "$best" ]]; then
    fallback_pool="$(provider_fallback_pool)"
    log_warn "No reachable $provider_name endpoint was found; using fallback $fallback_pool."
    printf '%s' "$fallback_pool"
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
    PEARL_MINER_POOL="$CLI_POOL"
    return 0
  fi

  detected_pool="$(detect_best_pool)"
  default_pool="${PEARL_MINER_POOL:-$detected_pool}"

  if [[ -n "${PEARL_MINER_POOL:-}" && "$PEARL_MINER_POOL" != "$detected_pool" ]]; then
    log_info "Saved pool: $PEARL_MINER_POOL; fastest now: $detected_pool"
  fi

  selected_pool="$(prompt_value "Pool endpoint" "$default_pool")"
  valid_pool "$selected_pool" || die "Invalid pool endpoint: $selected_pool"
  PEARL_MINER_POOL="$selected_pool"
}

select_address() {
  local selected

  selected="$(prompt_value "Pearl/PRL address" "${PEARL_MINER_ADDRESS:-}")"
  valid_prl_address "$selected" || die "Invalid Pearl/PRL address. It must start with prl and contain no spaces."
  PEARL_MINER_ADDRESS="$selected"
}

select_worker() {
  local default_worker selected

  default_worker="${PEARL_MINER_WORKER:-$(sanitize_worker_default)}"
  selected="$(prompt_value "Worker name" "$default_worker")"
  valid_worker "$selected" || die "Invalid worker name. It must be non-empty and contain no spaces."
  PEARL_MINER_WORKER="$selected"
}

find_miner_pids() {
  ps -eo pid=,comm=,args= 2>/dev/null | awk -v self="$$" -v supervisor="$SUPERVISOR_PATH" '
    {
      pid=$1
      comm=$2
      $1=""
      $2=""
      cmd=$0
      if (pid != self &&
          (comm ~ /^alpha-miner/ ||
           comm == "pearl-miner" ||
           cmd ~ /(^|[ /])alpha-miner[^ /]*( |$)/ ||
           cmd ~ /(^|[ /])pearl-miner( |$)/ ||
           index(cmd, supervisor) > 0) &&
          cmd !~ /deploy_miner.sh/ &&
          cmd !~ /check_pool_latency.sh/ &&
          cmd !~ /get-pearlhash-miner-url.sh/ &&
          cmd !~ /awk -v self=/) {
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
    as_root systemctl stop "$OLD_SERVICE_NAME" >/dev/null 2>&1 || true
  fi
}

stop_existing_miner() {
  local pids=()
  local alive=()
  local pid i

  log_info "Stopping existing miner services/processes if present"
  stop_systemd_service

  mapfile -t pids < <(find_miner_pids)
  if [[ "${#pids[@]}" -eq 0 ]]; then
    log_ok "No running miner process found"
    return 0
  fi

  log_info "Sending TERM to miner PIDs: ${pids[*]}"
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
    log_warn "Forcing miner PIDs: ${alive[*]}"
    as_root kill -KILL "${alive[@]}" >/dev/null 2>&1 || true
  fi

  log_ok "Old miner processes stopped"
}

run_cuda_forward_compat_fix() {
  if [[ ! -f "$CUDA_FIX_SCRIPT" ]]; then
    log_warn "CUDA forward compatibility fix script not found, skipping: $CUDA_FIX_SCRIPT"
    return 0
  fi

  log_info "Running CUDA forward compatibility fix before starting miner"
  as_root bash "$CUDA_FIX_SCRIPT"
  log_ok "CUDA forward compatibility fix completed"
}

install_systemd_service() {
  local tmp_service

  tmp_service="$(mktemp)"
  cat > "$tmp_service" <<EOF
[Unit]
Description=PRL Miner
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

  printf 'PRL miner deploy script v%s\n' "$VERSION"
  printf 'Config: %s\n' "$ENV_FILE"
  printf 'Provider: %s\n' "${PEARL_MINER_PROVIDER:-N/A}"
  printf 'Version: %s\n' "${PEARL_MINER_VERSION:-N/A}"
  printf 'Binary: %s\n' "${PEARL_MINER_BIN:-N/A}"
  printf 'Pool: %s\n' "${PEARL_MINER_POOL:-N/A}"
  printf 'Worker: %s\n' "${PEARL_MINER_WORKER:-N/A}"
  printf 'Log: %s\n' "${PEARL_MINER_LOG:-$LOG_FILE}"
  printf '\n'

  if command -v systemctl >/dev/null 2>&1 && [[ -f "$SERVICE_PATH" ]]; then
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    printf '\n'
  fi

  if [[ -r "$PID_FILE" ]]; then
    printf 'Fallback supervisor PID file: %s -> %s\n' "$PID_FILE" "$(cat "$PID_FILE" 2>/dev/null || true)"
  fi

  pids="$(find_miner_pids | tr '\n' ' ')"
  if [[ -n "$pids" ]]; then
    printf 'Matching miner PIDs: %s\n' "$pids"
  else
    printf 'Matching miner PIDs: none\n'
  fi

  printf '\nRecent log lines:\n'
  if [[ -r "${PEARL_MINER_LOG:-$LOG_FILE}" ]]; then
    tail -n 40 "${PEARL_MINER_LOG:-$LOG_FILE}" || true
  else
    printf 'Log file is not readable: %s\n' "${PEARL_MINER_LOG:-$LOG_FILE}"
  fi
}

deploy() {
  require_deploy_tools || die "Missing required tools."
  ensure_root_access
  load_persisted_env

  select_provider
  select_version
  select_address
  select_worker
  select_pool

  download_and_install_miner "$PEARL_MINER_VERSION"
  write_runtime_scripts
  write_env_file
  stop_existing_miner

  if [[ "$NO_START" -eq 1 ]]; then
    log_ok "Installed and saved config. Miner was not started because --no-start was set."
  else
    run_cuda_forward_compat_fix
    start_miner
  fi

  printf '\nDeployment summary:\n'
  printf '  Provider: %s\n' "$PEARL_MINER_PROVIDER"
  printf '  Version:  %s\n' "$PEARL_MINER_VERSION"
  printf '  Binary:   %s\n' "$PEARL_MINER_BIN"
  printf '  Pool:     %s\n' "$PEARL_MINER_POOL"
  printf '  Worker:   %s\n' "$PEARL_MINER_WORKER"
  printf '  Log:      %s\n' "$PEARL_MINER_LOG"
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
