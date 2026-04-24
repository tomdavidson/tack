#!/usr/bin/env sh
# tack.sh - apply tack packages to a consumer repo
# Lives at the tack repo root.
# Usage: ./tack.sh [--dry-run] [--target DIR] <package>...

set -eu

TACK_ROOT="${TACK_ROOT:-$(cd "$(dirname "$0")" && pwd)}"
DRY_RUN=0
TARGET="$PWD"

log()  { printf '[tack] %s\n' "$*" >&2; }
die()  { printf '[tack] error: %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then printf '[dry-run] %s\n' "$*"; else eval "$@"; fi; }

link_package() {
  pkg_dir=$1; target=$2
  log "link: $pkg_dir -> $target"
  run lnko link \
    --ignore '*.tera.*' \
    --ignore '*.copy.*' \
    --ignore '*.concat.*' \
    --ignore 'tack-manifest.yml' \
    -t "$target" \
    "$pkg_dir"
}

strip_marker() { printf '%s\n' "$1" | sed -E 's/\.(tera|copy|merge)\./\./'; }
rel_in_pkg()   { printf '%s\n' "${1#"$2"/}"; }

manifest_get() {
  manifest=$1; src_rel=$2; field=$3
  [ -f "$manifest" ] || { printf ''; return 0; }
  command -v yq >/dev/null 2>&1 || die "yq required for manifest reads"
  yq -r ".files[\"$src_rel\"].$field // \"\"" "$manifest"
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
      /*) ctx=$vars_from ;;
      *)  ctx=$pkg_dir/$vars_from ;;
    esac
    [ -f "$ctx" ] || die "vars_from not found: $ctx (from $src_rel)"
    run "tera --template \"$src\" --include-path \"$TACK_ROOT\" \"$ctx\" --out \"$dest\""
  else
    run "tera --template \"$src\" --out \"$dest\""
  fi
  [ -n "$post" ] && run "$post \"$dest\""
  return 0
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

concat_file() {
  src=$1; pkg_dir=$2; manifest=$3; target=$4
  src_rel=$(rel_in_pkg "$src" "$pkg_dir")
  concat_target=$(manifest_get "$manifest" "$src_rel" target)
  [ -n "$concat_target" ] || die "concat file $src_rel requires 'target' in $manifest"
  dest="$target/$concat_target"
  [ -f "$dest" ] || { [ "$DRY_RUN" -eq 1 ] || die "concat target missing: $dest"; }
  log "concat: $src_rel -> $concat_target"
  sig=$(grep -v -E '^[[:space:]]*(#|$)' "$src" | head -n 2)
  line1=$(printf '%s\n' "$sig" | sed -n '1p')
  line2=$(printf '%s\n' "$sig" | sed -n '2p')
  [ -n "$line1" ] || die "concat file $src_rel has no non-comment content"
  if [ "$DRY_RUN" -ne 1 ] && [ -n "$line2" ] && \
     awk -v a="$line1" -v b="$line2" 'prev == a && $0 == b { found=1; exit } { prev=$0 } END { exit !found }' "$dest"; then
    log "skip: $src_rel: signature already present in $concat_target"
    return 0
  fi
  run "printf '\\n' >> \"$dest\" && cat \"$src\" >> \"$dest\""
}

apply_package() {
  pkg=$1
  pkg_dir="$TACK_ROOT/configs/$pkg"
  [ -d "$pkg_dir" ] || die "no such package: configs/$pkg"
  manifest="$pkg_dir/tack-manifest.yml"
  link_package "$pkg_dir" "$TARGET"
  find "$pkg_dir" -type f -name '*.tera.*' | while IFS= read -r f; do
    render_file "$f" "$pkg_dir" "$manifest" "$TARGET"
  done
  find "$pkg_dir" -type f -name '*.copy.*' | while IFS= read -r f; do
    copy_file "$f" "$pkg_dir" "$TARGET"
  done
  find "$pkg_dir" -type f -name '*.concat.*' | while IFS= read -r f; do
    concat_file "$f" "$pkg_dir" "$manifest" "$TARGET"
  done
}

usage() {
  cat <<EOF
Usage: ./tack.sh [options] <package>...
Options:
  --dry-run        Print actions without executing
  --target DIR     Target directory (default: \$PWD)
  -h, --help       Show this help

Packages are directory names under configs/ (e.g., rust, formatting).
Run from the tack repo root, or set TACK_ROOT to point at it.
EOF
}

pkgs=""
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY_RUN=1 ;;
    --target)  shift; TARGET=$1 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *)  pkgs="$pkgs $1" ;;
  esac
  shift
done

[ -n "$pkgs" ] || { usage; exit 1; }
for p in $pkgs; do apply_package "$p"; done