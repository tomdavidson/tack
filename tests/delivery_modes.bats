#!/usr/bin/env bats
# tests/delivery_modes.bats - ADR-0009 delivery-mode guards
#
# Decision 6: concat is for line-oriented files only. A structured file
# (Nix, JSON, YAML) is never shipped as a *.concat.* fragment: Nix is a
# devenv module imported from .tack, JSON/YAML use *.merge.*. TOML concat
# (configs/rust Cargo.toml) is grandfathered until a TOML merge path
# exists and is deliberately not covered here.

setup() {
  TACK_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TACK_ROOT
}

# package_files PATTERN -- files matching PATTERN under every package root
# (configs/**, .moon), excluding test fixtures and dependency trees.
package_files() {
  find "$TACK_ROOT/configs" "$TACK_ROOT/.moon" \
    \( -name node_modules -o -name tests -o -name cache -o -name .git \) -prune -o \
    -type f -name "$1" -print 2> /dev/null
}

@test "ADR-0009: no package ships a *.concat.nix fragment" {
  found=$(package_files '*.concat.nix')
  [ -z "$found" ] || {
    printf 'Nix must be a devenv module, not a concat fragment:\n%s\n' "$found" >&2
    return 1
  }
}

@test "ADR-0009: no package ships a *.concat.json fragment" {
  found=$(package_files '*.concat.json')
  [ -z "$found" ] || {
    printf 'JSON must use *.merge.json, not concat:\n%s\n' "$found" >&2
    return 1
  }
}

@test "ADR-0009: no package ships a *.concat.yml or *.concat.yaml fragment" {
  found=$(package_files '*.concat.yml'; package_files '*.concat.yaml')
  [ -z "$found" ] || {
    printf 'YAML must use *.merge.yml, not concat:\n%s\n' "$found" >&2
    return 1
  }
}

@test "ADR-0009: configs/php ships php.nix as an ignored module, no devenv fragment" {
  [ -f "$TACK_ROOT/configs/php/php.nix" ]
  [ ! -e "$TACK_ROOT/configs/php/devenv.concat.nix" ]
  grep -qE '^\s*-\s*php\.nix\s*$' "$TACK_ROOT/configs/php/tack.yml"
}
