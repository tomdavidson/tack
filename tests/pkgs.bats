#!/usr/bin/env bats
# tests/pkgs.bats - pkgs / overrides / pkgs_metadata resolution and
# tera context injection. Each test builds an isolated ALT_ROOT so we
# can shape configs/, scripts/, and tackrc-defaults.yml per case.

setup() {
  TACK_TEST_TMP="$(mktemp -d -t tack-pkgs.XXXXXX)"
  REAL_TACK_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ALT_ROOT="$TACK_TEST_TMP/tack"
  CONSUMER="$TACK_TEST_TMP/consumer"
  mkdir -p "$ALT_ROOT/configs" "$CONSUMER"
  cp "$REAL_TACK_ROOT/tack.sh" "$ALT_ROOT/tack.sh"
  chmod +x "$ALT_ROOT/tack.sh"
  export ALT_ROOT CONSUMER
}

teardown() { rm -rf "$TACK_TEST_TMP"; }

# mk_pkg <relpath-from-ALT_ROOT> -- creates an empty package directory with
# a single linkable marker file so tack has something to do.
mk_pkg() {
  rel=$1
  mkdir -p "$ALT_ROOT/$rel"
  printf 'marker for %s\n' "$rel" > "$ALT_ROOT/$rel/marker.txt"
}

write_defaults() {
  printf '%s' "$1" > "$ALT_ROOT/tackrc-defaults.yml"
}

# bats's `run` only captures stdout by default; tack writes errors to
# stderr, so we redirect stderr into stdout for assertion convenience.
run_tack() {
  TACK_ROOT="$ALT_ROOT" run bash -c '"$1" --target "$2" "${@:3}" 2>&1' _ "$ALT_ROOT/tack.sh" "$CONSUMER" "$@"
}

# applied <pkg-relpath> -- 0 if marker.txt was linked into consumer.
applied() {
  rel=$1
  base=$(basename "$rel")
  [ -L "$CONSUMER/marker.txt" ] || return 1
  resolved=$(readlink "$CONSUMER/marker.txt")
  case "$resolved" in
    *"$rel/marker.txt") return 0 ;;
    *) return 1 ;;
  esac
  : "$base"
}

# Each pkg's marker.txt has the same name, so they collide on link if more
# than one is applied. Use distinct file names per pkg in multi-pkg tests.
mk_unique_pkg() {
  rel=$1; tag=$2
  mkdir -p "$ALT_ROOT/$rel"
  printf 'marker for %s\n' "$rel" > "$ALT_ROOT/$rel/${tag}.txt"
}

# ----- pkgs glob expansion -----

@test "pkgs: configs/* applies every package under configs/" {
  mk_unique_pkg configs/alpha alpha
  mk_unique_pkg configs/beta  beta
  mk_unique_pkg configs/gamma gamma
  write_defaults 'pkgs:
  - "configs/*"
'
  run_tack
  [ "$status" -eq 0 ]
  [ -L "$CONSUMER/alpha.txt" ]
  [ -L "$CONSUMER/beta.txt" ]
  [ -L "$CONSUMER/gamma.txt" ]
}

@test "overrides.<pkg>.exclude == ['**'] removes one package" {
  mk_unique_pkg configs/alpha alpha
  mk_unique_pkg configs/beta  beta
  mk_unique_pkg configs/gamma gamma
  write_defaults 'pkgs:
  - "configs/*"
overrides:
  configs/beta:
    exclude: ["**"]
'
  run_tack
  [ "$status" -eq 0 ]
  [ -L "$CONSUMER/alpha.txt" ]
  [ ! -e "$CONSUMER/beta.txt" ]
  [ -L "$CONSUMER/gamma.txt" ]
}

@test "overrides: multiple ['**'] entries remove multiple packages" {
  mk_unique_pkg configs/keep        keep
  mk_unique_pkg configs/exp-foo     expfoo
  mk_unique_pkg configs/exp-bar     expbar
  # overrides keys are literal pkg paths, not globs. To exclude a set,
  # list each one explicitly. Pkg-path glob support in overrides keys
  # is a separate feature, not implemented here.
  write_defaults 'pkgs:
  - "configs/*"
overrides:
  configs/exp-foo:
    exclude: ["**"]
  configs/exp-bar:
    exclude: ["**"]
'
  run_tack
  [ "$status" -eq 0 ]
  [ -L "$CONSUMER/keep.txt" ]
  [ ! -e "$CONSUMER/expfoo.txt" ]
  [ ! -e "$CONSUMER/expbar.txt" ]
}

@test "pkgs: literal that does not exist hard-errors" {
  mk_unique_pkg configs/real real
  write_defaults 'pkgs:
  - configs/real
  - configs/missing
'
  run_tack
  [ "$status" -ne 0 ]
  [[ "$output" == *"pkg literal does not resolve"* ]]
  [[ "$output" == *"configs/missing"* ]]
}

@test "pkgs: glob that matches nothing is silent (selection may be empty)" {
  write_defaults 'pkgs:
  - "configs/none-*"
'
  run_tack
  [ "$status" -ne 0 ]
  [[ "$output" == *"no packages selected"* ]]
}

@test "empty pkgs and no CLI args: actionable error" {
  write_defaults 'vars: {}
'
  run_tack
  [ "$status" -ne 0 ]
  [[ "$output" == *"no packages selected"* ]]
}

# ----- CLI override -----

@test "CLI args override pkgs and overrides entirely" {
  mk_unique_pkg configs/alpha alpha
  mk_unique_pkg configs/beta  beta
  write_defaults 'pkgs:
  - configs/alpha
overrides:
  configs/beta:
    exclude: ["**"]
'
  run_tack configs/beta
  [ "$status" -eq 0 ]
  [ ! -e "$CONSUMER/alpha.txt" ]
  [ -L "$CONSUMER/beta.txt" ]
}

# ----- pkgs_metadata into tera context -----

@test "pkgs_metadata: subtree is exposed as .pkg in tera context" {
  mkdir -p "$ALT_ROOT/configs/moon"
  cat > "$ALT_ROOT/configs/moon/toolchain.tera.yml" <<'EOF'
first: {{ pkg.toolchains[0] }}
count: {{ pkg.toolchains | length }}
EOF
  write_defaults 'pkgs:
  - configs/moon
pkgs_metadata:
  configs/moon:
    toolchains:
      - javascript
      - rust
'
  run_tack
  [ "$status" -eq 0 ]
  run cat "$CONSUMER/toolchain.yml"
  [[ "$output" == *"first: javascript"* ]]
  [[ "$output" == *"count: 2"* ]]
}

@test "pkgs_metadata: missing entry yields empty .pkg, default filter works" {
  mkdir -p "$ALT_ROOT/configs/orphan"
  cat > "$ALT_ROOT/configs/orphan/x.tera.yml" <<'EOF'
name: {{ pkg.name | default(value="none") }}
EOF
  write_defaults 'pkgs:
  - configs/orphan
'
  run_tack
  [ "$status" -eq 0 ]
  run cat "$CONSUMER/x.yml"
  [[ "$output" == *"name: none"* ]]
}

# ----- non-configs root packages -----

@test "package outside configs/ resolves by literal path" {
  mk_unique_pkg scripts scripts
  write_defaults 'pkgs:
  - scripts
'
  run_tack
  [ "$status" -eq 0 ]
  [ -L "$CONSUMER/scripts.txt" ]
}
