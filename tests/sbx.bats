#!/usr/bin/env bats
# tests/sbx.bats - sbx sandbox integration tests
# bats --verbose-run tests/sbx.bats
#
# Covers the devenv template wiring (sbx scripts, tack input, disable
# switch) and the host-side tool resolution inside pkgs/sbx.sh. Running
# bwrap itself is not covered here; that is a host acceptance step in
# docs/sbx.md.

export BATS_LIB_PATH=/usr/lib/bats

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  bats_load_library bats-file

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"
  REPO="$(dirname "$HERE")"
  TACK_SH="$REPO/tack.sh"
  SBX_SH="$REPO/pkgs/sbx.sh"
  TARGET="$(mktemp -d -t tack-sbx.XXXXXX)"

  export TACK_ROOT="$REPO"
}

teardown() {
  rm -rf "$TARGET"
}

apply_devenv() {
  "$TACK_SH" --target "$TARGET" configs/devenv
}

# ---------- devenv template rendering ----------

@test "devenv renders sbx scripts for every default tool" {
  apply_devenv
  for tool in node npx pnpm moon cargo rustc; do
    run grep -F "${tool}.exec" "$TARGET/devenv.nix"
    assert_success
    run grep -F "exec sbx ${tool}" "$TARGET/devenv.nix"
    assert_success
  done
}

@test "devenv adds sbx packages and apparmor check when enabled" {
  apply_devenv
  run grep -F "inputs.tack.packages.\${pkgs.system}.sbx" "$TARGET/devenv.nix"
  assert_success
  run grep -F "inputs.tack.packages.\${pkgs.system}.sbx-apparmor" "$TARGET/devenv.nix"
  assert_success
  run grep -F "sbx-apparmor check --quiet" "$TARGET/devenv.nix"
  assert_success
}

@test "devenv yaml declares the tack input when enabled" {
  apply_devenv
  run grep -F "tack:" "$TARGET/devenv.yaml"
  assert_success
  run grep -F "url: github:tomdavidson/tack" "$TARGET/devenv.yaml"
  assert_success
}

@test "devenv omits all sbx wiring when disabled" {
  cat > "$TARGET/tackrc.yml" <<'EOF'
vars:
  sbx:
    enabled: false
EOF
  apply_devenv
  run grep -F "exec sbx" "$TARGET/devenv.nix"
  assert_failure
  run grep -F "inputs.tack" "$TARGET/devenv.nix"
  assert_failure
  run grep -F "tack:" "$TARGET/devenv.yaml"
  assert_failure
  # Base template still renders: the packages list closes plainly.
  run grep -F "]" "$TARGET/devenv.nix"
  assert_success
}

@test "devenv consumer tools list is honored" {
  cat > "$TARGET/tackrc.yml" <<'EOF'
vars:
  sbx:
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
      SBX_TEST_MARKER: present
EOF
  apply_devenv
  run grep -F 'SBX_TEST_MARKER = "present";' "$TARGET/devenv.nix"
  assert_success
}

# ---------- sbx host-side tool resolution ----------

@test "sbx --print-cmd resolves proto shims" {
  fake_proto="$TARGET/proto"
  mkdir -p "$fake_proto/shims"
  printf '#!/bin/sh\n' > "$fake_proto/shims/node"
  chmod +x "$fake_proto/shims/node"
  PROTO_HOME="$fake_proto" run bash "$SBX_SH" --print-cmd node
  assert_success
  assert_output "$fake_proto/shims/node"
}

@test "sbx --print-cmd resolves cargo bins" {
  fake_cargo="$TARGET/cargo"
  mkdir -p "$fake_cargo/bin"
  printf '#!/bin/sh\n' > "$fake_cargo/bin/cargo"
  chmod +x "$fake_cargo/bin/cargo"
  CARGO_HOME="$fake_cargo" run bash "$SBX_SH" --print-cmd cargo
  assert_success
  assert_output "$fake_cargo/bin/cargo"
}

@test "sbx --print-cmd skips devenv script wrappers on PATH" {
  fake_devenv="$TARGET/proj/.devenv/state/scripts"
  real_bin="$TARGET/real-bin"
  mkdir -p "$fake_devenv" "$real_bin"
  printf '#!/bin/sh\n' > "$fake_devenv/node"
  printf '#!/bin/sh\n' > "$real_bin/node"
  chmod +x "$fake_devenv/node" "$real_bin/node"
  PATH="$fake_devenv:$real_bin:$PATH" run bash "$SBX_SH" --print-cmd node
  assert_success
  assert_output "$real_bin/node"
}

@test "sbx --print-cmd resolves explicit paths verbatim" {
  run bash "$SBX_SH" --print-cmd /usr/bin/env
  assert_success
  assert_output "/usr/bin/env"
}
