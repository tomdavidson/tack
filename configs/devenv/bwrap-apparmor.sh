#!/usr/bin/env bash
# configs/devenv/bwrap-apparmor.sh
#
# bwrap-apparmor: manage the AppArmor profile that permits the exact bubblewrap
# binary bwrap-run uses to create unprivileged user namespaces.
#
# Ubuntu 23.10+ (and KDE Neon on a 24.04 base) set
# kernel.apparmor_restrict_unprivileged_userns=1, which blocks bwrap unless
# an AppArmor profile grants `userns`. Ubuntu ships no bwrap profile because
# bwrap can launch arbitrary programs inside a namespace; this helper writes
# a profile bound to ONE bwrap store path instead of a broad glob, so only
# the bubblewrap built alongside this script is allowed through.
#
# Commands:
#   check [--quiet]   report whether bwrap works; exit 1 if blocked.
#                     Never needs root. Used by devenv enterShell.
#   install           one-time sudo: write /etc/apparmor.d/bwrap-run-<hash>,
#                     load it, re-test. Skipped when bwrap already works.
#   prune             remove profiles whose bwrap path no longer exists
#                     (run after nix garbage collection).
#   uninstall         remove the profile for the current bwrap.
#   path              print the bwrap path this helper was built for.
#
# The profile must be re-installed whenever bubblewrap updates and its store
# path changes. `check` in enterShell tells you when that happens.
#
# sudo and apparmor_parser are used from the host on purpose: setuid sudo
# cannot come from the Nix store, and the parser must match the host
# kernel's AppArmor ABI.

set -euo pipefail

progname=${0##*/}

BWRAP="${BWRAP_BIN:-$(command -v bwrap || true)}"
if [ -z "$BWRAP" ]; then
  printf '%s: error: bwrap not found; set BWRAP_BIN or add bubblewrap to PATH\n' "$progname" >&2
  exit 1
fi
STORE_DIR=$(dirname "$(dirname "$BWRAP")")
HASH=$(basename "$STORE_DIR" | cut -d- -f1)
NAME="bwrap-run-$HASH"
FILE="/etc/apparmor.d/$NAME"
PARSER=/usr/sbin/apparmor_parser
QUIET=""
if [ "${2:-}" = "--quiet" ]; then
  QUIET=1
fi

say() {
  [ -n "$QUIET" ] || printf '%s: %s\n' "$progname" "$*" >&2
}

die() {
  printf '%s: error: %s\n' "$progname" "$*" >&2
  exit 1
}

restricted() {
  [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2> /dev/null || echo 0)" = "1" ]
}

works() {
  "$BWRAP" --unshare-user --ro-bind / /true 2> /dev/null
}

cmd_check() {
  if ! restricted; then
    say "userns not restricted; no profile needed"
    return 0
  fi
  if works; then
    say "ok ($BWRAP)"
    return 0
  fi
  printf '%s: bwrap blocked by AppArmor. Run: bwrap-apparmor install\n' "$progname" >&2
  return 1
}

cmd_install() {
  if ! restricted; then
    say "userns not restricted; nothing to install"
    return 0
  fi
  if works; then
    say "already working"
    return 0
  fi
  [ -x "$PARSER" ] || die "$PARSER not found (apt install apparmor)"
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  cat > "$tmp" << EOF
abi <abi/4.0>,
include <tunables/global>
profile $NAME $BWRAP flags=(unconfined) {
  userns,
  include if exists <local/$NAME>
}
EOF
  printf '%s: installing %s for %s (sudo)\n' "$progname" "$FILE" "$BWRAP" >&2
  sudo install -m 0644 -o root -g root "$tmp" "$FILE"
  sudo "$PARSER" -r "$FILE"
  works || die "profile loaded but bwrap still fails; check: journalctl -k | grep -i apparmor"
  say "ok"
}

cmd_prune() {
  shopt -s nullglob
  for f in /etc/apparmor.d/bwrap-run-*; do
    p=$(grep -oE '/nix/store/[^ ]+/bin/bwrap' "$f" | head -n1 || true)
    if [ -z "$p" ] || [ ! -e "$p" ]; then
      printf '%s: removing stale %s\n' "$progname" "$f" >&2
      sudo "$PARSER" -R "$f" || true
      sudo rm -f "$f"
    fi
  done
}

cmd_uninstall() {
  if [ ! -e "$FILE" ]; then
    say "not installed"
    return 0
  fi
  sudo "$PARSER" -R "$FILE" || true
  sudo rm -f "$FILE"
}

case "${1:-check}" in
  check) cmd_check ;;
  install) cmd_install ;;
  prune) cmd_prune ;;
  uninstall) cmd_uninstall ;;
  path) echo "$BWRAP" ;;
  *)
    die "usage: bwrap-apparmor {check [--quiet]|install|prune|uninstall|path}"
    ;;
esac
