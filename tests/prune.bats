#!/usr/bin/env bats
# tests/prune.bats - package-level tack.yml prune: list
#
# prune names subtrees find(1) never descends into. Unlike ignore (per-file
# filter, one log line per skipped file) a pruned subtree is logged once
# per pattern and its files are never visited by any pass (link/copy,
# render, concat, merge).

setup() {
  TACK_TEST_TMP="$(mktemp -d -t tack-prune.XXXXXX)"
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

# make_cache -- a moon-like runtime tree with many files plus a file that
# would otherwise be a protected-target problem if linked (.envrc is not
# used here; the point is volume and the content markers).
make_cache() {
  mkdir -p "$ALT_ROOT/configs/demo/cache/states/root" "$ALT_ROOT/configs/demo/cache/blobs/ab"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    printf '%s\n' "$i" > "$ALT_ROOT/configs/demo/cache/blobs/ab/blob$i"
  done
  printf '{}\n' > "$ALT_ROOT/configs/demo/cache/states/root/lastRun.json"
  printf 'x: 1\n' > "$ALT_ROOT/configs/demo/cache/states/pruned.merge.yml"
  printf 'r={{ vars.x | default(value=1) }}\n' > "$ALT_ROOT/configs/demo/cache/pruned.tera.txt"
  printf 'k\n' > "$ALT_ROOT/configs/demo/keep.txt"
}

@test "prune: dir/* pattern skips the whole subtree and logs once" {
  make_cache
  cat > "$ALT_ROOT/configs/demo/tack.yml" << 'EOF'
prune:
  - "cache/*"
EOF
  cat > "$CONSUMER/tackrc.yml" << 'EOF'
pkgs: ["configs/demo"]
EOF
  run_tack_pkgs
  [ "$status" -eq 0 ]
  [ -e "$CONSUMER/keep.txt" ]
  [ ! -e "$CONSUMER/cache" ]
  # exactly one prune line, no per-file exclude lines for the subtree
  [ "$(printf '%s\n' "$output" | grep -c 'prune: cache/\*')" -eq 1 ]
  [[ "$output" != *"exclude: cache/"* ]]
  [[ "$output" != *"blob1"* ]]
}

@test "prune: content markers inside a pruned subtree are never processed" {
  make_cache
  cat > "$ALT_ROOT/configs/demo/tack.yml" << 'EOF'
prune:
  - cache
EOF
  : > "$CONSUMER/tackrc.yml"
  run_tack
  [ "$status" -eq 0 ]
  [ ! -e "$CONSUMER/cache/pruned.txt" ]
  [ ! -e "$CONSUMER/cache/states/pruned.yml" ]
  [[ "$output" != *"render: cache/"* ]]
  [[ "$output" != *"merge: cache/"* ]]
}

@test "prune: applies under CLI selection (package contract)" {
  make_cache
  cat > "$ALT_ROOT/configs/demo/tack.yml" << 'EOF'
prune:
  - "cache/**"
EOF
  : > "$CONSUMER/tackrc.yml"
  run_tack
  [ "$status" -eq 0 ]
  [ -e "$CONSUMER/keep.txt" ]
  [ ! -e "$CONSUMER/cache" ]
}

@test "prune: glob in the directory part is passed to find -path" {
  mkdir -p "$ALT_ROOT/configs/demo/a/node_modules/x" "$ALT_ROOT/configs/demo/b/node_modules/y"
  printf 'x\n' > "$ALT_ROOT/configs/demo/a/node_modules/x/index.js"
  printf 'y\n' > "$ALT_ROOT/configs/demo/b/node_modules/y/index.js"
  printf 'k\n' > "$ALT_ROOT/configs/demo/a/keep.js"
  cat > "$ALT_ROOT/configs/demo/tack.yml" << 'EOF'
prune:
  - "*/node_modules"
EOF
  : > "$CONSUMER/tackrc.yml"
  run_tack
  [ "$status" -eq 0 ]
  [ -e "$CONSUMER/a/keep.js" ]
  [ ! -e "$CONSUMER/a/node_modules" ]
  [ ! -e "$CONSUMER/b/node_modules" ]
}

@test "prune: missing key is a no-op and ignore still works alongside" {
  make_cache
  printf 's\n' > "$ALT_ROOT/configs/demo/skip.txt"
  cat > "$ALT_ROOT/configs/demo/tack.yml" << 'EOF'
ignore:
  - skip.txt
prune:
  - "cache/*"
EOF
  : > "$CONSUMER/tackrc.yml"
  run_tack
  [ "$status" -eq 0 ]
  [ -e "$CONSUMER/keep.txt" ]
  [ ! -e "$CONSUMER/skip.txt" ]
  [ ! -e "$CONSUMER/cache" ]
  [[ "$output" == *"exclude: skip.txt"* ]]
}

@test "prune: malformed scalar is rejected with a clear error" {
  make_cache
  cat > "$ALT_ROOT/configs/demo/tack.yml" << 'EOF'
prune:
  cache/*
EOF
  : > "$CONSUMER/tackrc.yml"
  run_tack
  [ "$status" -ne 0 ]
  [[ "$output" == *"prune"* ]]
  [[ "$output" == *"list"* || "$output" == *"sequence"* ]]
}
