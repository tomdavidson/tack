#!/usr/bin/env bats
# tests/delivery_modes.bats - ADR-0009 delivery-mode guards
#
# Decision 6: concat is for line-oriented files only. A structured file
# (Nix, JSON, YAML, TOML) is never shipped as a *.concat.* fragment: Nix is
# a devenv module imported from .tack, JSON/YAML/TOML use *.merge.*.

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

@test "ADR-0009: no package ships a *.concat.toml fragment" {
  found=$(package_files '*.concat.toml')
  [ -z "$found" ] || {
    printf 'TOML must use *.merge.toml or stub+extend, not concat:\n%s\n' "$found" >&2
    return 1
  }
}

@test "ADR-0009: no package ships a nested dprint.json that dprint would mistake for a sub-project config" {
  found=$(package_files 'dprint.json')
  [ -z "$found" ] || {
    printf 'Shared dprint profiles must be named dprint-<pkg>.json so dprint does not treat them as standalone directory configs:\n%s\n' "$found" >&2
    return 1
  }
}

@test "ADR-0009: configs/common ships dprint.copy.json stub extending .tack/configs/common/dprint-common.json" {
  [ -f "$TACK_ROOT/configs/common/dprint-common.json" ]
  [ -f "$TACK_ROOT/configs/common/dprint.copy.json" ]
  grep -qE '^\s*-\s*dprint-common\.json\s*$' "$TACK_ROOT/configs/common/tack.yml"
  grep -q './.tack/configs/common/dprint-common.json' "$TACK_ROOT/configs/common/dprint.copy.json"
}

@test "ADR-0009: configs/php ships php.nix and shared lint/format rules in .tack with seed-once stubs and dprint.merge.json" {
  [ -f "$TACK_ROOT/configs/php/php.nix" ]
  [ -f "$TACK_ROOT/configs/php/phpcs-base.xml" ]
  [ -f "$TACK_ROOT/configs/php/phpcs.xml" ]
  [ -f "$TACK_ROOT/configs/php/phpcs.copy.xml.dist" ]
  [ -f "$TACK_ROOT/configs/php/phpstan.neon" ]
  [ -f "$TACK_ROOT/configs/php/phpstan.copy.neon.dist" ]
  [ -f "$TACK_ROOT/configs/php/dprint-php.json" ]
  [ -f "$TACK_ROOT/configs/php/dprint.merge.json" ]
  [ ! -e "$TACK_ROOT/configs/php/devenv.concat.nix" ]
  grep -qE '^\s*-\s*php\.nix\s*$' "$TACK_ROOT/configs/php/tack.yml"
  grep -qE '^\s*-\s*phpcs-base\.xml\s*$' "$TACK_ROOT/configs/php/tack.yml"
  grep -qE '^\s*-\s*phpcs\.xml\s*$' "$TACK_ROOT/configs/php/tack.yml"
  grep -qE '^\s*-\s*phpstan\.neon\s*$' "$TACK_ROOT/configs/php/tack.yml"
  grep -qE '^\s*-\s*dprint-php\.json\s*$' "$TACK_ROOT/configs/php/tack.yml"
  grep -q './.tack/configs/php/phpcs.xml' "$TACK_ROOT/configs/php/phpcs.copy.xml.dist"
  grep -q '.tack/configs/php/phpstan.neon' "$TACK_ROOT/configs/php/phpstan.copy.neon.dist"
  grep -q './.tack/configs/php/dprint-php.json' "$TACK_ROOT/configs/php/dprint.merge.json"
}

@test "ADR-0008/0009: configs/drupal layers on configs/php and ignores .nix modules, shared rules, and host scripts" {
  grep -qE '^\s*-\s*drupal\.nix\s*$' "$TACK_ROOT/configs/drupal/tack.yml"
  grep -qE '^\s*-\s*phpcs\.xml\s*$' "$TACK_ROOT/configs/drupal/tack.yml"
  grep -qE '^\s*-\s*phpstan\.neon\s*$' "$TACK_ROOT/configs/drupal/tack.yml"
  grep -qE '^\s*-\s*dprint-drupal\.json\s*$' "$TACK_ROOT/configs/drupal/tack.yml"
  grep -qE '^\s*-\s*scripts/\*\*\s*$' "$TACK_ROOT/configs/drupal/tack.yml"
  grep -qE '^\s*-\s*python\.nix\s*$' "$TACK_ROOT/configs/python/tack.yml"
  grep -q '../php/php.nix' "$TACK_ROOT/configs/drupal/drupal.nix"
  grep -q '../php/phpcs-base.xml' "$TACK_ROOT/configs/drupal/phpcs.xml"
  grep -q '../php/phpstan.neon' "$TACK_ROOT/configs/drupal/phpstan.neon"
  grep -q './.tack/configs/drupal/phpcs.xml' "$TACK_ROOT/configs/drupal/phpcs.xml.dist"
  grep -q '.tack/configs/drupal/phpstan.neon' "$TACK_ROOT/configs/drupal/phpstan.neon.dist"
  grep -q './.tack/configs/drupal/dprint-drupal.json' "$TACK_ROOT/configs/drupal/dprint.merge.json"
}

@test "ADR-0009: configs/javascript merges node/pnpm into .prototools and does not clobber package.json metadata" {
  [ -f "$TACK_ROOT/configs/javascript/prototools.merge.toml" ]
  [ ! -e "$TACK_ROOT/configs/javascript/.prototools" ]
  ! grep -qE '^(node|pnpm)\s*=' "$TACK_ROOT/configs/common/.prototools"
  grep -q 'prototools.merge.toml:' "$TACK_ROOT/configs/javascript/tack.yml"
  grep -q 'target: .prototools' "$TACK_ROOT/configs/javascript/tack.yml"
  grep -q 'package.merge.json:' "$TACK_ROOT/configs/javascript/tack.yml"
  grep -q 'pnpm-workspace.merge.yaml:' "$TACK_ROOT/configs/javascript/tack.yml"
  grep -q '.tack/packages/\*' "$TACK_ROOT/configs/javascript/pnpm-workspace.merge.yaml"
  grep -q '@tack/eslint-config' "$TACK_ROOT/configs/javascript/package.merge.json"
  ! grep -q '"name"' "$TACK_ROOT/configs/javascript/package.merge.json"
  ! grep -q '"version"' "$TACK_ROOT/configs/javascript/package.merge.json"
  ! grep -q '"packageManager"' "$TACK_ROOT/configs/javascript/package.merge.json"
  ! grep -q '"name"' "$TACK_ROOT/configs/web/package.merge.json"
  ! grep -q '"version"' "$TACK_ROOT/configs/web/package.merge.json"
  ! grep -q '"packageManager"' "$TACK_ROOT/configs/web/package.merge.json"
}

@test "ADR-0009: configs/renovate ships shared default.json5 preset and seed-once .github/renovate.json5 stub" {
  [ -f "$TACK_ROOT/configs/renovate/default.json5" ]
  [ -f "$TACK_ROOT/configs/renovate/.github/renovate.json5" ]
  grep -qE '^\s*-\s*default\.json5\s*$' "$TACK_ROOT/configs/renovate/tack.yml"
  grep -q '.github/renovate.json5:' "$TACK_ROOT/configs/renovate/tack.yml"
  grep -q 'overwrite: false' "$TACK_ROOT/configs/renovate/tack.yml"
  grep -q 'github>tomdavidson/tack//configs/renovate/default.json5' "$TACK_ROOT/configs/renovate/.github/renovate.json5"
  grep -q 'pnpm-workspace.yaml' "$TACK_ROOT/configs/renovate/default.json5"
}
