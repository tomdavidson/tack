#!/usr/bin/env bats
# tests/ignore.bats - package-level tack.yml ignore: list

setup() {
  TACK_TEST_TMP="$(mktemp -d -t tack-ignore.XXXXXX)"
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

# ----- package-declared ignore -----

@test "ignore: single literal pattern skips matching file" {
  printf 'k\n' > "$ALT_ROOT/configs/demo/keep.txt"
  printf 's\n' > "$ALT_ROOT/configs/demo/skip.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
ignore:
  - skip.txt
EOF
  cat > "$CONSUMER/tackrc.yml" <<'EOF'
pkgs: ["configs/demo"]
EOF
  run_tack_pkgs
  [ "$status" -eq 0 ]
  [ -e "$CONSUMER/keep.txt" ]
  [ ! -e "$CONSUMER/skip.txt" ]
}

@test "ignore: * glob crosses path separators (case-glob semantics)" {
  mkdir -p "$ALT_ROOT/configs/demo/src/debug" "$ALT_ROOT/configs/demo/src/nested/deep"
  printf 'k\n' > "$ALT_ROOT/configs/demo/src/keep.sh"
  printf 's\n' > "$ALT_ROOT/configs/demo/src/debug/a.local.sh"
  printf 's\n' > "$ALT_ROOT/configs/demo/src/nested/deep/b.local.sh"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
ignore:
  - "*.local.*"
EOF
  cat > "$CONSUMER/tackrc.yml" <<'EOF'
pkgs: ["configs/demo"]
EOF
  run_tack_pkgs
  [ "$status" -eq 0 ]
  [ -e "$CONSUMER/src/keep.sh" ]
  [ ! -e "$CONSUMER/src/debug/a.local.sh" ]
  [ ! -e "$CONSUMER/src/nested/deep/b.local.sh" ]
}

@test "ignore: multiple patterns all apply" {
  printf 'a\n' > "$ALT_ROOT/configs/demo/a.txt"
  printf 'b\n' > "$ALT_ROOT/configs/demo/b.txt"
  printf 'c\n' > "$ALT_ROOT/configs/demo/c.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
ignore:
  - b.txt
  - c.txt
EOF
  cat > "$CONSUMER/tackrc.yml" <<'EOF'
pkgs: ["configs/demo"]
EOF
  run_tack_pkgs
  [ "$status" -eq 0 ]
  [ -e "$CONSUMER/a.txt" ]
  [ ! -e "$CONSUMER/b.txt" ]
  [ ! -e "$CONSUMER/c.txt" ]
}

# ----- union with consumer overrides -----

@test "ignore: unions with consumer overrides.<pkg>.exclude" {
  printf 'k\n' > "$ALT_ROOT/configs/demo/kept.txt"
  printf 'p\n' > "$ALT_ROOT/configs/demo/pkg-skip.txt"
  printf 'c\n' > "$ALT_ROOT/configs/demo/consumer-skip.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
ignore:
  - pkg-skip.txt
EOF
  cat > "$CONSUMER/tackrc.yml" <<'EOF'
pkgs: ["configs/demo"]
overrides:
  configs/demo:
    exclude: ["consumer-skip.txt"]
EOF
  run_tack_pkgs
  [ "$status" -eq 0 ]
  [ -e "$CONSUMER/kept.txt" ]
  [ ! -e "$CONSUMER/pkg-skip.txt" ]
  [ ! -e "$CONSUMER/consumer-skip.txt" ]
}

# ----- CLI selection precedence -----

@test "ignore: package ignore applies under CLI selection (package contract)" {
  printf 'k\n' > "$ALT_ROOT/configs/demo/kept.txt"
  printf 'p\n' > "$ALT_ROOT/configs/demo/pkg-skip.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
ignore:
  - pkg-skip.txt
EOF
  : > "$CONSUMER/tackrc.yml"
  run_tack
  [ "$status" -eq 0 ]
  [ -e "$CONSUMER/kept.txt" ]
  [ ! -e "$CONSUMER/pkg-skip.txt" ]
}

@test "ignore: consumer excludes still bypassed under CLI selection" {
  printf 'k\n' > "$ALT_ROOT/configs/demo/kept.txt"
  printf 'c\n' > "$ALT_ROOT/configs/demo/consumer-skip.txt"
  : > "$ALT_ROOT/configs/demo/tack.yml"
  cat > "$CONSUMER/tackrc.yml" <<'EOF'
overrides:
  configs/demo:
    exclude: ["consumer-skip.txt"]
EOF
  run_tack
  [ "$status" -eq 0 ]
  [ -e "$CONSUMER/kept.txt" ]
  [ -e "$CONSUMER/consumer-skip.txt" ]
}

# ----- no-op cases -----

@test "ignore: missing key is a no-op" {
  printf 'a\n' > "$ALT_ROOT/configs/demo/a.txt"
  printf 'b\n' > "$ALT_ROOT/configs/demo/b.txt"
  : > "$ALT_ROOT/configs/demo/tack.yml"
  cat > "$CONSUMER/tackrc.yml" <<'EOF'
pkgs: ["configs/demo"]
EOF
  run_tack_pkgs
  [ "$status" -eq 0 ]
  [ -e "$CONSUMER/a.txt" ]
  [ -e "$CONSUMER/b.txt" ]
}

@test "ignore: applies to content markers (merge file is skipped)" {
  printf '{"x":1}' > "$ALT_ROOT/configs/demo/a.merge.json"
  printf '{"y":2}' > "$ALT_ROOT/configs/demo/b.merge.json"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
ignore:
  - a.merge.json
EOF
  cat > "$CONSUMER/tackrc.yml" <<'EOF'
pkgs: ["configs/demo"]
EOF
  run_tack_pkgs
  [ "$status" -eq 0 ]
  [ ! -e "$CONSUMER/a.json" ]
  [ -f "$CONSUMER/b.json" ]
}

# ----- ignore source vs rendered output -----

@test "ignore: ignoring source name does not block tera rendering to that name" {
  printf 'literal: true\n' > "$ALT_ROOT/configs/demo/workspace.yml"
  printf 'rendered: {{ vars.who | default(value=\"world\") }}\n' > "$ALT_ROOT/configs/demo/workspace.tera.yml"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
ignore:
  - workspace.yml
EOF
  cat > "$CONSUMER/tackrc.yml" <<'EOF'
pkgs: ["configs/demo"]
vars:
  who: tack
EOF
  run_tack_pkgs
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/workspace.yml" ]
  run cat "$CONSUMER/workspace.yml"
  [[ "$output" == *"rendered: tack"* ]]
  [[ "$output" != *"literal: true"* ]]
}

@test "ignore: malformed scalar (block-folded) is rejected with a clear error" {
  printf 't\n' > "$ALT_ROOT/configs/demo/toolchains.yml"
  printf 'w\n' > "$ALT_ROOT/configs/demo/workspace.yml"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
ignore:
  toolchains.yml
  workspace.yml
EOF
  cat > "$CONSUMER/tackrc.yml" <<'EOF'
pkgs: ["configs/demo"]
EOF
  run_tack_pkgs
  [ "$status" -ne 0 ]
  [[ "$output" == *"ignore"* ]]
  [[ "$output" == *"list"* || "$output" == *"sequence"* ]]
}

# ----- conflict resolution: re-apply same package -----

@test "link: re-applying a package is idempotent (lnko branch)" {
  mkdir -p "$ALT_ROOT/configs/demo/templates/astro-plugin"
  printf 'pkg\n' > "$ALT_ROOT/configs/demo/templates/astro-plugin/package.json"
  : > "$ALT_ROOT/configs/demo/tack.yml"
  cat > "$CONSUMER/tackrc.yml" <<'EOF'
pkgs: ["configs/demo"]
EOF
  run_tack_pkgs
  [ "$status" -eq 0 ]
  [ -e "$CONSUMER/templates/astro-plugin/package.json" ]
  run_tack_pkgs
  [ "$status" -eq 0 ]
  [[ "$output" != *"are the same file"* ]]
  [[ "$output" != *"aborted:"* ]]
}

@test "link: re-applying is idempotent under per-file branch (active ignore)" {
  mkdir -p "$ALT_ROOT/configs/demo/templates/astro-plugin"
  printf 'pkg\n' > "$ALT_ROOT/configs/demo/templates/astro-plugin/package.json"
  printf 'x\n' > "$ALT_ROOT/configs/demo/skip.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" <<'EOF'
ignore:
  - skip.txt
EOF
  cat > "$CONSUMER/tackrc.yml" <<'EOF'
pkgs: ["configs/demo"]
EOF
  run_tack_pkgs
  [ "$status" -eq 0 ]
  run_tack_pkgs
  [ "$status" -eq 0 ]
  [[ "$output" != *"are the same file"* ]]
  [[ "$output" != *"aborted:"* ]]
  [ ! -e "$CONSUMER/skip.txt" ]
}
