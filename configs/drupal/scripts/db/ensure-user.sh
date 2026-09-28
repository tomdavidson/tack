#!/usr/bin/env bash
#
# Create the application database and user, and grant privileges. Idempotent.
#
# Why this exists: devenv's services.mysql.ensureUsers runs as a task that is
# downstream of the mysql process, and `devenv up` schedules processes in
# "before" mode, so that task never runs (cachix/devenv#2852). The symptom is
# "Access denied for user 'drupal'@'localhost'". This script does the same job
# explicitly and is wired as the db:user task in devenv.nix.
#
# Not used on Fly: the database app provisions the account.
#
# Env (required): DB_NAME DB_USER DB_PASSWORD
# Env (optional): DB_HOST (127.0.0.1) DB_PORT (3306) DB_ROOT_USER (root)
#                 DB_ROOT_PASSWORD (empty) MYSQL_UNIX_PORT (socket; preferred when present)

set -euo pipefail
# shellcheck source=scripts/lib/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/env.sh"

readonly DB_HOST="${DB_HOST:-127.0.0.1}"
readonly DB_ROOT_USER="${DB_ROOT_USER:-root}"
readonly USER_HOSTS=(localhost 127.0.0.1 '%')

# Resolve DB_PORT dynamically: check $DEVENV_STATE/db.port first,
# fallback to $DB_PORT env var, then 3306.
resolve_db_port() {
  if [[ -n "${DEVENV_STATE:-}" && -f "${DEVENV_STATE}/db.port" ]]; then
    cat "${DEVENV_STATE}/db.port"
  elif [[ -n "${DB_PORT:-}" ]]; then
    printf '%s' "${DB_PORT}"
  else
    printf '3306'
  fi
}

admin_sql() {
  local port
  port="$(resolve_db_port)"
  if [[ -n "${MYSQL_UNIX_PORT:-}" && -S "${MYSQL_UNIX_PORT}" ]]; then
    MYSQL_PWD="${DB_ROOT_PASSWORD:-}" mariadb --socket="${MYSQL_UNIX_PORT}" \
      --user="${DB_ROOT_USER}" --batch --skip-column-names "$@"
  else
    MYSQL_PWD="${DB_ROOT_PASSWORD:-}" mariadb --protocol=TCP --host="${DB_HOST}" --port="${port}" \
      --user="${DB_ROOT_USER}" --batch --skip-column-names "$@"
  fi
}

admin_ping() { admin_sql --execute='SELECT 1'; }

app_sql() {
  local port
  port="$(resolve_db_port)"
  MYSQL_PWD="${DB_PASSWORD}" mariadb --protocol=TCP --host="${DB_HOST}" --port="${port}" \
    --user="${DB_USER}" --batch --skip-column-names "${DB_NAME}" "$@"
}

app_ping() { app_sql --execute='SELECT 1'; }

ensure_user_statements() {
  local host
  # shellcheck disable=SC2016
  printf 'CREATE DATABASE IF NOT EXISTS `%s`;\n' "${DB_NAME}"
  for host in "${USER_HOSTS[@]}"; do
    printf "CREATE USER IF NOT EXISTS '%s'@'%s' IDENTIFIED BY '%s';\n" "${DB_USER}" "${host}" "${DB_PASSWORD}"
    printf "ALTER USER '%s'@'%s' IDENTIFIED BY '%s';\n"               "${DB_USER}" "${host}" "${DB_PASSWORD}"
    printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%s';\n"         "${DB_NAME}" "${DB_USER}" "${host}"
  done
  printf 'FLUSH PRIVILEGES;\n'
}

main() {
  env_require DB_NAME DB_USER DB_PASSWORD
  wait_for mariadb 60 admin_ping

  # Record the live port so install.sh and drush always hit the right socket.
  if [[ -n "${DEVENV_STATE:-}" ]]; then
    local live_port
    live_port="$(admin_sql --execute="SHOW VARIABLES LIKE 'port';" | awk '{print $2}' || true)"
    if [[ -n "${live_port}" ]]; then
      echo "${live_port}" > "${DEVENV_STATE}/db.port"
      log "Recorded active MariaDB port ${live_port} to ${DEVENV_STATE}/db.port"
    fi
  fi

  log "Ensuring database ${DB_NAME} and user ${DB_USER}@{${USER_HOSTS[*]}}."
  ensure_user_statements | admin_sql

  local port
  port="$(resolve_db_port)"
  wait_for "${DB_USER}@${DB_HOST}:${port}" 10 app_ping
}

main "$@"
