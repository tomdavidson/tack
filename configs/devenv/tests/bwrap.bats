#!/usr/bin/env bats
# bwrap sandbox integration tests
# bats --verbose-run configs/devenv/tests/bwrap.bats
#
# Covers the devenv template wiring (bwrap-run scripts, sandbox script
# distribution, disable switch) and the host-side tool resolution inside
# configs/devenv/bwrap-run.sh. Running bwrap itself is not covered here;
# that is a host acceptance step in docs/bwrap.md.

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

# ---------- devenv template rendering ----------

@test "devenv renders bwrap-run scripts for every default tool" {
  apply_devenv
  for tool in node npx pnpm moon cargo rustc; do
    run grep -F "${tool}.exec" "$TARGET/devenv.nix"
    assert_success
    run grep -F "exec bwrap-run ${tool}" "$TARGET/devenv.nix"
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

@test "sandbox scripts are distributed as executable consumer-owned files" {
  apply_devenv
  assert_file_exists "$TARGET/bwrap-run.sh"
  assert_file_exists "$TARGET/bwrap-apparmor.sh"
  assert_file_executable "$TARGET/bwrap-run.sh"
  assert_file_executable "$TARGET/bwrap-apparmor.sh"
}

@test "re-apply does not overwrite consumer edits to the sandbox scripts" {
  apply_devenv
  echo "# consumer edit" >> "$TARGET/bwrap-run.sh"
  apply_devenv
  run grep -F "# consumer edit" "$TARGET/bwrap-run.sh"
  assert_success
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
  run grep -F "exec bwrap-run" "$TARGET/devenv.nix"
  assert_failure
  run grep -F "bubblewrap" "$TARGET/devenv.nix"
  assert_failure
  # The sandbox scripts are still distributed: they are plain files whose
  # distribution is not gated on vars.bwrap.enabled.
  assert_file_exists "$TARGET/bwrap-run.sh"
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
