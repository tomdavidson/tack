#!/usr/bin/env sh
# tack.sh - apply tack packages to a consumer repo
# Lives at the tack repo root.
# Usage: ./tack.sh [--dry-run] [--target DIR] <package>...
#
# Dispatch (per ADR-0002, with concat per ADR-0004; merge not yet implemented):
#   *.tera.*           render via tera
#   *.copy.*           copy verbatim
#   *.concat.*         append to manifest-declared target (signature-dedup)
#   everything else    symlink via lnko (except tack-manifest.yml and tack.yml)

set -eu

TACK_ROOT="${TACK_ROOT:-$(cd "$(dirname "$0")" && pwd)}"
DRY_RUN=0
TARGET="$PWD"
# TACK_CONSUMER_ROOT overrides where @consumer/ and bare vars_from paths
# resolve. Defaults to $TARGET after argv parsing.
TACK_CONSUMER_ROOT="${TACK_CONSUMER_ROOT:-}"

log() { printf '[tack] %s\n' "$*" >&2; }
die() { printf '[tack] error: %s\n' "$*" >&2; exit 1; }

# run CMD ARG...  -- executes argv directly (no eval). In dry-run, prints argv.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run]'
    for a in "$@"; do printf ' %s' "$a"; done
    printf '\n'
    return 0
  fi
  "$@"
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH ($2)"
}

# Verify runtime deps up front so errors are actionable. yq is only needed
# when a package carries a tack-manifest.yml; check it lazily.
require_core_deps() {
  require_bin lnko "install from https://github.com/tomdavidson/lnko releases"
  require_bin tera "install with: cargo install tera-cli"
}

require_yq_if_manifest() {
  manifest=$1
  [ -f "$manifest" ] || return 0
  if ! command -v yq >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "warn: yq missing; manifest reads will be skipped in dry-run ($manifest)"
      return 0
    fi
    die "yq not found on PATH (required to read $manifest)"
  fi
}

strip_marker() { printf '%s\n' "$1" | sed -E 's/\.(tera|copy|concat)\./\./'; }
rel_in_pkg()   { printf '%s\n' "${1#"$2"/}"; }

# manifest_get MANIFEST SRC_REL FIELD
# Returns empty string if manifest missing, yq missing in dry-run, or field unset.
manifest_get() {
  manifest=$1; src_rel=$2; field=$3
  [ -f "$manifest" ] || { printf ''; return 0; }
  if ! command -v yq >/dev/null 2>&1; then
    [ "$DRY_RUN" -eq 1 ] || die "yq required to read $manifest"
    printf ''
    return 0
  fi
  yq -r ".files[\"$src_rel\"].$field // \"\"" "$manifest"
}

link_package() {
  pkg_dir=$1; target=$2
  log "link: $pkg_dir -> $target"
  run lnko link \
    --ignore '*.tera.*' \
    --ignore '*.copy.*' \
    --ignore '*.concat.*' \
    --ignore 'tack-manifest.yml' \
    --ignore 'tack.yml' \
    -t "$target" \
    "$pkg_dir"
}

render_file() {
  src=$1; pkg_dir=$2; manifest=$3; target=$4
  src_rel=$(rel_in_pkg "$src" "$pkg_dir")
  target_rel=$(dirname "$src_rel")/$(strip_marker "$(basename "$src")")
  target_rel=${target_rel#./}
  dest="$target/$target_rel"
  vars_from=$(manifest_get "$manifest" "$src_rel" vars_from)
  post=$(manifest_get "$manifest" "$src_rel" post)
  log "render: $src_rel -> $target_rel"
  run mkdir -p "$(dirname "$dest")"
  if [ -n "$vars_from" ]; then
    case "$vars_from" in
      /*)             ctx=$vars_from ;;
      '~/'*)          ctx="$HOME/${vars_from#~/}" ;;
      '@tack/'*)      ctx="$TACK_ROOT/${vars_from#@tack/}" ;;
      '@consumer/'*)  ctx="$TACK_CONSUMER_ROOT/${vars_from#@consumer/}" ;;
      *)              ctx="$TACK_CONSUMER_ROOT/$vars_from" ;;
    esac
    [ -f "$ctx" ] || [ "$DRY_RUN" -eq 1 ] || die "vars_from not found: $ctx (from $src_rel)"
    run tera --template "$src" --include-path "$TACK_ROOT" "$ctx" --out "$dest"
  else
    run tera --template "$src" --out "$dest"
  fi
  if [ -n "$post" ]; then
    # post is a single command name or path; argv-split on whitespace is
    # intentional. Wrap in a script if you need complex args.
    # shellcheck disable=SC2086
    run $post "$dest"
  fi
}

copy_file() {
  src=$1; pkg_dir=$2; target=$3
  src_rel=$(rel_in_pkg "$src" "$pkg_dir")
  target_rel=$(dirname "$src_rel")/$(strip_marker "$(basename "$src")")
  target_rel=${target_rel#./}
  dest="$target/$target_rel"
  log "copy: $src_rel -> $target_rel"
  run mkdir -p "$(dirname "$dest")"
  run cp "$src" "$dest"
}

# Append src to dest. Skip if the first two non-comment/non-blank lines of
# src already appear consecutively in dest (idempotent re-runs).
concat_append() {
  src=$1; dest=$2
  line1=$(grep -v -E '^[[:space:]]*(#|$)' "$src" | sed -n '1p')
  line2=$(grep -v -E '^[[:space:]]*(#|$)' "$src" | sed -n '2p')
  [ -n "$line1" ] || die "concat source has no non-comment content: $src"
  if [ -n "$line2" ] && \
     awk -v a="$line1" -v b="$line2" '
       prev == a && $0 == b { found=1; exit }
       { prev=$0 }
       END { exit !found }
     ' "$dest"; then
    log "skip: signature already present in $dest"
    return 0
  fi
  printf '\n' >> "$dest"
  cat "$src" >> "$dest"
}

concat_file() {
  src=$1; pkg_dir=$2; manifest=$3; target=$4
  src_rel=$(rel_in_pkg "$src" "$pkg_dir")
  concat_target=$(manifest_get "$manifest" "$src_rel" target)
  [ -n "$concat_target" ] || die "concat file $src_rel requires files[\"$src_rel\"].target in $manifest"
  dest="$target/$concat_target"
  log "concat: $src_rel -> $concat_target"
  if [ ! -f "$dest" ]; then
    [ "$DRY_RUN" -eq 1 ] || die "concat target missing: $dest"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] append %s >> %s\n' "$src" "$dest"
    return 0
  fi
  concat_append "$src" "$dest"
}

# iterate_files PKG_DIR PATTERN HANDLER ARG...
# Uses a temp file (not a pipe) so set -e aborts on handler failure.
iterate_files() {
  pkg_dir=$1; pattern=$2; handler=$3; shift 3
  tmp=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT INT TERM
  find "$pkg_dir" -type f -name "$pattern" > "$tmp"
  while IFS= read -r f; do
    "$handler" "$f" "$@"
  done < "$tmp"
  rm -f "$tmp"
  trap - EXIT INT TERM
}

apply_package() {
  pkg=$1
  pkg_dir="$TACK_ROOT/configs/$pkg"
  [ -d "$pkg_dir" ] || die "no such package: configs/$pkg"
  manifest="$pkg_dir/tack-manifest.yml"
  require_yq_if_manifest "$manifest"

  link_package "$pkg_dir" "$TARGET"
  iterate_files "$pkg_dir" '*.tera.*'   _h_render "$pkg_dir" "$manifest" "$TARGET"
  iterate_files "$pkg_dir" '*.copy.*'   _h_copy   "$pkg_dir" "$TARGET"
  iterate_files "$pkg_dir" '*.concat.*' _h_concat "$pkg_dir" "$manifest" "$TARGET"
}

_h_render() { render_file "$1" "$2" "$3" "$4"; }
_h_copy()   { copy_file   "$1" "$2" "$3"; }
_h_concat() { concat_file "$1" "$2" "$3" "$4"; }

usage() {
  cat <<EOF
Usage: ./tack.sh [options] <package>...
Options:
  --dry-run        Print actions without executing
  --target DIR     Target directory (default: \$PWD)
  -h, --help       Show this help

Packages are directory names under configs/ (e.g., rust, common).
Run from the tack repo root, or set TACK_ROOT to point at it.

Dispatch by filename marker:
  *.tera.*     render via tera
  *.copy.*     copy verbatim
  *.concat.*   append to manifest-declared target
  (other)      symlink via lnko

Requires: lnko, tera on PATH. yq additionally required when a package
has a tack-manifest.yml.
EOF
}

pkgs=""
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY_RUN=1 ;;
    --target)  shift; [ $# -gt 0 ] || die "--target requires a DIR"; TARGET=$1 ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; break ;;
    -*)        die "unknown option: $1" ;;
    *)         pkgs="$pkgs $1" ;;
  esac
  shift
done

[ -n "$pkgs" ] || { usage; exit 1; }

: "${TACK_CONSUMER_ROOT:=$TARGET}"

require_core_deps
for p in $pkgs; do apply_package "$p"; done
