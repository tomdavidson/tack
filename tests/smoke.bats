#!/usr/bin/env bats
# tests/smoke.bats - end-to-end smoke test of tack.sh dispatch passes
# bats --verbose-run tests/smoke.bats

export BATS_LIB_PATH=/usr/lib/bats

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  bats_load_library bats-file

  HERE="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
  FIXTURE="$HERE/fixtures"
  TACK_SH="$HERE/../tack.sh"
  TARGET="$(mktemp -d -t tack-smoke.XXXXXX)"

  cat > "$TARGET/Cargo.toml" <<EOF
[workspace.package]
edition = "2021"
EOF

  # Seed a consumer-root tackrc.yml so bare vars_from: tackrc.yml resolves.
  cat > "$TARGET/tackrc.yml" <<'EOF'
vars:
  who: world
EOF

  export TACK_ROOT="$FIXTURE/tack-root"
}

teardown() {
  rm -rf "$TARGET"
}

# Build a PATH that preserves system dirs but excludes any dir holding BIN.
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

# ---------- happy path ----------

@test "applies example package successfully" {
  run "$TACK_SH" --target "$TARGET" configs/example
  assert_success
}

@test "plain file becomes a symlink in target" {
  "$TACK_SH" --target "$TARGET" configs/example
  [ -L "$TARGET/plain.txt" ]
  resolved=$(readlink "$TARGET/plain.txt")
  case "$resolved" in
    *configs/example/plain.txt) : ;;
    *) printf 'unexpected link target: %s\n' "$resolved" >&2; return 1 ;;
  esac
}

@test "tera file renders to marker-stripped target" {
  "$TACK_SH" --target "$TARGET" configs/example
  assert_file_exists "$TARGET/greeting.yml"
  assert_file_not_exists "$TARGET/greeting.tera.yml"
}

@test "vars_from resolves against consumer root (TARGET)" {
  # Override the seeded rc with a distinguishing value so we can prove the
  # template read from TARGET and not from some package-relative fallback.
  cat > "$TARGET/tackrc.yml" <<'EOF'
vars:
  who: consumer-root
EOF
  "$TACK_SH" --target "$TARGET" configs/example
  run cat "$TARGET/greeting.yml"
  assert_output --partial "consumer-root"
}

@test "copy file copies to marker-stripped target and is not a symlink" {
  "$TACK_SH" --target "$TARGET" configs/example
  assert_file_exists "$TARGET/Cargo.toml"
  assert_file_not_exists "$TARGET/Cargo.copy.toml"
  run test -L "$TARGET/Cargo.toml"
  assert_failure
}

@test "concat appends clippy lints to seeded Cargo.toml" {
  "$TACK_SH" --target "$TARGET" configs/example
  run cat "$TARGET/Cargo.toml"
  assert_output --partial "workspace.lints"
}

@test "tack.yml is not linked into target" {
  # The example fixture already has a tack.yml. After applying, the
  # target must not contain a tack.yml symlink.
  "$TACK_SH" --target "$TARGET" configs/example
  assert_file_not_exists "$TARGET/tack.yml"
}

# ---------- concat semantics ----------

@test "concat is idempotent across repeat runs" {
  "$TACK_SH" --target "$TARGET" configs/example
  first=$(wc -c < "$TARGET/Cargo.toml")
  "$TACK_SH" --target "$TARGET" configs/example
  second=$(wc -c < "$TARGET/Cargo.toml")
  assert_equal "$first" "$second"
}

@test "concat dies cleanly when target file is missing" {
  # Build an isolated package with only a concat fragment, so no copy pass
  # seeds Cargo.toml before concat runs.
  ALT_ROOT="$(mktemp -d -t tack-alt-root.XXXXXX)"
  mkdir -p "$ALT_ROOT/configs/bare"
  printf 'vars: {}\n' > "$ALT_ROOT/tackrc-defaults.yml"
  cat > "$ALT_ROOT/configs/bare/clippy.concat.toml" <<'EOF'
[workspace.lints.clippy]
unwrap_used = "warn"
EOF
  cat > "$ALT_ROOT/configs/bare/tack.yml" <<'EOF'
files:
  clippy.concat.toml:
    target: Cargo.toml
EOF
  EMPTY_TARGET="$(mktemp -d -t tack-empty.XXXXXX)"
  TACK_ROOT="$ALT_ROOT" run "$TACK_SH" --target "$EMPTY_TARGET" configs/bare
  assert_failure
  assert_output --partial "concat target missing"
  rm -rf "$ALT_ROOT" "$EMPTY_TARGET"
}

# ---------- unknown suffix fallthrough ----------

@test "unknown interior suffix falls through to link pass" {
  f="$TACK_ROOT/configs/example/notes.bak.md"
  printf 'note\n' > "$f"
  "$TACK_SH" --target "$TARGET" configs/example
  rm -f "$f"
  [ -L "$TARGET/notes.bak.md" ]
}

# ---------- dry-run ----------

@test "dry-run makes no filesystem changes" {
  DRY_TARGET="$(mktemp -d -t tack-dry.XXXXXX)"
  cat > "$DRY_TARGET/Cargo.toml" <<EOF
[workspace.package]
edition = "2021"
EOF
  cat > "$DRY_TARGET/tackrc.yml" <<'EOF'
vars:
  who: world
EOF
  before=$(sha256sum "$DRY_TARGET/Cargo.toml" | awk '{print $1}')

  run "$TACK_SH" --dry-run --target "$DRY_TARGET" configs/example
  assert_success

  assert_file_not_exists "$DRY_TARGET/plain.txt"
  assert_file_not_exists "$DRY_TARGET/greeting.yml"
  after=$(sha256sum "$DRY_TARGET/Cargo.toml" | awk '{print $1}')
  assert_equal "$before" "$after"

  rm -rf "$DRY_TARGET"
}

@test "dry-run tolerates missing concat target without failing" {
  DRY_TARGET="$(mktemp -d -t tack-dry-no-cargo.XXXXXX)"
  run "$TACK_SH" --dry-run --target "$DRY_TARGET" configs/example
  assert_success
  rm -rf "$DRY_TARGET"
}

# ---------- error paths ----------

@test "unknown package name fails cleanly" {
  run "$TACK_SH" --target "$TARGET" does-not-exist
  assert_failure
  assert_output --partial "no such package"
}

@test "unknown option fails cleanly" {
  run "$TACK_SH" --nope configs/example
  assert_failure
  assert_output --partial "unknown option"
}

@test "--help exits 0" {
  run "$TACK_SH" --help
  assert_success
  assert_output --partial "Usage:"
}

@test "no packages and empty pkgs in tackrc fails with actionable message" {
  # No CLI args and the consumer's seeded tackrc.yml has no `pkgs` key, so
  # resolve_pkgs yields nothing and tack should die with a useful message.
  run "$TACK_SH" --target "$TARGET"
  assert_failure
  assert_output --partial "no packages selected"
}

@test "missing tera binary produces actionable error" {
  # Strip tera from PATH, then re-provide lnko (and yq if available) via a
  # stub dir so we isolate the failure to tera.
  stub_dir="$(mktemp -d)"
  ln -s "$(command -v lnko)" "$stub_dir/lnko"
  if command -v yq >/dev/null 2>&1; then
    ln -s "$(command -v yq)" "$stub_dir/yq"
  fi
  new_path=$(path_without tera)
  PATH="$stub_dir:$new_path" run "$TACK_SH" --target "$TARGET" configs/example
  assert_failure
  assert_output --partial "tera not found"
  rm -rf "$stub_dir"
}

@test "missing lnko binary produces actionable error" {
  stub_dir="$(mktemp -d)"
  ln -s "$(command -v tera)" "$stub_dir/tera"
  if command -v yq >/dev/null 2>&1; then
    ln -s "$(command -v yq)" "$stub_dir/yq"
  fi
  new_path=$(path_without lnko)
  PATH="$stub_dir:$new_path" run "$TACK_SH" --target "$TARGET" configs/example
  assert_failure
  assert_output --partial "lnko not found"
  rm -rf "$stub_dir"
}

# ---------- paths with spaces ----------

@test "target path with spaces is handled correctly" {
  SPACED="$(mktemp -d -t 'tack smoke XXXX')"
  cat > "$SPACED/Cargo.toml" <<EOF
[workspace.package]
edition = "2021"
EOF
  cat > "$SPACED/tackrc.yml" <<'EOF'
vars:
  who: world
EOF
  run "$TACK_SH" --target "$SPACED" configs/example
  assert_success
  assert_file_exists "$SPACED/greeting.yml"
  assert_file_exists "$SPACED/Cargo.toml"
  rm -rf "$SPACED"
}
