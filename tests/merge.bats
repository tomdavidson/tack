#!/usr/bin/env bats
# tests/merge.bats - *.merge.json and *.merge.{yml,yaml} dispatch

setup() {
  TACK_TEST_TMP="$(mktemp -d -t tack-merge.XXXXXX)"
  TACK_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TACK_ROOT

  # Build an isolated tack root mirror so we can drop fragments under
  # configs/demo/ without polluting the real repo. tack.sh resolves
  # configs/<pkg> from $TACK_ROOT, and we override that env var per test.
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

# write_pkg <frag-basename> <frag-body> <target-path-rel-to-consumer> <target-body>
# Manifest declares files[<frag-basename>].target = <target-path-rel-to-consumer>.
write_pkg() {
  frag_name="$1"; frag_body="$2"; tgt_rel="$3"; tgt_body="$4"
  printf '%s' "$frag_body" > "$ALT_ROOT/configs/demo/$frag_name"
  cat > "$ALT_ROOT/configs/demo/tack-manifest.yml" <<EOF
files:
  $frag_name:
    target: $tgt_rel
EOF
  mkdir -p "$(dirname "$CONSUMER/$tgt_rel")"
  printf '%s' "$tgt_body" > "$CONSUMER/$tgt_rel"
}

run_tack() {
  TACK_ROOT="$ALT_ROOT" run "$ALT_ROOT/tack.sh" --target "$CONSUMER" configs/demo
}

# ----- Refusals -----

@test "merge: refuses *.merge.toml with concat suggestion" {
  write_pkg clippy.merge.toml '[lints]
foo = "warn"
' target.toml '[a]
x = 1
'
  run_tack
  [ "$status" -ne 0 ]
  [[ "$output" == *"*.merge.toml not supported"* ]]
  [[ "$output" == *"*.concat.toml"* ]]
  grep -q '\[a\]' "$CONSUMER/target.toml"
}

@test "merge: refuses unknown extension" {
  write_pkg foo.merge.xml '<a/>' foo.xml '<b/>'
  run_tack
  [ "$status" -ne 0 ]
  [[ "$output" == *"*.merge.xml unsupported"* ]]
}

@test "merge: malformed fragment fails before touching target" {
  write_pkg bad.merge.json '{ this is not json' package.json '{"name":"x"}'
  run_tack
  [ "$status" -ne 0 ]
  [[ "$output" == *"not valid json"* ]]
  grep -q '"name":"x"' "$CONSUMER/package.json"
}

@test "merge: malformed target reports target, not fragment" {
  write_pkg add.merge.json '{"v":1}' package.json '{ broken'
  run_tack
  [ "$status" -ne 0 ]
  [[ "$output" == *"target is not valid json"* ]]
}

@test "merge: missing target file errors with path" {
  printf '{"x":1}' > "$ALT_ROOT/configs/demo/a.merge.json"
  cat > "$ALT_ROOT/configs/demo/tack-manifest.yml" <<'EOF'
files:
  a.merge.json:
    target: missing.json
EOF
  run_tack
  [ "$status" -ne 0 ]
  [[ "$output" == *"merge target missing"* ]]
  [[ "$output" == *"missing.json"* ]]
}

@test "merge: fragment without manifest entry fails" {
  printf '{"x":1}' > "$ALT_ROOT/configs/demo/orphan.merge.json"
  cat > "$ALT_ROOT/configs/demo/tack-manifest.yml" <<'EOF'
files: {}
EOF
  run_tack
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires files"* ]]
  [[ "$output" == *"orphan.merge.json"* ]]
}

# ----- JSON happy paths -----

@test "merge json: nested object merge preserves both branches" {
  write_pkg scripts.merge.json '{"scripts":{"test":"vitest"}}' \
    package.json '{"name":"x","scripts":{"build":"tsc"}}'
  run_tack
  [ "$status" -eq 0 ]
  result=$(yq -p json -o json '.' "$CONSUMER/package.json")
  [[ "$result" == *'"name": "x"'* ]]
  [[ "$result" == *'"build": "tsc"'* ]]
  [[ "$result" == *'"test": "vitest"'* ]]
}

@test "merge json: scalar override wins from fragment" {
  write_pkg ver.merge.json '{"version":"2.0.0"}' \
    package.json '{"name":"x","version":"1.0.0"}'
  run_tack
  [ "$status" -eq 0 ]
  v=$(yq -p json -o json '.version' "$CONSUMER/package.json")
  [ "$v" = '"2.0.0"' ]
}

@test "merge json: scalar arrays append-and-dedup" {
  write_pkg kw.merge.json '{"keywords":["b","c"]}' \
    package.json '{"keywords":["a","b"]}'
  run_tack
  [ "$status" -eq 0 ]
  joined=$(yq -p json -o json -r '.keywords | join(",")' "$CONSUMER/package.json")
  [ "$joined" = "a,b,c" ]
}

@test "merge json: object arrays dedup by deep equality" {
  write_pkg svc.merge.json '{"services":[{"name":"db"},{"name":"cache"}]}' \
    package.json '{"services":[{"name":"web"},{"name":"db"}]}'
  run_tack
  [ "$status" -eq 0 ]
  count=$(yq -p json -o json '.services | length' "$CONSUMER/package.json")
  [ "$count" = "3" ]
}

@test "merge json: idempotent across two runs" {
  write_pkg a.merge.json '{"keywords":["b","c"],"v":2}' \
    package.json '{"keywords":["a","b"],"v":1}'
  run_tack
  [ "$status" -eq 0 ]
  first=$(cat "$CONSUMER/package.json")
  run_tack
  [ "$status" -eq 0 ]
  second=$(cat "$CONSUMER/package.json")
  [ "$first" = "$second" ]
}

# ----- YAML happy paths -----

@test "merge yaml: nested map merge" {
  write_pkg svc.merge.yml \
    'services:
  cache:
    image: redis
' \
    compose.yml \
    'version: "3"
services:
  web:
    image: nginx
'
  run_tack
  [ "$status" -eq 0 ]
  keys=$(yq -p yaml -o yaml '.services | keys | join(",")' "$CONSUMER/compose.yml")
  [[ "$keys" == *"cache"* ]]
  [[ "$keys" == *"web"* ]]
}

@test "merge yaml: array append-and-dedup" {
  write_pkg br.merge.yml \
    'on:
  push:
    branches: [main, dev]
' \
    wf.yml \
    'on:
  push:
    branches: [main]
'
  run_tack
  [ "$status" -eq 0 ]
  joined=$(yq -p yaml -o yaml -r '.on.push.branches | join(",")' "$CONSUMER/wf.yml")
  [ "$joined" = "main,dev" ]
}

@test "merge yaml: leading comments in target survive merge" {
  # yq Go preserves leading document comments through deep-merge.
  # Inline/key-attached comments may still be lost; this test pins only the
  # leading-comment behavior we observed.
  write_pkg c.merge.yml 'b: 2
' t.yml '# header comment
a: 1
'
  run_tack
  [ "$status" -eq 0 ]
  grep -q 'header comment' "$CONSUMER/t.yml"
  [ "$(yq -p yaml -o yaml '.a' "$CONSUMER/t.yml")" = "1" ]
  [ "$(yq -p yaml -o yaml '.b' "$CONSUMER/t.yml")" = "2" ]
}

# ----- Mixed package -----

@test "merge: json and yaml fragments in the same package both apply" {
  printf '{"v":2}' > "$ALT_ROOT/configs/demo/a.merge.json"
  printf 'k: 2
' > "$ALT_ROOT/configs/demo/b.merge.yml"
  cat > "$ALT_ROOT/configs/demo/tack-manifest.yml" <<'EOF'
files:
  a.merge.json: { target: pkg.json }
  b.merge.yml:  { target: pkg.yml  }
EOF
  printf '{"v":1,"x":9}' > "$CONSUMER/pkg.json"
  printf 'k: 1
z: 9
' > "$CONSUMER/pkg.yml"
  run_tack
  [ "$status" -eq 0 ]
  [ "$(yq -p json -o json '.v' "$CONSUMER/pkg.json")" = "2" ]
  [ "$(yq -p json -o json '.x' "$CONSUMER/pkg.json")" = "9" ]
  [ "$(yq -p yaml -o yaml '.k' "$CONSUMER/pkg.yml")" = "2" ]
  [ "$(yq -p yaml -o yaml '.z' "$CONSUMER/pkg.yml")" = "9" ]
}
