#!/usr/bin/env bats
# bwrap sandbox integration tests
# bats --verbose-run configs/devenv/tests/bwrap.bats
#
# Covers the devenv template wiring (bwrap-run wrappers, .tack namespace,
# disable switch) and the host-side tool resolution + repo root detection
# inside configs/devenv/bwrap-run.sh. Running bwrap itself is only exercised
# by the root-detection tests below (skipped when bwrap is unavailable);
# full sandbox behavior is a host acceptance step in docs/bwrap.md.

export BATS_LIB_PATH=/usr/lib/bats

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
  run grep -F "DEVENV_ROOT" "$TARGET/devenv.nix"
  assert_failure
  run grep -F 'PWD' "$TARGET/devenv.nix"
  assert_failure
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
  mkdir -p "$fake_devenv" "$real_bin"
  printf '#!/bin/sh\n' > "$fake_devenv/node"
  printf '#!/bin/sh\n' > "$real_bin/node"
  chmod +x "$fake_devenv/node" "$real_bin/node"
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
  command -v bwrap >/dev/null 2>&1 || skip "bwrap not available"
  tree="$TARGET/tree"
  make_tree "$tree"
  (cd "$tree/mod"
  run bash "$BWRAP_SH" bash -c "touch '$tree/marker'"
  assert_success
  assert_file_exists "$tree/marker")
}

@test "root fallback stops at a linked worktree .git file" {
  command -v bwrap >/dev/null 2>&1 || skip "bwrap not available"
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
  command -v bwrap >/dev/null 2>&1 || skip "bwrap not available"
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
