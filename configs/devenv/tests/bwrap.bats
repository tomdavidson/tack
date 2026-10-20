#!/usr/bin/env bats
# bwrap sandbox integration tests
# bats --verbose-run configs/devenv/tests/bwrap.bats
#
# Covers the devenv template wiring (bwrap-run wrappers, .tack namespace,
# disable switch) and the host-side tool resolution + repo root detection
# inside configs/devenv/bwrap-run.sh. Running bwrap itself is only exercised
# by the root-detection tests below (skipped when bwrap is unavailable);
# full sandbox behavior is a host acceptance step in docs/bwrap.md.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  bats_load_library bats-file

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"
  REPO="$(cd "$HERE/../../.." && pwd)"
  TACK_SH="$REPO/tack.sh"
  BWRAP_SH="$REPO/configs/devenv/bwrap-run.sh"
  TARGET="$(mktemp -d -t tack-bwrap.XXXXXX)"

  export TACK_ROOT="$REPO"
}

teardown() {
  rm -rf "$TARGET"
}

apply_devenv() {
  "$TACK_SH" --target "$TARGET" configs/devenv
}

# make_tree DIR -- fake repository layout under DIR:
#   DIR/.git        directory (superproject root)
#   DIR/mod/.git    file "gitdir: ../.git/modules/mod" (submodule worktree)
#   DIR/wt/.git     file "gitdir: ../.git/worktrees/wt" (linked worktree)
make_tree() {
  mkdir -p "$1/mod" "$1/wt"
  mkdir -p "$1/.git/modules/mod" "$1/.git/worktrees/wt"
  printf 'gitdir: ../.git/modules/mod\n' > "$1/mod/.git"
  printf 'gitdir: ../.git/worktrees/wt\n' > "$1/wt/.git"
}

# require_bwrap -- no bwrap on PATH means the host opted out of the
# sandbox: skip. bwrap present but unable to create a user namespace is a
# broken sandbox, and a sandbox must never fail silently: fail with the
# fix. Ubuntu 23.10+/KDE Neon set
# kernel.apparmor_restrict_unprivileged_userns=1, which yields
# "setting up uid map: Permission denied" until an AppArmor profile grants
# userns to this bwrap binary (configs/devenv/bwrap-apparmor.sh install).
require_bwrap() {
  command -v bwrap >/dev/null 2>&1 || skip "bwrap not installed (sandbox not in use on this host)"
  bwrap --unshare-user --ro-bind / / true >/dev/null 2>&1 ||
    fail "bwrap is installed but cannot create a user namespace (kernel.apparmor_restrict_unprivileged_userns). Run: configs/devenv/bwrap-apparmor.sh install"
}

# ---------- devenv template rendering ----------

@test "devenv renders bwrap-run scripts for every default tool" {
  apply_devenv
  for tool in node npx pnpm moon cargo rustc; do
    run grep -F "${tool}.exec" "$TARGET/devenv.nix"
    assert_success
    run grep -F "bwrapRun} ${tool}" "$TARGET/devenv.nix"
    assert_success
  done
}

@test "devenv adds bubblewrap packages and apparmor check when enabled" {
  apply_devenv
  run grep -F "bubblewrap" "$TARGET/devenv.nix"
  assert_success
  run grep -F "apparmor-utils" "$TARGET/devenv.nix"
  assert_success
  run grep -F "bwrap-apparmor check --quiet" "$TARGET/devenv.nix"
  assert_success
}

@test "sandbox scripts stay in the .tack namespace, not the consumer root" {
  apply_devenv
  assert_file_not_exists "$TARGET/bwrap-run.sh"
  assert_file_not_exists "$TARGET/bwrap-apparmor.sh"
  assert_file_not_exists "$TARGET/tests/bwrap.bats"
}

@test "rendered wrappers invoke .tack/configs/devenv scripts by absolute path" {
  apply_devenv
  run grep -F ".tack/configs/devenv/bwrap-run.sh" "$TARGET/devenv.nix"
  assert_success
  run grep -F ".tack/configs/devenv/bwrap-apparmor.sh" "$TARGET/devenv.nix"
  assert_success
}

@test "rendered wrappers pass BWRAP_REPO_ROOT, not a discovered root" {
  apply_devenv
  run grep -F "BWRAP_REPO_ROOT=" "$TARGET/devenv.nix"
  assert_success
  # Inspect only wrappers that execute bwrapRun; the git shim has its own root.
  wrappers=$(sed -n '/^[[:space:]]*bwrap-run.exec =/,/^[[:space:]]*};/p' "$TARGET/devenv.nix")
  [[ -n $wrappers ]]
  for tool in bwrap-run node npx pnpm moon cargo rustc; do
    block=$(printf '%s\n' "$wrappers" | sed -n "/^[[:space:]]*${tool}\.exec =/,/^[[:space:]]*'';/p")
    [[ -n $block ]]
    [[ $block == *'BWRAP_REPO_ROOT=${lib.escapeShellArg projectRoot}'* ]]
    [[ $block != *DEVENV_ROOT* ]]
    [[ $block != *PWD* ]]
  done
}

@test "devenv yaml keeps only the nixpkgs input when enabled" {
  apply_devenv
  run grep -F "nixpkgs:" "$TARGET/devenv.yaml"
  assert_success
  run grep -F "tack:" "$TARGET/devenv.yaml"
  assert_failure
}

@test "devenv omits all bwrap wiring when disabled" {
  cat > "$TARGET/tackrc.yml" <<'EOF'
vars:
  bwrap:
    enabled: false
EOF
  apply_devenv
  run grep -F "bwrapRun" "$TARGET/devenv.nix"
  assert_failure
  run grep -F "bubblewrap" "$TARGET/devenv.nix"
  assert_failure
  assert_file_not_exists "$TARGET/bwrap-run.sh"
}

@test "devenv consumer tools list is honored" {
  cat > "$TARGET/tackrc.yml" <<'EOF'
vars:
  bwrap:
    tools:
      - node
      - pnpm
EOF
  apply_devenv
  run grep -F "node.exec" "$TARGET/devenv.nix"
  assert_success
  run grep -F "cargo.exec" "$TARGET/devenv.nix"
  assert_failure
}

@test "devenv env vars render through vars.devenv" {
  cat > "$TARGET/tackrc.yml" <<'EOF'
vars:
  devenv:
    env:
      BWRAP_TEST_MARKER: present
EOF
  apply_devenv
  run grep -F 'BWRAP_TEST_MARKER = "present";' "$TARGET/devenv.nix"
  assert_success
}

# ---------- bwrap-run host-side tool resolution ----------

@test "bwrap-run --print-cmd resolves proto shims" {
  fake_proto="$TARGET/proto"
  mkdir -p "$fake_proto/shims"
  printf '#!/bin/sh\n' > "$fake_proto/shims/node"
  chmod +x "$fake_proto/shims/node"
  PROTO_HOME="$fake_proto" run bash "$BWRAP_SH" --print-cmd node
  assert_success
  assert_output "$fake_proto/shims/node"
}

@test "bwrap-run --print-cmd resolves cargo bins" {
  fake_cargo="$TARGET/cargo"
  mkdir -p "$fake_cargo/bin"
  printf '#!/bin/sh\n' > "$fake_cargo/bin/cargo"
  chmod +x "$fake_cargo/bin/cargo"
  CARGO_HOME="$fake_cargo" run bash "$BWRAP_SH" --print-cmd cargo
  assert_success
  assert_output "$fake_cargo/bin/cargo"
}

@test "bwrap-run --print-cmd skips devenv script wrappers on PATH" {
  fake_devenv="$TARGET/proj/.devenv/state/scripts"
  real_bin="$TARGET/real-bin"
  # resolve_cmd consults `proto bin`, proto shims, and cargo bins before
  # PATH. Point PROTO_HOME/CARGO_HOME at empty dirs so a node installed
  # in the real proto store cannot win before the PATH step under test.
  empty_proto="$TARGET/empty-proto"
  empty_cargo="$TARGET/empty-cargo"
  mkdir -p "$fake_devenv" "$real_bin" "$empty_proto" "$empty_cargo"
  printf '#!/bin/sh\n' > "$fake_devenv/node"
  printf '#!/bin/sh\n' > "$real_bin/node"
  chmod +x "$fake_devenv/node" "$real_bin/node"
  PROTO_HOME="$empty_proto" CARGO_HOME="$empty_cargo" \
    PATH="$fake_devenv:$real_bin:$PATH" run bash "$BWRAP_SH" --print-cmd node
  assert_success
  assert_output "$real_bin/node"
}

@test "bwrap-run --print-cmd resolves explicit paths verbatim" {
  run bash "$BWRAP_SH" --print-cmd /usr/bin/env
  assert_success
  assert_output "/usr/bin/env"
}

# ---------- repo root detection (needs bwrap; skipped otherwise) ----------

@test "root fallback walks past a submodule .git file to the superproject" {
  require_bwrap
  tree="$TARGET/tree"
  make_tree "$tree"
  (cd "$tree/mod"
  run bash "$BWRAP_SH" bash -c "touch '$tree/marker'"
  assert_success
  assert_file_exists "$tree/marker")
}

@test "root fallback stops at a linked worktree .git file" {
  require_bwrap
  tree="$TARGET/tree"
  make_tree "$tree"
  (cd "$tree/wt"
  # the sandbox /tmp is a tmpfs, so the touch itself succeeds inside it;
  # the observable is whether the host file appears. Stopping at the
  # worktree means the parent never becomes writable.
  run bash "$BWRAP_SH" bash -c "touch '$tree/marker'"
  assert_success
  assert_file_not_exists "$tree/marker"
  # the worktree root itself is writable
  run bash "$BWRAP_SH" bash -c "touch '$tree/wt/inner'"
  assert_success
  assert_file_exists "$tree/wt/inner")
}

@test "BWRAP_REPO_ROOT overrides root detection" {
  require_bwrap
  tree="$TARGET/tree"
  make_tree "$tree"
  (cd "$tree/mod"
  # detection alone would make $tree writable (submodule walk); the
  # override narrows the sandbox to the submodule, so a host file never
  # appears outside it
  run env BWRAP_REPO_ROOT="$tree/mod" bash "$BWRAP_SH" bash -c "touch '$tree/marker'"
  assert_success
  assert_file_not_exists "$tree/marker"
  run env BWRAP_REPO_ROOT="$tree/mod" bash "$BWRAP_SH" bash -c "touch '$tree/mod/inner'"
  assert_success
  assert_file_exists "$tree/mod/inner")
}

# ---------- ADR-0008: writable .tack, read-only host-executed surface ----------

# allowed_tack_ref REL -- REL (relative to the tack root) lies inside the
# surface bwrap-run pins read-only: tack.sh, configs/devenv/**,
# configs/<area>/scripts/**, and *.nix modules. Anything a template or
# module references outside this set would execute on the host from a
# writable location.
allowed_tack_ref() {
  case "$1" in
    tack.sh | configs/devenv | configs/devenv/*) return 0 ;;
    configs/*/scripts | configs/*/scripts/*) return 0 ;;
    *.nix) return 0 ;;
  esac
  return 1
}

@test "ADR-0008: templates and modules reference only the pinned .tack surface" {
  files=$(find "$REPO/configs" \( -name node_modules -o -name tests \) -prune -o \
    -type f \( -name '*.nix' -o -name '*.tera.*' -o -name '.envrc' \) -print)
  [ -n "$files" ]
  # Tera placeholders ({{ vars.drupal.variant }}.nix) are collapsed so the
  # extension survives and the *.nix rule applies. Trailing slashes and
  # sentence punctuation ("...python.nix." in a comment) are stripped.
  # shellcheck disable=SC2086
  refs=$(cat $files | sed 's/{{[^}]*}}/VAR/g' |
    grep -oE '\.tack/[A-Za-z0-9_./-]+' | sed -e 's#^\.tack/##' -e 's#[./]*$##' | sort -u)
  bad=""
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    allowed_tack_ref "$r" || bad="$bad $r"
  done <<< "$refs"
  [ -z "$bad" ] || fail "host-executed .tack references outside the pinned surface:$bad"
}

# make_consumer DIR LAYOUT -- consumer repo with a .tack checkout.
#   submodule  DIR/.tack is a directory whose .git is a gitdir: file
#              pointing at DIR/.git/modules/tack (hooks live there)
#   symlink    DIR/.tack -> ../tack-src (dev-time layout); tack-src has
#              its own .git directory
# The checkout holds one representative of every pinned class plus two
# data files that must stay writable.
make_consumer() {
  dir=$1
  layout=$2
  mkdir -p "$dir/.git/hooks"
  case "$layout" in
    submodule)
      src="$dir/.tack"
      mkdir -p "$src" "$dir/.git/modules/tack/hooks"
      printf 'gitdir: ../.git/modules/tack\n' > "$src/.git"
      printf '#!/bin/sh\n' > "$dir/.git/modules/tack/hooks/pre-push"
      ;;
    symlink)
      src="$(dirname "$dir")/tack-src"
      mkdir -p "$src/.git/hooks"
      printf '#!/bin/sh\n' > "$src/.git/hooks/pre-push"
      ln -s ../tack-src "$dir/.tack"
      ;;
  esac
  mkdir -p "$src/configs/devenv" "$src/configs/python" "$src/configs/drupal/scripts" "$src/.moon"
  cp "$BWRAP_SH" "$src/configs/devenv/bwrap-run.sh"
  printf '#!/usr/bin/env bash\n' > "$src/tack.sh"
  printf '{ ... }: { }\n' > "$src/configs/python/python.nix"
  printf '#!/bin/sh\n' > "$src/configs/drupal/scripts/deploy.sh"
  printf 'line-length = 100\n' > "$src/configs/python/ruff.toml"
  printf 'ignore: []\n' > "$src/.moon/tack.yml"
}

# sbx_write DIR PATH -- append to PATH from inside the sandbox rooted at DIR.
sbx_write() {
  (cd "$1" && env BWRAP_REPO_ROOT="$1" bash "$BWRAP_SH" bash -c "echo x >> '$2'")
}

assert_tack_surface() {
  dir=$1
  hooks=$2
  # data stays writable
  run sbx_write "$dir" "$dir/.tack/configs/python/ruff.toml"
  assert_success
  run sbx_write "$dir" "$dir/.tack/.moon/tack.yml"
  assert_success
  # host-executed code is read-only
  for p in tack.sh configs/devenv/bwrap-run.sh configs/python/python.nix configs/drupal/scripts/deploy.sh; do
    run sbx_write "$dir" "$dir/.tack/$p"
    assert_failure
    assert_output --partial 'Read-only file system'
  done
  run sbx_write "$dir" "$hooks/pre-push"
  assert_failure
  assert_output --partial 'Read-only file system'
}

@test "ADR-0008: submodule .tack is writable except the pinned surface" {
  require_bwrap
  dir="$TARGET/consumer"
  make_consumer "$dir" submodule
  assert_tack_surface "$dir" "$dir/.git/modules/tack/hooks"
}

@test "ADR-0008: symlinked .tack is bound at its real path, writable except the pinned surface" {
  require_bwrap
  dir="$TARGET/consumer"
  make_consumer "$dir" symlink
  assert_tack_surface "$dir" "$TARGET/tack-src/.git/hooks"
}

@test "ADR-0008: BWRAP_STRICT=1 keeps all of .tack read-only" {
  require_bwrap
  dir="$TARGET/consumer"
  make_consumer "$dir" submodule
  (cd "$dir"
  run env BWRAP_REPO_ROOT="$dir" BWRAP_STRICT=1 bash "$BWRAP_SH" bash -c "echo x >> '$dir/.tack/configs/python/ruff.toml'"
  assert_failure
  assert_output --partial 'Read-only file system')
}
