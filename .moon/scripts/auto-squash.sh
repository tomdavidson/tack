#!/usr/bin/env bash
#
# auto-squash.sh — squash unlanded commits on the current branch into one,
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

detect-trunk() {
  local t
  t="$(git symbolic-ref --short refs/remotes/origin/HEAD 2> /dev/null | sed 's|^origin/||' || true)"
  [[ -n $t ]] && { echo "$t"; return 0; }
  for c in main master trunk develop; do
    if git show-ref --verify --quiet "refs/remotes/origin/$c"; then
      echo "$c"; return 0
    fi
  done
  echo main
}

resolve-state() {
  branch="$(git branch --show-current)"
  [[ -n $branch ]] || return 1
  git fetch --prune origin > /dev/null 2>&1 || true
  local trunk
  trunk="$(detect-trunk)"
  trunk_ref="origin/$trunk"
  if [[ $branch == "$trunk" ]] || ! git show-ref --verify --quiet "refs/remotes/$trunk_ref"; then
    return 1
  fi
  local mb
  mb="$(git merge-base "$trunk_ref" HEAD 2> /dev/null || true)"
  [[ -n $mb ]] || return 1
  base_commit="$mb"
  target_parent="$mb"
  already_landed=0
  conflict_info=""
  merged_tree=""
  # 1. Check if any earlier commit on this branch is already in trunk_ref
  #    (exact tree match after a squash-merge, or empty diff against trunk_ref).
  local c trunk_tree
  trunk_tree="$(git rev-parse "$trunk_ref^{tree}")"
  while IFS= read -r c; do
    [[ -n $c ]] || continue
    if [[ "$(git rev-parse "$c^{tree}")" == "$trunk_tree" ]] || git diff --quiet "$c" "$trunk_ref" -- $(git diff --name-only "$mb" "$c") 2> /dev/null; then
      base_commit="$c"
      already_landed=1
      echo "Detected commits up to $(git rev-parse --short "$c") ($(git log -1 --format='%s' "$c")) already landed in $trunk_ref; excluding from roll-up."
      break
    fi
  done < <(git rev-list "$mb"..HEAD~1 2> /dev/null || true)

  local out
  if out=$(git merge-tree --write-tree --merge-base="$base_commit" "$trunk_ref" HEAD 2>&1); then
    merged_tree="${out%%$'\n'*}"
    target_parent="$(git rev-parse "$trunk_ref")"
  else
    conflict_info="$out"
  fi
  ahead="$(git rev-list --count "$base_commit"..HEAD 2> /dev/null || echo 0)"
  return 0
}

build-rollup-msg() {
  local range=$1
  local out=$2
  local c subj body norm
  declare -A seen_norm=()
  local substantive=()
  local noise=()

  while IFS= read -r c; do
    [[ -n $c ]] || continue
    subj="$(git log -1 --format='%s' "$c")"
    body="$(git log -1 --format='%b' "$c" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
    if [[ $subj == "chore: auto-format and lint-fix before push" ]]; then
      continue
    fi
    norm="$(printf '%s\n%s' "$subj" "$body" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n $norm ]] || continue
    if [[ -n ${seen_norm[$norm]:-} ]]; then
      continue
    fi
    seen_norm[$norm]=1

    local entry="$subj"
    if [[ -n $body ]]; then
      entry="$subj"$'\n\n'"$body"
    fi

    if [[ ${#subj} -le 4 || $subj =~ ^([-._]+|wip|fmt|fixup|temp|tmp|test|try.*)$ ]]; then
      noise+=("$entry")
    else
      substantive+=("$entry")
    fi
  done < <(git rev-list --reverse "$range")

  : > "$out"
  local item
  for item in "${substantive[@]}"; do
    printf '%s\n\n----\n' "$item" >> "$out"
  done
  for item in "${noise[@]}"; do
    printf '# wip: %s\n' "${item//$'/\n'/ }" >> "$out"
  done
}

squash() {
  if ! resolve-state; then
    echo "Nothing to squash."
    return 0
  fi

  if [[ -n $conflict_info ]]; then
    echo "Warning: branch '$branch' has merge conflicts with '$trunk_ref':"
    printf '%s\n' "$conflict_info" | grep '^CONFLICT' || true
  fi

  if [[ $ahead -le 1 && $already_landed -eq 0 ]]; then
    echo "Branch '$branch' already has $ahead commit ahead of '$trunk_ref'. Nothing to squash."
    return 0
  fi

  msg_file="$(mktemp)"
  build-rollup-msg "$base_commit..HEAD" "$msg_file"

  echo "Squashing $ahead commit(s) on '$branch' into one (based on '$trunk_ref')."
  echo "A deduplicated message will open in your editor for cleanup."

  if [[ -n $merged_tree ]]; then
    git read-tree -u -m "$merged_tree"
  fi
  git reset --soft "$target_parent"

  if [[ -e /dev/tty ]]; then
    git commit --edit -F "$msg_file" < /dev/tty > /dev/tty 2> /dev/tty
  else
    git commit -F "$msg_file"
  fi

  echo "New squashed commit on '$branch':"
  git log -1 --oneline
}

check() {
  if ! resolve-state; then
    return 0
  fi

  if [[ -n $conflict_info ]]; then
    echo "Warning: branch '$branch' has merge conflicts with '$trunk_ref' (push allowed):"
    printf '%s\n' "$conflict_info" | grep '^CONFLICT' || true
    echo
  fi

  # If the only extra commit is the pre-push hook's auto-format commit, fold
  # it silently into the preceding commit without opening an editor.
  if [[ $ahead -eq 2 && $already_landed -eq 0 ]] && [[ "$(git log -1 --format='%s' HEAD)" == "chore: auto-format and lint-fix before push" ]]; then
    local prev_commit
    prev_commit="$(git rev-parse HEAD~1)"
    git reset --soft "$target_parent"
    git commit --no-edit -C "$prev_commit"
    return 0
  fi

  if [[ ${AUTO_SQUASH:-} == "1" ]]; then
    squash
    return $?
  fi

  if [[ $ahead -gt 1 || $already_landed -eq 1 ]]; then
    echo "Branch '$branch' has $ahead unlanded commit(s) vs '$trunk_ref':"
    git log --oneline "$base_commit"..HEAD
    echo
    echo "To squash & rebase onto '$trunk_ref', run:"
    echo "  .moon/scripts/auto-squash.sh run"
    echo "or push with:"
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
