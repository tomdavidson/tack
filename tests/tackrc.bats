#!/usr/bin/env bats
# tests/tackrc.bats - tackrc merge, link.unfold, default tera ctx
# bats --verbose-run tests/tackrc.bats

export BATS_LIB_PATH=/usr/lib/bats

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  bats_load_library bats-file

  HERE="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
  FIXTURE="$HERE/fixtures"
  TACK_SH="$HERE/../tack.sh"
  TARGET="$(mktemp -d -t tack-tackrc.XXXXXX)"

  cat > "$TARGET/Cargo.toml" <<EOF
[workspace.package]
edition = "2021"
EOF

  export TACK_ROOT="$FIXTURE/tack-root"
}

teardown() {
  rm -rf "$TARGET"
}

path_without() {
  bin=$1
  out=""
  IFS=':'
  for p in $PATH; do
    if [ -n "$p" ] && [ ! -x "$p/$bin" ]; then
      out="${out:+$out:}$p"
    fi
  done
  unset IFS
  printf '%s' "$out"
}

# ---------- merge semantics ----------

@test "defaults apply when consumer tackrc.yml is absent" {
  # No tackrc.yml in TARGET. The default-greeting template has no vars_from
  # and should pick up vars.who from tackrc-defaults.yml.
  "$TACK_SH" --target "$TARGET" configs/example
  assert_file_exists "$TARGET/defaults-greeting.yml"
  run cat "$TARGET/defaults-greeting.yml"
  assert_output --partial "hello default-who"
  assert_output --partial "toolchain: javascript"
}

@test "consumer scalar overrides default scalar (deep merge)" {
  cat > "$TARGET/tackrc.yml" <<'EOF'
vars:
  who: consumer-who
EOF
  "$TACK_SH" --target "$TARGET" configs/example
  run cat "$TARGET/defaults-greeting.yml"
  assert_output --partial "hello consumer-who"
  # moon.toolchains untouched, defaults preserved.
  assert_output --partial "toolchain: javascript"
}

@test "consumer adds new key without dropping defaults" {
  cat > "$TARGET/tackrc.yml" <<'EOF'
vars:
  who: world
  extra: bonus
EOF
  "$TACK_SH" --target "$TARGET" configs/example
  run cat "$TARGET/defaults-greeting.yml"
  assert_output --partial "hello world"
  assert_output --partial "toolchain: javascript"
}

@test "list in consumer replaces list in defaults" {
  cat > "$TARGET/tackrc.yml" <<'EOF'
vars:
  who: world
moon:
  toolchains:
    - rust
EOF
  "$TACK_SH" --target "$TARGET" configs/example
  run cat "$TARGET/defaults-greeting.yml"
  assert_output --partial "toolchain: rust"
  refute_output --partial "toolchain: javascript"
}

@test "vars_from: tackrc.yml resolves to merged result, not raw consumer" {
  # The existing greeting.tera.yml declares vars_from: tackrc.yml.
  # That token must redirect to the merged tackrc, so a key only present
  # in defaults (vars.who: default-who) is visible when consumer omits it.
  cat > "$TARGET/tackrc.yml" <<'EOF'
moon:
  toolchains:
    - rust
EOF
  "$TACK_SH" --target "$TARGET" configs/example
  run cat "$TARGET/greeting.yml"
  assert_output --partial "default-who"
}

# ---------- defaults file required ----------

@test "missing tackrc-defaults.yml is a hard error" {
  ALT_ROOT="$(mktemp -d -t tack-noroot.XXXXXX)"
  mkdir -p "$ALT_ROOT/configs/empty"
  TACK_ROOT="$ALT_ROOT" run "$TACK_SH" --target "$TARGET" configs/empty
  assert_failure
  assert_output --partial "tackrc-defaults.yml missing"
  rm -rf "$ALT_ROOT"
}

# ---------- yq is now a core dep ----------

@test "missing yq binary produces actionable error" {
  stub_dir="$(mktemp -d)"
  ln -s "$(command -v lnko)" "$stub_dir/lnko"
  ln -s "$(command -v tera)" "$stub_dir/tera"
  new_path=$(path_without yq)
  PATH="$stub_dir:$new_path" run "$TACK_SH" --target "$TARGET" configs/example
  assert_failure
  assert_output --partial "yq not found"
  rm -rf "$stub_dir"
}

# ---------- link.unfold ----------

@test "link.unfold makes parent dir real and children symlinks" {
  "$TACK_SH" --target "$TARGET" configs/example
  # nested/ exists as a real directory, not a symlink to the package dir.
  [ -d "$TARGET/nested" ]
  run test -L "$TARGET/nested"
  assert_failure
  # Child is a symlink into the package.
  [ -L "$TARGET/nested/keep.txt" ]
}

@test "unfolded dir lets consumer add siblings without writing through" {
  "$TACK_SH" --target "$TARGET" configs/example
  echo extra > "$TARGET/nested/extra.txt"
  # The new file lives in the consumer, not the package.
  assert_file_exists "$TARGET/nested/extra.txt"
  assert_file_not_exists "$TACK_ROOT/configs/example/nested/extra.txt"
}

# ---------- default tera ctx = merged tackrc ----------

@test "render without vars_from uses merged tackrc as context" {
  cat > "$TARGET/tackrc.yml" <<'EOF'
vars:
  who: ctx-test
EOF
  "$TACK_SH" --target "$TARGET" configs/example
  run cat "$TARGET/defaults-greeting.yml"
  assert_output --partial "hello ctx-test"
}
