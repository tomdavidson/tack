#!/usr/bin/env bats
# tests/smoke.bats - end-to-end smoke test of tack.sh dispatch passes
# bats --verbose-run tests/smoke.bats

export BATS_LIB_PATH=/usr/lib/bats


setup() {

  # : "${BATS_LIB_PATH:=/usr/lib/bats:/usr/lib}"
  # export BATS_LIB_PATH
  
  bats_load_library bats-support
  bats_load_library bats-assert
  bats_load_library bats-file

  HERE="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
  FIXTURE="$HERE/fixtures"
  TACK_SH="$HERE/../tack.sh"
  TARGET="$(mktemp -d -t tack-smoke.XXXXXX)"

  # Seed a Cargo.toml so merge_file has a real target to merge into.
  cat > "$TARGET/Cargo.toml" <<EOF
[workspace.package]
edition = "2021"
EOF

  export TACK_ROOT="$FIXTURE/tack-root"
}

teardown() {
  rm -rf "$TARGET"
}

@test "applies example package successfully" {
  run "$TACK_SH" --target "$TARGET" example
  assert_success
}

@test "plain file becomes a symlink in target" {
  "$TACK_SH" --target "$TARGET" example
  assert_link_exists "$TARGET/plain.txt"
  assert_equal "$(readlink -f "$TARGET/plain.txt")" "$TACK_ROOT/configs/example/plain.txt"
}

@test "tera file renders to marker-stripped target" {
  "$TACK_SH" --target "$TARGET" example
  assert_file_exists "$TARGET/greeting.yml"
  assert_file_not_exists "$TARGET/greeting.tera.yml"
}

@test "copy file copies to marker-stripped target" {
  "$TACK_SH" --target "$TARGET" example
  assert_file_exists "$TARGET/Cargo.toml"
  assert_file_not_exists "$TARGET/Cargo.copy.toml"
}

@test "merge applies clippy lints to seeded Cargo.toml" {
  "$TACK_SH" --target "$TARGET" example
  run cat "$TARGET/Cargo.toml"
  assert_output --partial "workspace.lints"
}

@test "tack-manifest.yml is not linked into target" {
  "$TACK_SH" --target "$TARGET" example
  assert_file_not_exists "$TARGET/tack-manifest.yml"
}

@test "dry-run makes no filesystem changes" {
  DRY_TARGET="$(mktemp -d -t tack-dry.XXXXXX)"
  run "$TACK_SH" --dry-run --target "$DRY_TARGET" example
  assert_success
  assert_file_not_exists "$DRY_TARGET/plain.txt"
  assert_file_not_exists "$DRY_TARGET/greeting.yml"
  rm -rf "$DRY_TARGET"
}
