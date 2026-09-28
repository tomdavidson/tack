#!/usr/bin/env bash
#
# Shared shell library for tack drupal scripts. Source it, don't run it:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/env.sh"
#
# Provides:
#   REPO_ROOT           repository root, derived from this file's location
#   APP_ROOT            Drupal application root (defaults to REPO_ROOT).
#                       Set APP_ROOT in the environment or devenv.nix when
#                       Drupal lives in a subdirectory (e.g. apps/hub).
#   log / die           prefixed stderr logging; die exits 1
#   env_require VAR...  fail listing every missing variable
#   env_shim            map AWS_*/BUCKET_NAME onto neutral S3_* names
#   wait_for NAME TIMEOUT_S CMD...   bounded readiness loop

if [[ -n "${TACK_ENV_SH_LOADED:-}" ]]; then
  return 0
fi
readonly TACK_ENV_SH_LOADED=1

TACK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${TACK_LIB_DIR}/../.." && pwd)}"
# APP_ROOT: Drupal application root. Defaults to REPO_ROOT so consumers
# with Drupal at the repo root require no change. Consumers that place
# Drupal in a subdirectory (e.g. apps/hub) set this before sourcing.
APP_ROOT="${APP_ROOT:-${REPO_ROOT}}"
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "${0}" .sh)}"
readonly TACK_LIB_DIR REPO_ROOT APP_ROOT SCRIPT_NAME

export PATH="${APP_ROOT}/vendor/bin:${PATH}"

# If devenv recorded an allocated database port, adopt it so scripts and Drush
# always connect to the active port rather than an out-of-date static default.
if [[ -n "${DEVENV_STATE:-}" && -f "${DEVENV_STATE}/db.port" ]]; then
  DB_PORT="$(cat "${DEVENV_STATE}/db.port")"
  export DB_PORT
fi

log() { printf '[%s] %s\n' "${SCRIPT_NAME}" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Collects every unset/empty variable and reports them together.
env_require() {
  local name missing=()
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || missing+=("${name}")
  done
  (( ${#missing[@]} == 0 )) || die "Required environment variables not set: ${missing[*]}"
}

# Map provider-specific AWS_*/BUCKET_NAME env vars onto neutral S3_* names.
# Allows scripts to work with Tigris, Fly Storage, or any S3-compatible
# provider without changing the env contract.
env_shim() {
  env_shim_one S3_ENDPOINT    AWS_ENDPOINT_URL_S3
  env_shim_one S3_ACCESS_KEY  AWS_ACCESS_KEY_ID
  env_shim_one S3_SECRET_KEY  AWS_SECRET_ACCESS_KEY
  env_shim_one S3_REGION      AWS_REGION
  env_shim_one S3_BUCKET      BUCKET_NAME
}

env_shim_one() {
  local target="$1" legacy="$2"
  if [[ -z "${!target:-}" && -n "${!legacy:-}" ]]; then
    export "${target}=${!legacy}"
    log "deprecated: ${target} taken from ${legacy}; set ${target} directly."
  fi
}

# wait_for NAME TIMEOUT_S CMD...  Retries CMD once a second until it exits 0.
wait_for() {
  local name="$1" timeout="$2" elapsed=0
  shift 2
  until "$@" >/dev/null 2>&1; do
    (( elapsed < timeout )) || die "${name} not ready after ${timeout}s"
    sleep 1
    elapsed=$((elapsed + 1))
  done
  log "${name} ready."
}
