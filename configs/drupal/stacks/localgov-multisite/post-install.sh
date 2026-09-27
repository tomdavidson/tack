#!/usr/bin/env bash
#
# LocalGov Microsites post-install hook.
# Called by configs/drupal/scripts/drupal/install.sh after site:install
# succeeds, before deploy.sh runs.
#
# - Grants microsites_controller to admin (hook_install is patched out in this
#   profile, so the grant must happen explicitly after install).
# - Enables the demo module if LOCALGOV_DEMO=1 (set by drupal:setup task).
#
# Env (optional): LOCALGOV_DEMO (0)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib/env.sh"
source "${TACK_LIB_DIR}/drupal.sh"

log "Granting microsites_controller role to admin."
drush user:role:add microsites_controller admin

if [[ "${LOCALGOV_DEMO:-0}" == "1" ]]; then
  log "Enabling localgov_microsites_demo (LOCALGOV_DEMO=1)."
  drush pm:enable -y localgov_microsites_demo
  drush cache:rebuild
  log "Before exporting config: drush pm:uninstall -y localgov_microsites_demo && drush cex -y"
fi
