#!/usr/bin/env bash
#
# Dump the MariaDB database and upload it to the backup bucket.
#
# Used by:
#   - the web image's scripts/release.sh (pre-deploy backup, label "predeploy")
#   - the cron app's crontab (nightly backup, label "nightly")
#
# Dependencies: mariadb-dump, gzip, curl >= 7.75 (SigV4 support). No vendor CLI.
#
# Env (required): DB_HOST DB_NAME DB_USER DB_PASSWORD
#                 BACKUP_BUCKET S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY
# Env (optional): DB_PORT (3306)  BACKUP_PREFIX (<app-name>-db)  S3_REGION (auto)
# Legacy AWS_* / BUCKET_NAME values set by `fly storage create` are accepted
# through env_shim in scripts/lib/env.sh.
#
# Delivered by configs/drupal (tack-owned: overwrite: false).

set -euo pipefail
# shellcheck source=scripts/lib/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/env.sh"

readonly LABEL="${1:-manual}"
readonly BACKUP_PREFIX="${BACKUP_PREFIX:-${APP_NAME:-drupal}-db}"

build_object_key() {
  local label="$1" stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  printf '%s/%s/%s-%s.sql.gz' "${BACKUP_PREFIX}" "${label}" "${stamp}" "${label}"
}

dump_database() {
  local target="$1"
  MYSQL_PWD="${DB_PASSWORD}" mariadb-dump \
    --host="${DB_HOST}" --port="${DB_PORT:-3306}" --user="${DB_USER}" \
    --single-transaction --quick --routines --triggers --events \
    --skip-lock-tables --default-character-set=utf8mb4 \
    "${DB_NAME}" | gzip -6 > "${target}"
}

upload_to_bucket() {
  local source="$1" key="$2"
  curl -fsS --retry 3 --retry-delay 5 \
    --aws-sigv4 "aws:amz:${S3_REGION:-auto}:s3" \
    --user "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
    --upload-file "${source}" \
    --header "Content-Type: application/gzip" \
    "${S3_ENDPOINT%/}/${BACKUP_BUCKET}/${key}" \
    --output /dev/null
}

main() {
  env_shim
  env_require DB_HOST DB_NAME DB_USER DB_PASSWORD \
    BACKUP_BUCKET S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY

  local workdir key dumpfile size
  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir}"' EXIT

  key="$(build_object_key "${LABEL}")"
  dumpfile="${workdir}/dump.sql.gz"

  log "Dumping ${DB_NAME}@${DB_HOST} (${LABEL})."
  dump_database "${dumpfile}"
  size="$(stat -c %s "${dumpfile}")"
  [[ "${size}" -gt 1024 ]] || die "Dump is suspiciously small (${size} bytes); refusing to upload."

  log "Uploading ${size} bytes to ${BACKUP_BUCKET}/${key}."
  upload_to_bucket "${dumpfile}" "${key}"
  log "Backup complete: s3://${BACKUP_BUCKET}/${key}"
}

main "$@"
