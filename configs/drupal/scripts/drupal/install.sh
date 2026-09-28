#!/usr/bin/env bash
#
# The one way Drupal gets installed in this project (devenv, CI, Fly first
# deploy): from the committed config/sync export.
#
#   install.sh            install if the database is empty or half-installed,
#                         then deploy + drift gate
#   install.sh --force    drop and reinstall (refused when APP_ENV=production)
#
# After install and before deploy, scripts/drupal/post-install.sh is called if
# it exists. Use this for project-specific setup: role grants, demo modules,
# fixture imports, etc.
#
# Steps:
#   1. refuse an export that enables a dev-only module
#   2. detect database state: empty | partial | installed
#   3. partial (non-production) or --force: drop all tables
#   4. drush site:install --existing-config (seeds domain records, sets admin password)
#   5. scripts/drupal/post-install.sh (if present — project-specific hook)
#   6. scripts/drupal/deploy.sh (updatedb, cim, cr, cron key, drift gate)
#   7. drush s3fs:refresh-cache (warning only)
#
# Already installed and no --force: runs steps 6 and 7 only. Idempotent.
# Half-installed in production: refuses to drop; inspect by hand.
#
# Env (required): HASH_SALT DB_HOST DB_NAME DB_USER DB_PASSWORD PLATFORM_HOST
#                 TRUSTED_HOSTS S3_BUCKET S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY
# Env (optional): PLATFORM_URI APP_ENV DB_PORT CRON_KEY DRUPAL_ADMIN_PASSWORD
#                 DRUPAL_INSTALL_LOG APP_ROOT

set -euo pipefail
# shellcheck source=scripts/lib/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/env.sh"
# shellcheck source=scripts/lib/drupal.sh
source "${TACK_LIB_DIR}/drupal.sh"

readonly DEPLOY_SCRIPT="${TACK_LIB_DIR}/../drupal/deploy.sh"
# POST_INSTALL_SCRIPT is app-relative: variants place it under
# APP_ROOT/scripts/drupal/post-install.sh via tack's path_prefix.
readonly POST_INSTALL_SCRIPT="${APP_ROOT}/scripts/drupal/post-install.sh"
readonly APP_ENV="${APP_ENV:-production}"
readonly INSTALL_LOG="${DRUPAL_INSTALL_LOG:-${DEVENV_STATE:-/tmp}/drupal-install.log}"

FORCE=0

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --force) FORCE=1 ;;
      -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
      *) die "Unknown argument: ${arg}" ;;
    esac
  done
  readonly FORCE
}

resolve_db_port() {
  if [[ -n "${DEVENV_STATE:-}" && -f "${DEVENV_STATE}/db.port" ]]; then
    cat "${DEVENV_STATE}/db.port"
  elif [[ -n "${DB_PORT:-}" ]]; then
    printf '%s' "${DB_PORT}"
  else
    printf '3306'
  fi
}

# The URI seeds domain.record.default, so it must carry the port the web
# server actually listens on.
resolve_platform_uri() {
  if [[ -n "${DEVENV_STATE:-}" && -f "${DEVENV_STATE}/web.port" ]]; then
    printf 'http://%s:%s' "${PLATFORM_HOST}" "$(cat "${DEVENV_STATE}/web.port")"
  else
    printf '%s' "${PLATFORM_URI:-https://${PLATFORM_HOST}}"
  fi
}

db_exec() {
  local port
  port="$(resolve_db_port)"
  MYSQL_PWD="${DB_PASSWORD}" mariadb --protocol=TCP --host="${DB_HOST}" --port="${port}" \
    --user="${DB_USER}" --batch --skip-column-names --execute="$1" "${DB_NAME}"
}

database_is_reachable() { db_exec 'SELECT 1' >/dev/null; }

export_profile() {
  sed -n 's/^profile:[[:space:]]*//p' "${CORE_EXTENSION_FILE}" | tr -d "'\"[:space:]"
}

# Prints: empty | partial | installed
site_state() {
  local tables modules profile
  tables="$(db_exec 'SHOW TABLES' | wc -l)"
  if (( tables == 0 )); then
    echo empty
    return
  fi
  profile="$(export_profile)"
  modules="$(drush config:get core.extension module --format=yaml 2>/dev/null || true)"
  if [[ -n "${profile}" ]] \
     && grep -qE "^[[:space:]]*${profile}:" <<<"${modules}" \
     && grep -qE '^[[:space:]]*user:' <<<"${modules}"; then
    echo installed
  else
    echo partial
  fi
}

drop_database() {
  log "Dropping all tables in ${DB_NAME}@${DB_HOST}."
  drush sql:drop -y
}

# Run install without PHP memory/time limits — large module sets (e.g.
# LocalGov Microsites) can exhaust defaults and die silently part-way.
drush_unlimited() {
  php -d memory_limit=-1 -d max_execution_time=0 "${APP_ROOT}/vendor/bin/drush.php" "$@"
}

install_from_config() {
  local uri profile
  uri="$(resolve_platform_uri)"
  local args=(--existing-config -y -v --account-name=admin --uri="${uri}")
  [[ -n "${DRUPAL_ADMIN_PASSWORD:-}" ]] && args+=(--account-pass="${DRUPAL_ADMIN_PASSWORD}")

  has_exported_config \
    || die "${CONFIG_SYNC_DIR} has no exported config. Export it (drush cex) and commit it before installing."
  profile="$(export_profile)"
  [[ -n "${profile}" ]] || die "No profile: key in ${CORE_EXTENSION_FILE}."

  mkdir -p "$(dirname "${INSTALL_LOG}")"
  log "Installing ${profile} from config/sync with --uri=${uri} (log: ${INSTALL_LOG})."
  if ! drush_unlimited site:install "${args[@]}" >"${INSTALL_LOG}" 2>&1; then
    tail -n 40 "${INSTALL_LOG}" >&2
    die "drush site:install failed; full log in ${INSTALL_LOG}."
  fi

  if [[ "$(site_state)" != installed ]]; then
    tail -n 40 "${INSTALL_LOG}" >&2
    die "site:install exited 0 but ${profile} is not enabled; see ${INSTALL_LOG}."
  fi
  log "Install verified: ${profile} enabled."
}

run_post_install_hook() {
  if [[ -x "${POST_INSTALL_SCRIPT}" ]]; then
    log "Running post-install hook: ${POST_INSTALL_SCRIPT#"${APP_ROOT}"/}"
    "${POST_INSTALL_SCRIPT}"
  fi
}

refresh_s3fs_cache() {
  if drush s3fs:refresh-cache; then
    log "s3fs metadata cache refreshed."
  else
    log "WARNING: s3fs:refresh-cache failed; check S3_ENDPOINT and the bucket."
  fi
}

main() {
  local state

  parse_args "$@"
  cd "${APP_ROOT}"
  env_shim
  env_require HASH_SALT DB_HOST DB_NAME DB_USER DB_PASSWORD PLATFORM_HOST TRUSTED_HOSTS \
    S3_BUCKET S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY

  refuse_dev_only_modules_in_export
  wait_for "database ${DB_NAME}@${DB_HOST}" 60 database_is_reachable

  if (( FORCE )) && [[ "${APP_ENV}" == "production" ]]; then
    die "--force is refused when APP_ENV=production."
  fi

  state="$(site_state)"
  log "Database state: ${state} (APP_ENV=${APP_ENV})."

  if (( FORCE )); then
    drop_database
    install_from_config
    run_post_install_hook
  else
    case "${state}" in
      installed)
        log "Drupal already installed; running the deploy path."
        ;;
      partial)
        [[ "${APP_ENV}" == "production" ]] \
          && die "Half-installed in production; refusing to drop ${DB_NAME} automatically."
        log "Half-installed site detected; dropping and reinstalling."
        drop_database
        install_from_config
        run_post_install_hook
        ;;
      empty)
        install_from_config
        run_post_install_hook
        ;;
      *) die "Unexpected database state: ${state}" ;;
    esac
  fi

  "${DEPLOY_SCRIPT}"
  refresh_s3fs_cache
  log "Install complete."
}

main "$@"
