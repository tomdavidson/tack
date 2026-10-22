#!/usr/bin/env bats
# git shim regression tests
# bats --verbose-run configs/devenv/tests/git-shim.bats
#
# The shim body lives inside devenv.tera.nix as a Nix string. These tests
# render the template, lift the `git.exec` body out of devenv.nix into a
# standalone script, and drive it against a fake "real" git and a fake
# tidy-push.sh. The shim pins real git via a Nix interpolation that tack does
# not evaluate, so extraction swaps it for the fake. TTY-gated cases run under
# util-linux `script` and skip when it is unavailable.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  bats_load_library bats-file

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  REPO="$(cd "$HERE/../../.." && pwd)"
  TACK_SH="$REPO/tack.sh"
  TARGET="$(mktemp -d -t tack-gitshim.XXXXXX)"
  SYSTEM_GIT="$(command -v git)"
  [[ -n $SYSTEM_GIT ]] || skip "git not installed"

  export TACK_ROOT="$REPO"
}

teardown() {
  rm -rf "$TARGET"
}

apply_devenv() {
  "$TACK_SH" --target "$TARGET" configs/devenv
}

# PINNED_GIT -- the Nix interpolation the shim uses for its real git.
PINNED_GIT='${lib.escapeShellArg (lib.getExe pkgs.git)}'

# extract_shim -- lift the git.exec body from the rendered devenv.nix into
# $TARGET/shim/git. Nix's ''${ escape becomes a plain ${ for bash, and the
# pinned-git interpolation becomes the fake real git under $TARGET/real.
extract_shim() {
  apply_devenv
  mkdir -p "$TARGET/shim"
  {
    # Absolute interpreter: PATH-restricted tests must hide git, not bash.
    printf '#!%s\n' "$BASH"
    sed -n "/^[[:space:]]*git\\.exec = ''\$/,/^[[:space:]]*'';\$/p" "$TARGET/devenv.nix" \
      | sed -e '1d' -e '$d' -e "s/''\\\${/\\\${/g" \
      | awk -v pin="$PINNED_GIT" -v real="'$TARGET/real/git'" '{ i = index($0, pin); if (i) $0 = substr($0, 1, i - 1) real substr($0, i + length(pin)); print }'
  } > "$TARGET/shim/git"
  chmod +x "$TARGET/shim/git"
  run grep -F "$TARGET/real/git" "$TARGET/shim/git"
  assert_success
  run grep -F "$PINNED_GIT" "$TARGET/shim/git"
  assert_failure
}

# make_fakes -- $TARGET/real/git logs every call to $TARGET/real.log and
# delegates rev-parse to the system git so worktree discovery is genuine.
# $TARGET/proj is a git repo acting as DEVENV_ROOT with a fake tidy-push.sh
# that records its cwd and args.
make_fakes() {
  mkdir -p "$TARGET/real" "$TARGET/proj/.moon/scripts" "$TARGET/proj/sub"
  cat > "$TARGET/real/git" << EOF
#!$BASH
if [[ \${1:-} == rev-parse ]]; then exec "$SYSTEM_GIT" "\$@"; fi
printf 'real-git:%s\\n' "\$*" >> "$TARGET/real.log"
EOF
  cat > "$TARGET/proj/.moon/scripts/tidy-push.sh" << EOF
#!$BASH
printf 'tidy-push:%s cwd=%s\\n' "\$*" "\$PWD" >> "$TARGET/tidy.log"
EOF
  chmod +x "$TARGET/real/git" "$TARGET/proj/.moon/scripts/tidy-push.sh"
  (cd "$TARGET/proj" && "$SYSTEM_GIT" init -q)
}

SHIM_PATH() { printf '%s:%s:%s' "$TARGET/shim" "$TARGET/real" "$PATH"; }

# run_tty CWD CMD... -- run CMD under a pseudo-terminal so -t 0 && -t 1 hold.
run_tty() {
  script --version 2> /dev/null | grep -q util-linux || skip "util-linux script(1) not available for TTY cases"
  local cwd=$1
  shift
  local cmd
  printf -v cmd '%q ' "$@"
  run script -qefc "cd $(printf '%q' "$cwd") && $cmd" /dev/null
}

# ---------- template rendering ----------

@test "devenv renders the git shim by default" {
  apply_devenv
  run grep -F 'git.exec' "$TARGET/devenv.nix"
  assert_success
  run grep -F 'tidy-push.sh' "$TARGET/devenv.nix"
  assert_success
}

@test "devenv omits the git shim when vars.devenv.git_shim is false" {
  cat > "$TARGET/tackrc.yml" << 'EOF'
vars:
  devenv:
    git_shim: false
EOF
  apply_devenv
  run grep -F 'git.exec' "$TARGET/devenv.nix"
  assert_failure
}

@test "shim pins real git at Nix evaluation time and never searches PATH" {
  apply_devenv
  run grep -F "real_git=$PINNED_GIT" "$TARGET/devenv.nix"
  assert_success
  run grep -E 'type -aP|command -v git|which git|DEVENV_PROFILE/bin' "$TARGET/devenv.nix"
  assert_failure
}

# ---------- pass-through ----------

@test "non-push commands pass through with arguments intact" {
  extract_shim
  make_fakes
  PATH="$(SHIM_PATH)" DEVENV_ROOT="$TARGET/proj" run git status --short "a b"
  assert_success
  run cat "$TARGET/real.log"
  assert_output 'real-git:status --short a b'
  assert_file_not_exists "$TARGET/tidy.log"
}

@test "non-interactive bare push passes through to real git" {
  extract_shim
  make_fakes
  (
    cd "$TARGET/proj" && PATH="$(SHIM_PATH)" DEVENV_ROOT="$TARGET/proj" run git push < /dev/null
    assert_success
  )
  run cat "$TARGET/real.log"
  assert_output 'real-git:push'
  assert_file_not_exists "$TARGET/tidy.log"
}

@test "shim does not recurse into itself via a symlink alias" {
  extract_shim
  make_fakes
  mkdir -p "$TARGET/alias"
  ln -s "$TARGET/shim/git" "$TARGET/alias/git"
  PATH="$TARGET/alias:$(SHIM_PATH)" DEVENV_ROOT="$TARGET/proj" run timeout 5 git version
  assert_success
  run cat "$TARGET/real.log"
  assert_output 'real-git:version'
}

@test "shim reaches the pinned git even when PATH holds only the shim" {
  extract_shim
  make_fakes
  # A host git wrapper that calls `git` by name used to bounce back into the
  # shim and fork until OOM. With PATH reduced to the shim dir, the pinned
  # path must still be what runs.
  PATH="$TARGET/shim" run "$TARGET/shim/git" status
  assert_success
  run cat "$TARGET/real.log"
  assert_output 'real-git:status'
}

# ---------- interactive push (TTY) ----------

@test "bare interactive push in DEVENV_ROOT runs tidy-push from the worktree root" {
  extract_shim
  make_fakes
  run_tty "$TARGET/proj/sub" env PATH="$(SHIM_PATH)" DEVENV_ROOT="$TARGET/proj" git push
  assert_success
  run cat "$TARGET/tidy.log"
  assert_output "tidy-push:push cwd=$(cd "$TARGET/proj" && pwd -P)"
  assert_file_not_exists "$TARGET/real.log"
}

@test "interactive push with explicit arguments passes through untouched" {
  extract_shim
  make_fakes
  run_tty "$TARGET/proj" env PATH="$(SHIM_PATH)" DEVENV_ROOT="$TARGET/proj" git push --force-with-lease origin HEAD
  assert_success
  run cat "$TARGET/real.log"
  assert_output 'real-git:push --force-with-lease origin HEAD'
  assert_file_not_exists "$TARGET/tidy.log"
}

@test "interactive push in a nested repo is not intercepted" {
  extract_shim
  make_fakes
  mkdir -p "$TARGET/proj/nested"
  (cd "$TARGET/proj/nested" && "$SYSTEM_GIT" init -q)
  run_tty "$TARGET/proj/nested" env PATH="$(SHIM_PATH)" DEVENV_ROOT="$TARGET/proj" git push
  assert_success
  run cat "$TARGET/real.log"
  assert_output 'real-git:push'
  assert_file_not_exists "$TARGET/tidy.log"
}

@test "interactive push outside any repo falls back to real git" {
  extract_shim
  make_fakes
  mkdir -p "$TARGET/norepo"
  run_tty "$TARGET/norepo" env PATH="$(SHIM_PATH)" DEVENV_ROOT="$TARGET/proj" GIT_CEILING_DIRECTORIES="$TARGET" git push
  assert_success
  run cat "$TARGET/real.log"
  assert_output 'real-git:push'
  assert_file_not_exists "$TARGET/tidy.log"
}

@test "TIDY_PUSH_ACTIVE short-circuits to real git" {
  extract_shim
  make_fakes
  run_tty "$TARGET/proj" env PATH="$(SHIM_PATH)" DEVENV_ROOT="$TARGET/proj" TIDY_PUSH_ACTIVE=1 git push
  assert_success
  run cat "$TARGET/real.log"
  assert_output 'real-git:push'
  assert_file_not_exists "$TARGET/tidy.log"
}

@test "missing tidy-push.sh falls back to real git" {
  extract_shim
  make_fakes
  rm "$TARGET/proj/.moon/scripts/tidy-push.sh"
  run_tty "$TARGET/proj" env PATH="$(SHIM_PATH)" DEVENV_ROOT="$TARGET/proj" git push
  assert_success
  run cat "$TARGET/real.log"
  assert_output 'real-git:push'
}
