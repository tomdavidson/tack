#!/usr/bin/env bats
# tests/protected.bats - ADR-0008 protected consumer paths
#
# tack.sh refuses to write, link, or redirect into files the host executes
# outside any sandbox (.envrc, devenv.*, flake.*, nix/, .git/, .tack/)
# unless the SOURCE is itself read-only inside the bwrap sandbox:
# configs/devenv/** or a *.nix module. A writable package manifest must
# not be able to steer content into those paths.

setup() {
  TACK_TEST_TMP="$(mktemp -d -t tack-protected.XXXXXX)"
  TACK_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  ALT_ROOT="$TACK_TEST_TMP/tack"
  mkdir -p "$ALT_ROOT/configs/demo" "$ALT_ROOT/configs/devenv"
  printf 'vars: {}\n' > "$ALT_ROOT/tackrc-defaults.yml"
  cp "$TACK_ROOT_REAL/tack.sh" "$ALT_ROOT/tack.sh"
  chmod +x "$ALT_ROOT/tack.sh"

  CONSUMER="$TACK_TEST_TMP/consumer"
  mkdir -p "$CONSUMER"

  export ALT_ROOT CONSUMER
}

teardown() {
  rm -rf "$TACK_TEST_TMP"
}

run_tack() {
  TACK_ROOT="$ALT_ROOT" run "$ALT_ROOT/tack.sh" --target "$CONSUMER" "$@"
}

assert_refused() {
  [ "$status" -ne 0 ]
  [[ "$output" == *"protected consumer path"* ]]
  [[ "$output" == *"ADR-0008"* ]]
}

# ----- refused: data packages cannot reach host-executed files -----

@test "protected: link-mode file named .envrc in a data package is refused" {
  printf 'export PWNED=1\n' > "$ALT_ROOT/configs/demo/.envrc"
  : > "$ALT_ROOT/configs/demo/tack.yml"
  run_tack configs/demo
  assert_refused
  [ ! -e "$CONSUMER/.envrc" ]
}

@test "protected: files.<src>.target redirect to devenv.nix is refused" {
  printf '{ }\n' > "$ALT_ROOT/configs/demo/innocent.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
files:
  innocent.txt:
    target: devenv.nix
EOF
  run_tack configs/demo
  assert_refused
  [ ! -e "$CONSUMER/devenv.nix" ]
}

@test "protected: files.<src>.target redirect into .git/hooks is refused" {
  mkdir -p "$CONSUMER/.git/hooks"
  printf '#!/bin/sh\necho pwned\n' > "$ALT_ROOT/configs/demo/hook.sh"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
files:
  hook.sh:
    target: .git/hooks/pre-push
EOF
  run_tack configs/demo
  assert_refused
  [ ! -e "$CONSUMER/.git/hooks/pre-push" ]
}

@test "protected: tera render targeting .envrc from a data package is refused" {
  printf 'export X={{ vars.x | default(value=1) }}\n' > "$ALT_ROOT/configs/demo/.envrc.tera.sh"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
files:
  .envrc.tera.sh:
    target: .envrc
EOF
  run_tack configs/demo
  assert_refused
  [ ! -e "$CONSUMER/.envrc" ]
}

@test "protected: concat into flake.lock from a non-nix source is refused" {
  printf '{}\n' > "$ALT_ROOT/configs/demo/flake.concat.lock"
  : > "$ALT_ROOT/configs/demo/tack.yml"
  run_tack configs/demo
  assert_refused
  [ ! -e "$CONSUMER/flake.lock" ]
}

@test "protected: path traversal in a target override is refused" {
  printf 'x\n' > "$ALT_ROOT/configs/demo/a.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
files:
  a.txt:
    target: ../escape.txt
EOF
  run_tack configs/demo
  assert_refused
  [ ! -e "$TACK_TEST_TMP/escape.txt" ]
}

@test "protected: linking into .tack/ itself is refused" {
  printf 'x\n' > "$ALT_ROOT/configs/demo/a.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
path_prefix: .tack
EOF
  run_tack configs/demo
  assert_refused
}

# ----- allowed: pinned sources may produce host-executed files -----

@test "protected: configs/devenv may write .envrc" {
  printf 'use devenv\n' > "$ALT_ROOT/configs/devenv/.envrc"
  : > "$ALT_ROOT/configs/devenv/tack.yml"
  run_tack configs/devenv
  [ "$status" -eq 0 ]
  [ -e "$CONSUMER/.envrc" ]
}

@test "protected: a *.nix source may concat into devenv.nix" {
  printf '{ }\n' > "$CONSUMER/devenv.nix"
  printf '# php fragment\n{ languages.php.enable = true; }\n' > "$ALT_ROOT/configs/demo/devenv.concat.nix"
  : > "$ALT_ROOT/configs/demo/tack.yml"
  run_tack configs/demo
  [ "$status" -eq 0 ]
  run cat "$CONSUMER/devenv.nix"
  [[ "$output" == *"languages.php.enable"* ]]
}

@test "protected: ordinary data files from a data package are unaffected" {
  printf 'line-length = 100\n' > "$ALT_ROOT/configs/demo/ruff.toml"
  mkdir -p "$ALT_ROOT/configs/demo/.moon/tasks"
  printf 'tasks: {}\n' > "$ALT_ROOT/configs/demo/.moon/tasks/python.yml"
  : > "$ALT_ROOT/configs/demo/tack.yml"
  run_tack configs/demo
  [ "$status" -eq 0 ]
  [ -e "$CONSUMER/ruff.toml" ]
  [ -e "$CONSUMER/.moon/tasks/python.yml" ]
}

# ----- sandbox selection -----

@test "protected: helpers run direct when TACK_ROOT is not the consumer's .tack" {
  printf 'x\n' > "$ALT_ROOT/configs/demo/a.txt"
  : > "$ALT_ROOT/configs/demo/tack.yml"
  run_tack configs/demo
  [ "$status" -eq 0 ]
  [[ "$output" != *"run sandboxed via bwrap-run"* ]]
  [ -e "$CONSUMER/a.txt" ]
}

@test "protected: TACK_SANDBOX=0 forces direct helpers even for a consumer .tack" {
  ln -s ../tack "$CONSUMER/.tack"
  printf 'x\n' > "$ALT_ROOT/configs/demo/a.txt"
  : > "$ALT_ROOT/configs/demo/tack.yml"
  TACK_SANDBOX=0 run_tack configs/demo
  [ "$status" -eq 0 ]
  [[ "$output" != *"run sandboxed via bwrap-run"* ]]
  [ -e "$CONSUMER/a.txt" ]
}
