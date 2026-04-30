#!/usr/bin/env bats
# tests/path_prefix.bats - path_prefix and files.<src>.target across dispatch types

setup() {
  TACK_TEST_TMP="$(mktemp -d -t tack-pp.XXXXXX)"
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

# ----- concat create-on-missing -----

@test "concat: missing target is created from fragment without leading newline" {
  printf 'alpha=1\nbeta=2\n' > "$ALT_ROOT/configs/demo/notes.concat.txt"
  [ ! -e "$CONSUMER/notes.txt" ]
  run_tack
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/notes.txt" ]
  # First byte must be 'a' (no leading newline on create)
  first=$(head -c 1 "$CONSUMER/notes.txt")
  [ "$first" = "a" ]
  diff "$CONSUMER/notes.txt" "$ALT_ROOT/configs/demo/notes.concat.txt"
}

@test "concat: create-on-missing then re-run is idempotent" {
  printf 'alpha=1\nbeta=2\n' > "$ALT_ROOT/configs/demo/notes.concat.txt"
  run_tack
  [ "$status" -eq 0 ]
  before=$(cat "$CONSUMER/notes.txt")
  run_tack
  [ "$status" -eq 0 ]
  after=$(cat "$CONSUMER/notes.txt")
  [ "$before" = "$after" ]
}

# ----- files.<src>.target across dispatch types -----

@test "files.target: overrides render destination" {
  printf 'hello {{ vars.name }}\n' > "$ALT_ROOT/configs/demo/greeting.tera.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
files:
  greeting.tera.txt:
    vars_from: '@tack/tackrc-defaults.yml'
    target: out/g.txt
EOF
  printf 'vars:\n  name: world\n' > "$ALT_ROOT/tackrc-defaults.yml"
  run_tack
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/out/g.txt" ]
  [ ! -f "$CONSUMER/greeting.txt" ]
  grep -q 'hello world' "$CONSUMER/out/g.txt"
}

@test "files.target: overrides copy marker destination" {
  printf 'x\n' > "$ALT_ROOT/configs/demo/cfg.copy.json"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
files:
  cfg.copy.json:
    target: elsewhere/x.json
EOF
  run_tack
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/elsewhere/x.json" ]
  [ ! -e "$CONSUMER/cfg.json" ]
}

@test "files.target on unmarked file forces copy mode (no symlink)" {
  printf 'plain\n' > "$ALT_ROOT/configs/demo/file.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
mode:
  - link: "**"
files:
  file.txt:
    target: out.txt
EOF
  run_tack
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/out.txt" ]
  [ ! -L "$CONSUMER/out.txt" ]
}

# ----- path_prefix -----

@test "path_prefix: prefixes derived render/copy/concat/merge targets" {
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
path_prefix: sub
files:
  r.tera.txt:
    vars_from: '@tack/tackrc-defaults.yml'
EOF
  printf 'vars:\n  x: hi\n' > "$ALT_ROOT/tackrc-defaults.yml"
  printf 'r={{ vars.x }}\n' > "$ALT_ROOT/configs/demo/r.tera.txt"
  printf 'c=1\n' > "$ALT_ROOT/configs/demo/c.copy.txt"
  printf 'k=1\n' > "$ALT_ROOT/configs/demo/n.concat.txt"
  printf '{"a":1}\n' > "$ALT_ROOT/configs/demo/m.merge.json"
  run_tack
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/sub/r.txt" ]
  [ -f "$CONSUMER/sub/c.txt" ]
  [ -f "$CONSUMER/sub/n.txt" ]
  [ -f "$CONSUMER/sub/m.json" ]
  [ ! -e "$CONSUMER/r.txt" ]
  [ ! -e "$CONSUMER/c.txt" ]
  [ ! -e "$CONSUMER/n.txt" ]
  [ ! -e "$CONSUMER/m.json" ]
}

@test "path_prefix: link mode lands symlinks under the prefix" {
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
path_prefix: sub
EOF
  printf 'data\n' > "$ALT_ROOT/configs/demo/conf.yml"
  run_tack
  [ "$status" -eq 0 ]
  [ -L "$CONSUMER/sub/conf.yml" ]
  [ ! -e "$CONSUMER/conf.yml" ]
}

@test "files.target escapes path_prefix" {
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
path_prefix: sub
files:
  root.copy.yml:
    target: root.yml
EOF
  printf 'inside\n' > "$ALT_ROOT/configs/demo/inner.copy.yml"
  printf 'outside\n' > "$ALT_ROOT/configs/demo/root.copy.yml"
  run_tack
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/sub/inner.yml" ]
  [ -f "$CONSUMER/root.yml" ]
  [ ! -e "$CONSUMER/sub/root.yml" ]
}
