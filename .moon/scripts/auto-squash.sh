#!/usr/bin/env bash
#
# auto-squash.sh — squash unpushed commits on the current branch into one,
# opening the editor with a combined message for cleanup.
#
# Usage:
#   .moon/scripts/auto-squash.sh check
#       Pre-push gate. Intended to be called from the moon pre-push hook.
#       - If AUTO_SQUASH=1 is set, runs the squash and exits 0 on success.
#       - Else if more than 1 commit ahead of upstream, prints instructions
#         and exits 1 to block the push.
#       - Else exits 0 to allow the push.
#
#   .moon/scripts/auto-squash.sh run
#   .moon/scripts/auto-squash.sh squash
#       Squash unconditionally (still a no-op if <=1 commit ahead).
#       Useful for manual cleanup outside of a push.
#
# Triggering from git push:
#   AUTO_SQUASH=1 git push
#       Confirms that you want the pre-push hook to squash before pushing.
#
# Bypass entirely:
#   git push --no-verify
#       Skips all hooks. No squash, no moon checks.
#
# Behavior notes:
#   - Works on any branch with an upstream tracking ref.
#   - Gathers subjects and bodies of all commits in upstream..HEAD into a
#     temp file, does `git reset --soft <upstream>`, then
#     `git commit --edit -F <temp>` so $EDITOR opens with the combined
#     message prefilled for final cleanup.

set -euo pipefail

# Script-scope temp file + EXIT trap for cleanup.
msg_file=""
cleanup() {
  if [[ -n ${msg_file:-} && -e $msg_file ]]; then
    rm -f "$msg_file"
  fi
}
trap cleanup EXIT

# Resolve current branch and upstream. Returns 0 if both exist, else 1.
resolve-upstream() {
  branch="$(git branch --show-current)"
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2> /dev/null || true)"
  [[ -n $upstream ]]
}

ahead-count() {
  git fetch "${upstream%%/*}" > /dev/null 2>&1 || true
  git rev-list --count "${upstream}"..HEAD 2> /dev/null || echo 0
}

squash() {
  if ! resolve-upstream; then
    echo "No upstream for current branch. Nothing to squash."
    return 0
  fi

  local ahead
  ahead="$(ahead-count)"
  if [[ $ahead -le 1 ]]; then
    return 0
  fi

  msg_file="$(mktemp)"

  git log "${upstream}"..HEAD --pretty=format:'%s%n%n%b%n----%n' > "$msg_file"

  echo "Squashing $ahead commits on '$branch' into one."
  echo "A combined message will open in your editor for cleanup."

  git reset --soft "${upstream}"

  if [[ -e /dev/tty ]]; then
    git commit --edit -F "$msg_file" < /dev/tty > /dev/tty 2> /dev/tty
  else
    echo "No /dev/tty available; cannot open editor from pre-push hook."
    echo "Run manually:"
    echo "  git commit --edit -F $msg_file"
    return 1
  fi

  echo "New squashed commit on '$branch':"
  git log -1 --oneline
}

check() {
  if ! resolve-upstream; then
    return 0
  fi

  local ahead
  ahead="$(ahead-count)"

  if [[ ${AUTO_SQUASH:-} == "1" ]]; then
    squash
    return $?
  fi

  if [[ $ahead -gt 1 ]]; then
    echo "Branch '$branch' has $ahead commits ahead of '$upstream':"
    git log --oneline "${upstream}"..HEAD
    echo
    echo "To squash before pushing, re-run:"
    echo "  AUTO_SQUASH=1 git push"
    echo
    echo "Or bypass hooks entirely:"
    echo "  git push --no-verify"
    return 1
  fi

  return 0
}

cmd="${1:-check}"
case "$cmd" in
  check) check ;;
  run | squash) squash ;;
  *)
    echo "usage: $0 [check|run]" >&2
    exit 2
    ;;
esac
