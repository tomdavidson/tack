#!/usr/bin/env bash
#
# Bring an installed Drupal site up to date with the code and config in this
# checkout: database updates, config import, cache rebuild, deploy hooks,
# cron key sync, then the zero-drift gate.
#
# Called by scripts/drupal/install.sh and the devenv task drupal:deploy.
# On Fly, also called by scripts/release.sh as the release_command.
# Non-zero exit blocks a Fly rollout.
#
# Env (required): HASH_SALT DB_HOST DB_NAME DB_USER DB_PASSWORD TRUSTED_HOSTS
#                 S3_BUCKET S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY
# Env (optional): CRON_KEY, APP_ENV

set -euo pipefail
# shellcheck source=scripts/lib/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/env.sh"
# shellcheck source=scripts/lib/drupal.sh
source "${TACK_LIB_DIR}/drupal.sh"

main() {
  cd "${REPO_ROOT}"
  env_shim
  env_require HASH_SALT DB_HOST DB_NAME DB_USER DB_PASSWORD TRUSTED_HOSTS \
    S3_BUCKET S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY

  has_exported_config || die "Refusing to run config:import with an empty ${CONFIG_SYNC_DIR}."
  refuse_dev_only_modules_in_export
  is_site_installed   || die "Drupal is not installed; run scripts/drupal/install.sh first."

  log "Running updatedb, config:import, cache:rebuild and deploy hooks."
  drush deploy -y
  sync_cron_key
  gate_config_status
  log "Deploy steps complete."
}

main "$@"
