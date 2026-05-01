#!/usr/bin/env bats
# tests/overwrite.bats - files.<src>.overwrite: false skip-on-exists across modes

setup() {
  TACK_TEST_TMP="$(mktemp -d -t tack-ow.XXXXXX)"
  TACK_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TACK_ROOT

  ALT_ROOT="$TACK_TEST_TMP/tack"
  mkdir -p "$ALT_ROOT/configs/demo"
  printf 'vars: {}\n' > "$ALT_ROOT/tackrc-defaults.yml"
  cp "$TACK_ROOT/tack.sh" "$ALT_ROOT/tack.sh"
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

# ----- copy mode -----

@test "overwrite false: copy creates first run, skips second when target exists" {
  printf 'pkg-content\n' > "$ALT_ROOT/configs/demo/cfg.copy.json"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
files:
  cfg.copy.json:
    overwrite: false
EOF
  run_tack
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/cfg.json" ]
  printf 'consumer-edit\n' > "$CONSUMER/cfg.json"
  run_tack
  [ "$status" -eq 0 ]
  [ "$(cat "$CONSUMER/cfg.json")" = "consumer-edit" ]
}

# ----- render mode -----

@test "overwrite false: render creates first run, skips second" {
  printf 'rendered={{ vars.x | default(value="x") }}\n' > "$ALT_ROOT/configs/demo/r.tera.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
files:
  r.tera.txt:
    overwrite: false
EOF
  run_tack
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/r.txt" ]
  printf 'consumer-rendered\n' > "$CONSUMER/r.txt"
  run_tack
  [ "$status" -eq 0 ]
  [ "$(cat "$CONSUMER/r.txt")" = "consumer-rendered" ]
}

# ----- concat mode -----

@test "overwrite false: concat creates first run, skips second" {
  printf 'fragment-line\n' > "$ALT_ROOT/configs/demo/n.concat.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
files:
  n.concat.txt:
    overwrite: false
EOF
  run_tack
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/n.txt" ]
  before=$(wc -c < "$CONSUMER/n.txt")
  run_tack
  [ "$status" -eq 0 ]
  after=$(wc -c < "$CONSUMER/n.txt")
  [ "$before" = "$after" ]
}

# ----- merge mode -----

@test "overwrite false: merge creates first run, leaves consumer edits on second" {
  printf '{"v":1}\n' > "$ALT_ROOT/configs/demo/m.merge.json"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
files:
  m.merge.json:
    overwrite: false
EOF
  run_tack
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/m.json" ]
  printf '{"v":99,"consumer":true}\n' > "$CONSUMER/m.json"
  run_tack
  [ "$status" -eq 0 ]
  v=$(yq -p json -o json '.v' "$CONSUMER/m.json")
  [ "$v" = "99" ]
  c=$(yq -p json -o json '.consumer' "$CONSUMER/m.json")
  [ "$c" = "true" ]
}

# ----- link mode coercion -----

@test "overwrite false: unmarked file under link mode is coerced to copy and skips on second run" {
  printf 'pkg-plain\n' > "$ALT_ROOT/configs/demo/file.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
mode:
  - link: "**"
files:
  file.txt:
    overwrite: false
EOF
  run_tack
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/file.txt" ]
  [ ! -L "$CONSUMER/file.txt" ]
  printf 'consumer-plain\n' > "$CONSUMER/file.txt"
  run_tack
  [ "$status" -eq 0 ]
  [ "$(cat "$CONSUMER/file.txt")" = "consumer-plain" ]
}

# ----- default behavior unchanged -----

@test "overwrite default true: copy still stomps on second run" {
  printf 'pkg-content-v1\n' > "$ALT_ROOT/configs/demo/cfg.copy.json"
  run_tack
  [ "$status" -eq 0 ]
  printf 'consumer-edit\n' > "$CONSUMER/cfg.json"
  run_tack
  [ "$status" -eq 0 ]
  [ "$(cat "$CONSUMER/cfg.json")" = "pkg-content-v1" ]
}
