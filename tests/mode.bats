#!/usr/bin/env bats
# tests/mode.bats - mode rule precedence and dispatch

setup() {
  TACK_TEST_TMP="$(mktemp -d -t tack-mode.XXXXXX)"
  TACK_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  ALT_ROOT="$TACK_TEST_TMP/tack"
  mkdir -p "$ALT_ROOT/configs/demo"
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
  TACK_ROOT="$ALT_ROOT" run "$ALT_ROOT/tack.sh" --target "$CONSUMER" configs/demo
}

run_tack_pkgs() {
  TACK_ROOT="$ALT_ROOT" run "$ALT_ROOT/tack.sh" --target "$CONSUMER"
}

# ----- default behavior -----

@test "mode default: plain file is symlinked" {
  printf 'hello\n' > "$ALT_ROOT/configs/demo/plain.txt"
  run_tack
  [ "$status" -eq 0 ]
  [ -L "$CONSUMER/plain.txt" ]
}

@test "mode default: .copy. marker file is copied not linked" {
  printf 'hi\n' > "$ALT_ROOT/configs/demo/foo.copy.txt"
  run_tack
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/foo.txt" ]
  run test -L "$CONSUMER/foo.txt"
  [ "$status" -ne 0 ]
}

# ----- package mode rules -----

@test "package mode: copy rule overrides default link" {
  printf 'hello\n' > "$ALT_ROOT/configs/demo/plain.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
mode:
  - copy: "plain.txt"
EOF
  run_tack
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/plain.txt" ]
  run test -L "$CONSUMER/plain.txt"
  [ "$status" -ne 0 ]
}

@test "package mode: link rule overrides .copy. marker" {
  printf 'hi\n' > "$ALT_ROOT/configs/demo/foo.copy.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
mode:
  - link: "foo.copy.txt"
EOF
  run_tack
  [ "$status" -eq 0 ]
  [ -L "$CONSUMER/foo.copy.txt" ]
}

@test "package mode: glob list value matches multiple files" {
  mkdir -p "$ALT_ROOT/configs/demo/sub"
  printf 'a\n' > "$ALT_ROOT/configs/demo/a.yml"
  printf 'b\n' > "$ALT_ROOT/configs/demo/sub/b.yml"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
mode:
  - copy: ["a.yml", "sub/**/*.yml"]
EOF
  run_tack
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/a.yml" ]; run test -L "$CONSUMER/a.yml"; [ "$status" -ne 0 ]
  [ -f "$CONSUMER/sub/b.yml" ]; run test -L "$CONSUMER/sub/b.yml"; [ "$status" -ne 0 ]
}

@test "package mode: first match wins for overlapping rules" {
  printf 'x\n' > "$ALT_ROOT/configs/demo/a.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
mode:
  - copy: "a.txt"
  - link: "**"
EOF
  run_tack
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/a.txt" ]; run test -L "$CONSUMER/a.txt"; [ "$status" -ne 0 ]
}

# ----- consumer override -----

@test "consumer mode: copy rule wins over package link rule" {
  printf 'x\n' > "$ALT_ROOT/configs/demo/a.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
mode:
  - link: "**"
EOF
  cat > "$CONSUMER/tackrc.yml" <<'EOF'
pkgs: ["configs/demo"]
overrides:
  configs/demo:
    mode:
      - copy: "a.txt"
EOF
  run_tack_pkgs
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/a.txt" ]; run test -L "$CONSUMER/a.txt"; [ "$status" -ne 0 ]
}

@test "consumer mode: link rule wins over package copy rule" {
  printf 'x\n' > "$ALT_ROOT/configs/demo/a.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
mode:
  - copy: "**"
EOF
  cat > "$CONSUMER/tackrc.yml" <<'EOF'
pkgs: ["configs/demo"]
overrides:
  configs/demo:
    mode:
      - link: "a.txt"
EOF
  run_tack_pkgs
  [ "$status" -eq 0 ]
  [ -L "$CONSUMER/a.txt" ]
}

# ----- content markers unaffected -----

@test "content marker: .merge.json unaffected by mode link rule" {
  printf '{"x":1}' > "$ALT_ROOT/configs/demo/a.merge.json"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
mode:
  - link: "**"
files:
  a.merge.json:
    target: out.json
EOF
  run_tack
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/out.json" ]
  run test -L "$CONSUMER/out.json"
  [ "$status" -ne 0 ]
  v=$(yq -p json -o json '.x' "$CONSUMER/out.json")
  [ "$v" = "1" ]
}

# ----- excludes drop before mode -----

@test "excludes drop file before mode resolution" {
  printf 'x\n' > "$ALT_ROOT/configs/demo/skip.txt"
  printf 'y\n' > "$ALT_ROOT/configs/demo/keep.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
mode:
  - copy: "**"
EOF
  cat > "$CONSUMER/tackrc.yml" <<'EOF'
pkgs: ["configs/demo"]
overrides:
  configs/demo:
    exclude: ["skip.txt"]
EOF
  run_tack_pkgs
  [ "$status" -eq 0 ]
  [ ! -e "$CONSUMER/skip.txt" ]
  [ -f "$CONSUMER/keep.txt" ]
}
