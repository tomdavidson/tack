#!/usr/bin/env bash
#
# tidy-push.sh - tidy a short-lived PR branch before it is pushed.
#
# Usage (called from the moon pre-push hook):
#   tidy-push.sh preflight       fetch --prune; block merged/diverged branches
#   tidy-push.sh finalize-push   roll up unpushed commits, merge trunk, push
#   tidy-push.sh run             manual roll-up of unpushed commits (no push)
#   tidy-push.sh status          read-only: range and trunk mergeability
#   tidy-push.sh trunk           print the trunk branch name
#
# Rules:
#   - Only commits the remote has not seen (origin/<branch>..HEAD) are rewritten.
#   - Never force-pushes. Never rebases. Catches up with trunk via git merge.
#   - The roll-up range starts after the newest merge commit, so a merge of
#     trunk is never flattened.
#   - The editor opens BEFORE history changes. Ctrl+C, a non-zero editor exit,
#     or an empty message aborts with every commit untouched.
#   - If HEAD changes, the hook pushes the new HEAD itself and exits 1, because
#     the outer git push already chose the old SHA before the hook ran. It
#     prints 'EXPECTED' first, so Git's red error is explained.
#   - Any other non-zero exit prints 'UNEXPECTED' with fix hints.

set -euo pipefail

remote="${PUSH_FLOW_REMOTE:-origin}"
noise_re='^([-._]+|wip|fmt|fixup|temp|tmp|test|try.*|again|more)$'
msg_file=""
clean_msg=""
expected_rewrite=0
hint_on_fail=0

cleanup() {
  local rc=$?
  [[ -n $msg_file && -e $msg_file ]] && rm -f "$msg_file"
  [[ -n $clean_msg && -e $clean_msg ]] && rm -f "$clean_msg"
  if ((rc != 0 && rc != 2 && expected_rewrite == 0 && hint_on_fail == 1)); then
    rule
    say "x UNEXPECTED push failure. This is NOT the normal 'history rewritten' stop."
    say "  (That one always prints 'EXPECTED' before Git's red error.)"
    say "  Fixes to try, in order:"
    say "    1. Read the message above this one; it names the cause."
    say "    2. git status -sb          # diverged, or no upstream?"
    say "    3. git fetch --prune && .moon/scripts/tidy-push.sh status"
    say "    4. git merge $remote/<branch>   # if the remote moved"
    say "    5. moon run :vf, then fix lint/format/gitleaks findings"
    say "    6. Roll-up aborted? Re-run git push and save a non-empty message"
    rule
  fi
  return 0
}
trap cleanup EXIT

say() { printf '%s\n' "$*" >&2; }
rule() { say "--------------------------------------------------------"; }

detect-trunk() {
  local t c
  t="$(git symbolic-ref --short "refs/remotes/$remote/HEAD" 2> /dev/null | sed "s|^$remote/||" || true)"
  if [[ -n $t ]]; then
    echo "$t"
    return 0
  fi
  for c in main master trunk develop; do
    if git show-ref --verify --quiet "refs/remotes/$remote/$c"; then
      echo "$c"
      return 0
    fi
  done
  echo main
}

is-noise() {
  local norm
  norm="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n $norm ]] || return 0
  [[ ${#norm} -le 4 || $norm =~ $noise_re ]]
}

# Unpushed range base: upstream tip, else fork point with trunk; then skip
# past the newest merge commit so merges are never flattened.
resolve-base() {
  local branch=$1 trunk_ref=$2 base newest_merge
  if git show-ref --verify --quiet "refs/remotes/$remote/$branch"; then
    base="$(git rev-parse "$remote/$branch")"
  else
    base="$(git merge-base "$trunk_ref" HEAD)"
  fi
  newest_merge="$(git rev-list --merges -n1 "$base..HEAD" 2> /dev/null || true)"
  [[ -n $newest_merge ]] && base="$newest_merge"
  echo "$base"
}

# Prints the newest commit whose changes already exist in trunk (squash-merged).
find-already-landed-commit() {
  local trunk_ref=$1 mb=$2 c
  local -a files=()
  while IFS= read -r c; do
    [[ -n $c ]] || continue
    mapfile -t files < <(git diff --name-only "$mb" "$c" 2> /dev/null || true)
    if ((${#files[@]} > 0)) && git diff --quiet "$c" "$trunk_ref" -- "${files[@]}" 2> /dev/null; then
      echo "$c"
      return 0
    fi
  done < <(git rev-list "$mb..HEAD" 2> /dev/null || true)
  return 1
}

preflight() {
  local branch trunk trunk_ref mb
  branch="$(git branch --show-current)"
  [[ -n $branch ]] || return 0

  git fetch --prune "$remote" > /dev/null 2>&1 || say "warning: git fetch --prune failed; continuing offline"

  trunk="$(detect-trunk)"
  trunk_ref="$remote/$trunk"
  if [[ $branch == "$trunk" ]] || ! git show-ref --verify --quiet "refs/remotes/$trunk_ref"; then
    return 0
  fi

  # Guard 1: branch tracked a remote branch that is now gone (PR merged, branch deleted).
  local cfg_merge remote_ref
  cfg_merge="$(git config --get "branch.${branch}.merge" 2> /dev/null || true)"
  remote_ref="refs/remotes/$remote/$branch"
  if [[ -n $cfg_merge ]] && ! git show-ref --verify --quiet "$remote_ref"; then
    rule
    say "x '$branch' tracked '$remote/$branch', which no longer exists on $remote."
    say "  Its PR was likely squash-merged and the branch deleted."
    say "  Pushing again would re-propose commits already in $trunk_ref."
    say ""
    say "  Start fresh from trunk, carrying only new work:"
    say "    git switch -c <new-branch> $trunk_ref"
    say "    git cherry-pick <sha>..."
    say ""
    say "  Or, if you really intend to reuse this name:"
    say "    git branch --unset-upstream && git push -u $remote $branch"
    rule
    return 1
  fi

  # Guard 2: everything on this branch is already in trunk.
  if git merge-base --is-ancestor HEAD "$trunk_ref"; then
    rule
    say "x All commits on '$branch' are already in '$trunk_ref'."
    say "  Start fresh: git switch -c <new-branch> $trunk_ref"
    rule
    return 1
  fi

  # Guard 3: local and remote branch have split. Never force; merge instead.
  if git show-ref --verify --quiet "$remote_ref" && ! git merge-base --is-ancestor "$remote/$branch" HEAD; then
    rule
    say "x '$branch' has diverged from '$remote/$branch'."
    say "  Integrate the remote work with a merge (no force-push needed):"
    say "    git merge $remote/$branch"
    say "  Force-push remains a manual recovery action:"
    say "    git push --force-with-lease"
    rule
    return 1
  fi

  # Warning only: earlier commits already landed in trunk (e.g. pushed with --no-verify).
  mb="$(git merge-base "$trunk_ref" HEAD 2> /dev/null || true)"
  if [[ -n $mb ]]; then
    local landed
    landed="$(find-already-landed-commit "$trunk_ref" "$mb" || true)"
    if [[ -n $landed ]]; then
      rule
      say "! '$branch' has commits up to $(git rev-parse --short "$landed") whose changes already exist in $trunk_ref."
      say "  Push continues. If this branch was already squash-merged, start fresh:"
      say "    git switch -c <new-branch> $trunk_ref"
      rule
    fi
  fi
  return 0
}

# Draft message for RANGE. Real messages first (deduped); noise collapsed to counted comments.
build-rollup-msg() {
  local range=$1 out=$2 branch=$3 count=$4
  local c subj body full i n
  declare -A seen=()
  declare -A noise_counts=()
  local -a noise_order=() substantive=()

  while IFS= read -r c; do
    [[ -n $c ]] || continue
    subj="$(git log -1 --format='%s' "$c")"
    body="$(git log -1 --format='%b' "$c" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
    [[ $subj == "chore: auto-format and lint-fix before push" ]] && continue
    if is-noise "$subj"; then
      n="$(printf '%s' "$subj" | tr '[:upper:]' '[:lower:]')"
      if [[ -z ${noise_counts[$n]:-} ]]; then
        noise_order+=("$n")
        noise_counts[$n]=1
      else
        noise_counts[$n]=$((noise_counts[$n] + 1))
      fi
    else
      full="$(printf '%s\n%s' "$subj" "$body" | tr '[:upper:]' '[:lower:]')"
      if [[ -z ${seen[$full]:-} ]]; then
        seen[$full]=1
        if [[ -n $body ]]; then
          substantive+=("$subj"$'\n\n'"$body")
        else
          substantive+=("$subj")
        fi
      fi
    fi
  done < <(git rev-list --reverse "$range")

  : > "$out"
  for i in "${!substantive[@]}"; do
    ((i > 0)) && printf '\n----\n\n' >> "$out"
    printf '%s\n' "${substantive[$i]}" >> "$out"
  done
  {
    printf '\n# Rolling up %s unpushed commit(s) on '\''%s'\'' before pushing.\n' "$count" "$branch"
    printf '# Save and quit to ACCEPT the message above.\n'
    printf '# To ABORT (commits stay untouched): delete all non-comment lines and save, or press Ctrl+C.\n'
    if ((${#noise_order[@]} > 0)); then
      printf '#\n# Collapsed placeholder commits:\n'
      for n in "${noise_order[@]}"; do
        printf '#   %s (x%s)\n' "$n" "${noise_counts[$n]}"
      done
    fi
  } >> "$out"
}

# Run the editor Git would use. File is a separate argument, so editors
# like 'code --wait' and paths with spaces both work.
launch-editor() {
  local editor
  editor="$(git var GIT_EDITOR)"
  sh -c "$editor \"\$1\"" sh "$1" < /dev/tty > /dev/tty 2>&1
}

# Pre-populate, edit, strip comments into $clean_msg. Returns 1 to abort.
# Runs before any history change, so aborting needs no restore.
prompt-commit-msg() {
  local range=$1 branch=$2 count=$3 have_tty=0 rc=0
  msg_file="$(mktemp)"
  clean_msg="$(mktemp)"
  build-rollup-msg "$range" "$msg_file" "$branch" "$count"

  if [[ -r /dev/tty && -w /dev/tty ]]; then
    have_tty=1
    trap 'say "x Interrupted. Commits left untouched."; exit 130' INT
    launch-editor "$msg_file" || rc=$?
    trap - INT
    if ((rc != 0)); then
      say "x Editor exited with status $rc. Commits left untouched; push aborted."
      return 1
    fi
  fi

  git stripspace --strip-comments < "$msg_file" > "$clean_msg"

  if [[ -z "$(tr -d '[:space:]' < "$clean_msg")" ]]; then
    if ((have_tty)); then
      say "x Empty commit message. Commits left untouched; push aborted."
      return 1
    fi
    say "  (no terminal and only placeholder commits; using a placeholder subject)"
    printf 'wip: %s commits on %s\n' "$count" "$branch" > "$clean_msg"
  fi
  return 0
}

# Clean merge: merge trunk automatically. Conflict or failure: warn, never block.
catch-up-trunk() {
  local branch=$1 trunk_ref=$2 out
  git merge-base --is-ancestor "$trunk_ref" HEAD && return 0

  if out="$(git merge-tree --write-tree "$trunk_ref" HEAD 2>&1)"; then
    if git merge --no-edit "$trunk_ref" > /dev/null 2>&1; then
      say "* merged $trunk_ref into '$branch' (clean)"
      return 0
    fi
    git merge --abort > /dev/null 2>&1 || true
    rule
    say "! $trunk_ref merges cleanly but the merge could not run (uncommitted changes?). Push continues."
    say "  Run when ready: git merge $trunk_ref"
    rule
    return 0
  fi

  rule
  say "! '$branch' conflicts with $trunk_ref (push is NOT blocked):"
  printf '%s\n' "$out" | grep '^CONFLICT' | sed 's/^/    /' >&2 || true
  say "  Resolve when convenient:"
  say "    git merge $trunk_ref"
  say "    # fix conflicts, git add, git commit, then git push"
  rule
}

finalize-push() {
  local mode=${1:-finalize-push}
  local branch trunk trunk_ref base ahead has_staged=0 head_before head_after
  branch="$(git branch --show-current)"
  [[ -n $branch ]] || return 0

  trunk="$(detect-trunk)"
  trunk_ref="$remote/$trunk"
  [[ $branch != "$trunk" ]] || return 0

  base="$(resolve-base "$branch" "$trunk_ref")"
  ahead="$(git rev-list --count "$base..HEAD" 2> /dev/null || echo 0)"
  git diff --cached --quiet || has_staged=1
  head_before="$(git rev-parse HEAD)"

  if ((ahead == 1)); then
    local subj
    subj="$(git log -1 --format='%s' HEAD)"
    if is-noise "$subj" || [[ $mode == run ]]; then
      prompt-commit-msg "$base..HEAD" "$branch" "$ahead" || return 1
      git commit -q --amend --no-verify -F "$clean_msg"
    elif ((has_staged)); then
      say "* folding format fixes into $(git rev-parse --short HEAD)"
      git commit -q --amend --no-edit --no-verify
    fi
  elif ((ahead > 1)); then
    say "* rolling up $ahead unpushed commits on '$branch' (${base:0:7}..HEAD)"
    prompt-commit-msg "$base..HEAD" "$branch" "$ahead" || return 1
    git reset -q --soft "$base"
    if ! git commit -q --no-verify -F "$clean_msg"; then
      git reset -q --soft "$head_before"
      say "x Commit failed; original commits restored."
      return 1
    fi
    say "  -> $(git log -1 --oneline)"
  elif ((has_staged)); then
    rule
    say "! Format fixes are staged but there is no unpushed commit to fold them into."
    say "  Commit them yourself (git commit) and push again."
    rule
  fi

  [[ $mode == run ]] && return 0

  catch-up-trunk "$branch" "$trunk_ref"

  head_after="$(git rev-parse HEAD)"
  if [[ $head_after != "$head_before" ]]; then
    local -a flags=()
    git show-ref --verify --quiet "refs/remotes/$remote/$branch" || flags+=(-u)
    say "* pushing $(git log -1 --oneline) to $remote/$branch"
    SKIP_PRE_PUSH=1 git push "${flags[@]}" "$remote" "HEAD:refs/heads/$branch"
    expected_rewrite=1
    rule
    say "OK pushed $(git log -1 --oneline) to $remote/$branch."
    say ""
    say "EXPECTED: Git will now print a red 'error: failed to push some refs'."
    say "  Your history was tidied, so the outer 'git push' still held the old"
    say "  commit and stops on purpose. Nothing is wrong and nothing to do."
    say "  (Only worry if that red error appears WITHOUT this message.)"
    rule
    exit 1
  fi
  return 0
}

status() {
  local branch trunk trunk_ref base ahead
  branch="$(git branch --show-current)"
  trunk="$(detect-trunk)"
  trunk_ref="$remote/$trunk"
  base="$(resolve-base "$branch" "$trunk_ref")"
  ahead="$(git rev-list --count "$base..HEAD" 2> /dev/null || echo 0)"
  say "branch:  $branch"
  say "range:   ${base:0:7}..HEAD ($ahead unpushed commit(s))"
  if git merge-base --is-ancestor "$trunk_ref" HEAD; then
    say "trunk:   up to date with $trunk_ref"
  elif git merge-tree --write-tree "$trunk_ref" HEAD > /dev/null 2>&1; then
    say "trunk:   behind $trunk_ref, merges cleanly (auto-merged on push)"
  else
    say "trunk:   behind $trunk_ref, CONFLICTS (warned on push)"
  fi
}

case "${1:-preflight}" in
  trunk) detect-trunk ;;
  preflight | check)
    hint_on_fail=1
    preflight
    ;;
  finalize-push)
    hint_on_fail=1
    finalize-push finalize-push
    ;;
  run | squash | tidy) preflight && finalize-push run ;;
  status) status ;;
  *)
    say "usage: $0 [preflight|finalize-push|run|status|trunk]"
    exit 2
    ;;
esac
