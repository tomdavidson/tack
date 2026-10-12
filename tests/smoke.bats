#!/usr/bin/env bats
# tests/smoke.bats - end-to-end smoke test of tack.sh dispatch passes
# bats --verbose-run tests/smoke.bats

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

# path_without BIN -- PATH with BIN unreachable. A dir that holds BIN is
# replaced by a stub dir symlinking everything else in it, so hiding a tool
# that lives in /usr/bin (GitHub runner images ship yq there) does not also
# remove bash and coreutils. Stubs live under TARGET and go with teardown.
path_without() {
  bin=$1
  out=""
  IFS=':'
  for p in $PATH; do
    [ -n "$p" ] || continue
    if [ -x "$p/$bin" ]; then
      stub="$(mktemp -d "${TARGET:-${TMPDIR:-/tmp}}/pathstub.XXXXXX")"
      for f in "$p"/*; do
        name=${f##*/}
        [ "$name" = "$bin" ] && continue
        [ -x "$f" ] && ln -s "$f" "$stub/$name"
      done
      p=$stub
    fi
    out="${out:+$out:}$p"
  done
  unset IFS
  printf '%s' "$out"
}

# ---------- happy path ----------

@test "applies example package successfully" {
  run "$TACK_SH" --target "$TARGET" configs/example
  assert_success
}

@test "plain file becomes a relative symlink in target" {
  "$TACK_SH" --target "$TARGET" configs/example
  [ -L "$TARGET/plain.txt" ]
  resolved=$(readlink "$TARGET/plain.txt")
  case "$resolved" in
    /*) printf 'link target must be relative (consumers commit these): %s\n' "$resolved" >&2; return 1 ;;
    *configs/example/plain.txt) : ;;
    *) printf 'unexpected link target: %s\n' "$resolved" >&2; return 1 ;;
  esac
  # and the relative target actually resolves from the link's directory
  [ -f "$TARGET/plain.txt" ]
}

@test "re-apply replaces a stale absolute symlink with a relative one" {
  ln -sfn "$TACK_ROOT/configs/example/plain.txt" "$TARGET/plain.txt"
  "$TACK_SH" --target "$TARGET" configs/example
  resolved=$(readlink "$TARGET/plain.txt")
  case "$resolved" in
    /*) printf 'stale absolute link was not repaired: %s\n' "$resolved" >&2; return 1 ;;
  esac
  [ -f "$TARGET/plain.txt" ]
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

@test "concat creates missing target from fragment" {
  # Build an isolated package with only a concat fragment, so no copy pass
  # seeds Cargo.toml before concat runs. Concat is a create-or-update
  # operation: missing target is created with the fragment as initial
  # content (no leading newline), mirroring merge's empty-seed behavior.
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
  assert_success
  assert_file_exists "$EMPTY_TARGET/Cargo.toml"
  # First byte is '[' from the fragment, no leading newline on create.
  first=$(head -c 1 "$EMPTY_TARGET/Cargo.toml")
  [ "$first" = "[" ]
  diff "$EMPTY_TARGET/Cargo.toml" "$ALT_ROOT/configs/bare/clippy.concat.toml"
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
  # The fixture tack-root has no configs/common/.prototools, so tack takes
  # the PATH fallback. Strip tera from PATH, then re-provide yq (if
  # available) via a stub dir so we isolate the failure to tera.
  stub_dir="$(mktemp -d)"
  if command -v yq >/dev/null 2>&1; then
    ln -s "$(command -v yq)" "$stub_dir/yq"
  fi
  new_path=$(path_without tera)
  PATH="$stub_dir:$new_path" run "$TACK_SH" --target "$TARGET" configs/example
  assert_failure
  assert_output --partial "tera not found"
  rm -rf "$stub_dir"
}

@test "missing proto with a pinfile present produces install directions" {
  # When TACK_ROOT carries configs/common/.prototools, proto is required.
  # require_core_deps runs before load_tackrc, so ALT_ROOT only needs the
  # pinfile for this path to be exercised.
  ALT_ROOT="$(mktemp -d -t tack-noproto.XXXXXX)"
  mkdir -p "$ALT_ROOT/configs/common"
  printf 'yq = "4.53.3"\ntera = "0.5.0"\n' > "$ALT_ROOT/configs/common/.prototools"
  cp "$TACK_SH" "$ALT_ROOT/tack.sh"
  new_path=$(path_without proto)
  TACK_ROOT="$ALT_ROOT" PATH="$new_path" run "$ALT_ROOT/tack.sh" --target "$TARGET" configs/example
  assert_failure
  assert_output --partial "proto not found"
  assert_output --partial "moonrepo.dev/install/proto.sh"
  rm -rf "$ALT_ROOT"
}

@test "TACK_SKIP_BOOTSTRAP=1 bypasses proto and uses PATH tools" {
  ALT_ROOT="$(mktemp -d -t tack-skipboot.XXXXXX)"
  cp -R "$TACK_ROOT/." "$ALT_ROOT/"
  mkdir -p "$ALT_ROOT/configs/common"
  printf 'yq = "4.53.3"\ntera = "0.5.0"\n' > "$ALT_ROOT/configs/common/.prototools"
  new_path=$(path_without proto)
  TACK_SKIP_BOOTSTRAP=1 TACK_ROOT="$ALT_ROOT" PATH="$new_path" run "$TACK_SH" --target "$TARGET" configs/example
  assert_success
  assert_file_exists "$TARGET/greeting.yml"
  rm -rf "$ALT_ROOT"
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
