#!/usr/bin/env bash
#
# Drush helpers shared by configs/drupal/scripts/*.
# Source after lib/env.sh; do not run directly.
#
# DEV_ONLY_MODULES is intentionally empty here — stacks that need to guard
# against dev-only modules in the export should set it before sourcing this
# file, or extend it after sourcing:
#
#   DEV_ONLY_MODULES+=(my_demo_module)

if [[ -n "${TACK_DRUPAL_SH_LOADED:-}" ]]; then
  return 0
fi
readonly TACK_DRUPAL_SH_LOADED=1

readonly CONFIG_SYNC_DIR="${REPO_ROOT}/config/sync"
readonly CORE_EXTENSION_FILE="${CONFIG_SYNC_DIR}/core.extension.yml"

# Stacks extend this array before sourcing this lib, or after via +=.
DEV_ONLY_MODULES=()

drush() {
  "${REPO_ROOT}/vendor/bin/drush" --root="${REPO_ROOT}/web" --no-interaction "$@"
}

has_exported_config() { [[ -f "${CORE_EXTENSION_FILE}" ]]; }

is_site_installed() {
  local bootstrap
  bootstrap="$(drush core:status --fields=bootstrap --format=string 2>/dev/null || true)"
  [[ "${bootstrap}" == "Successful" ]]
}

# Refuse an export that enables a dev-only module — it would break config:import
# on any environment that does not ship that module (production, review apps).
refuse_dev_only_modules_in_export() {
  has_exported_config || return 0
  local module
  for module in "${DEV_ONLY_MODULES[@]:-}"; do
    if grep -qE "^\s+${module}:" "${CORE_EXTENSION_FILE}"; then
      die "${CORE_EXTENSION_FILE#"${REPO_ROOT}"/} enables ${module} (dev-only). Run: drush pm:uninstall -y ${module} && drush cex -y"
    fi
  done
}

# Any drift between the database and config/sync after an import means a
# missing export or missing config_ignore pattern. Both block a rollout.
gate_config_status() {
  local drift
  drift="$(drush config:status --format=list 2>/dev/null || true)"
  if [[ -n "${drift}" ]]; then
    log "Configuration drift after import:"
    printf '%s\n' "${drift}" >&2
    die "config:status is not clean. Export the change or add a config_ignore pattern."
  fi
  log "config:status clean."
}

# Sync CRON_KEY into Drupal's state so the cron endpoint matches the secret.
sync_cron_key() {
  if [[ -z "${CRON_KEY:-}" ]]; then
    log "CRON_KEY not set; leaving Drupal's generated cron key in place."
    return 0
  fi
  drush state:set system.cron_key "${CRON_KEY}" >/dev/null
  log "Cron key synced from CRON_KEY."
}
