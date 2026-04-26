#!/usr/bin/env bash
# tack.sh - apply tack packages to a consumer repo
# Lives at the tack repo root.
# Usage: ./tack.sh [--dry-run] [--target DIR] [<package-path>...]
#
# Control file (single source of runtime configuration):
#   <tack>/tackrc-defaults.yml deep-merged with <consumer>/tackrc.yml.
#   The merged result is the runtime controller and the default tera context.
#   Missing consumer file is fine; missing defaults file is a hard error.
#
# Package selection (no CLI args):
#   pkgs:           list of path globs relative to $TACK_ROOT (e.g. "configs/*", "scripts")
#   pkgs_exclude:   list of path globs subtracted from the resolved pkgs list
#   pkgs_metadata:  mapping keyed by package path; the matching subtree is
#                   exposed to tera as `.pkg` per render.
#
# Per-package context (not control):
#   <pkg>/tack-manifest.yml declares parameters that cannot be derived from
#   filename and path: render vars source, concat target, merge target,
#   link.unfold dirs.
#
# Dispatch:
#   *.tera.*           render via tera
#   *.copy.*           copy verbatim
#   *.concat.*         append to manifest-declared target (signature-dedup)
#   *.merge.json       deep-merge into manifest-declared target via yq
#   *.merge.yml|.yaml  deep-merge into manifest-declared target via yq
#   *.merge.toml       refused; use *.concat.toml instead
#   everything else    symlink via lnko (except tack-manifest.yml and tack.yml)

set -euo pipefail

# Static fallback when not running from a git checkout (e.g. release tarball).
# Bump on tagged release.
TACK_VERSION_FALLBACK="0.1.0"

# Diagnostic EXIT trap: any nonzero exit (including silent set -e
# aborts that might otherwise vanish inside command substitution)
# prints status, line, and command before the shell dies. Cleans up
# any tack-err side files left by resolve_pkgs.
# _TACK_CLEANUPS holds newline-separated paths to remove on exit.
# Inner functions push paths via tack_cleanup_add instead of registering
# their own EXIT traps (which would clobber this diagnostic trap).
_TACK_CLEANUPS=""
tack_cleanup_add() {
  _TACK_CLEANUPS="${_TACK_CLEANUPS}$1
"
}
_tack_on_exit() {
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    printf '[tack] aborted: exit=%d line=%d cmd=%s\n' \
      "$_rc" "${BASH_LINENO[0]:-0}" "${BASH_COMMAND:-?}" >&2
  fi
  [ -n "${TACK_ERR_FILE:-}" ] && rm -f "$TACK_ERR_FILE"
  if [ -n "$_TACK_CLEANUPS" ]; then
    printf '%s' "$_TACK_CLEANUPS" | while IFS= read -r _p; do
      [ -n "$_p" ] && rm -rf "$_p"
    done
  fi
  return $_rc
}
trap _tack_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Shell discipline (mandatory under set -eu):
#
# 1. Never end a function, subshell, or while/for body on a bare
#    `cmd1 && cmd2` or `cmd1 || cmd2` standalone statement. If cmd1
#    fails, set -e fires and aborts the parent SILENTLY because
#    command substitution swallows the message. Use an explicit
#    `if cmd1; then cmd2; fi` instead, or terminate with `:` / a
#    `return 0`.
#
# 2. Inside `var=$(fn)`, any nonzero exit from fn aborts the parent
#    with no diagnostic. Functions called in command substitution
#    must return 0 except on conditions the caller is prepared to
#    distinguish; signal errors via stdout sentinels or a side file,
#    not via `die` (die's stderr survives but the silent set -e
#    abort happens first if any prior command in fn returned 1).
#
# 3. Conditional contexts (`if`, `while`, `||`, `&&` as the test of
#    a compound) suppress set -e for the tested command; standalone
#    statements do not. When in doubt, wrap in `if`.

TACK_ROOT="${TACK_ROOT:-$(cd "$(dirname "$0")" && pwd)}"
DRY_RUN=0
TARGET="$PWD"
TACK_CONSUMER_ROOT="${TACK_CONSUMER_ROOT:-}"
MERGED_TACKRC=""
CURRENT_PKG_CTX=""

log() { printf '[tack] %s\n' "$*" >&2; }
die() { printf '[tack] error: %s\n' "$*" >&2; exit 1; }

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

require_core_deps() {
  require_bin lnko "install from https://github.com/tomdavidson/lnko releases"
  require_bin tera "install with: cargo install tera-cli"
  require_bin yq   "install Go yq from https://github.com/mikefarah/yq"
}

strip_marker() { printf '%s\n' "$1" | sed -E 's/\.(tera|copy|concat|merge)\./\./'; }
rel_in_pkg()   { printf '%s\n' "${1#"$2"/}"; }

load_tackrc() {
  defaults="$TACK_ROOT/tackrc-defaults.yml"
  consumer="$TACK_CONSUMER_ROOT/tackrc.yml"
  [ -f "$defaults" ] || die "$defaults missing; tack repo is incomplete"
  rc_dir=$(mktemp -d -t tack-rc.XXXXXX)
  MERGED_TACKRC="$rc_dir/tackrc.yml"
  tack_cleanup_add "$rc_dir"
  if [ -f "$consumer" ]; then
    # shellcheck disable=SC2016
    yq ea '. as $i ireduce ({}; . * $i)' "$defaults" "$consumer" > "$MERGED_TACKRC"
  else
    cp "$defaults" "$MERGED_TACKRC"
  fi
}

# rc_list KEY -- newline-separated entries from a top-level list in the
# merged tackrc, or empty if the key is missing/empty.
rc_list() {
  key=$1
  yq -r ".${key}[]?" "$MERGED_TACKRC" 2>/dev/null || true
}

# expand_glob PATTERN -- echoes matching directories under $TACK_ROOT, one
# per line. Path-shaped globs are resolved relative to $TACK_ROOT.
# Literals (no wildcards) that don't resolve to a directory return nothing.
expand_glob() {
  pat=$1
  (
    cd "$TACK_ROOT" || exit 0
    # shellcheck disable=SC2086
    for entry in $pat; do
      if [ -d "$entry" ]; then
        printf '%s\n' "$entry"
      fi
    done
    :
  )
}

has_glob_chars() {
  case "$1" in
    *'*'*|*'?'*|*'['*) return 0 ;;
    *) return 1 ;;
  esac
}

# pat_match_any PATTERN LIST -- echoes lines from LIST (newline-separated)
# that case-match PATTERN. PATTERN is a shell glob (e.g. configs/*).
pat_match_any() {
  pat=$1
  list=$2
  printf '%s\n' "$list" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    # shellcheck disable=SC2254
    case "$p" in
      $pat) printf '%s\n' "$p" ;;
    esac
  done
}

# in_list NEEDLE LIST -- exit 0 if NEEDLE appears as a whole line in LIST.
in_list() {
  needle=$1
  list=$2
  printf '%s\n' "$list" | grep -Fxq -- "$needle"
}

# resolve_pkgs -- echoes the final newline-separated list of package paths
# from pkgs/pkgs_exclude in the merged tackrc. Hard-errors (via die) if a
# literal pkg entry does not resolve to a directory.
resolve_pkgs() {
  raw_pkgs=$(rc_list pkgs)
  raw_excl=$(rc_list pkgs_exclude)

  # Loops use while-read instead of `for pat in $raw_pkgs` so the unquoted
  # patterns (`configs/*`, `configs/exp-*`) are NOT pathname-expanded against
  # the script's CWD before reaching expand_glob. expand_glob handles its own
  # cd into TACK_ROOT before letting the shell expand.

  selected=""
  missing_lit=""
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    matches=$(expand_glob "$pat")
    if [ -z "$matches" ]; then
      if has_glob_chars "$pat"; then
        continue
      else
        missing_lit="${missing_lit}${pat}
"
        continue
      fi
    fi
    selected="${selected}${matches}
"
  done <<EOF
$raw_pkgs
EOF

  if [ -n "$missing_lit" ]; then
    first=$(printf '%s' "$missing_lit" | awk 'NF{print; exit}')
    printf 'missing_literal:%s\n' "$first" > "$TACK_ERR_FILE"
    return 0
  fi

  if [ -n "$selected" ]; then
    selected=$(printf '%s' "$selected" | awk 'NF && !seen[$0]++')
  fi

  if [ -n "$raw_excl" ] && [ -n "$selected" ]; then
    excl_expanded=""
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      m=$(pat_match_any "$pat" "$selected")
      [ -n "$m" ] && excl_expanded="${excl_expanded}${m}
"
    done <<EOF
$raw_excl
EOF
    if [ -n "$excl_expanded" ]; then
      excl_expanded=$(printf '%s' "$excl_expanded" | awk 'NF && !seen[$0]++')
      filtered=""
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        in_list "$p" "$excl_expanded" && continue
        filtered="${filtered}${p}
"
      done <<EOF
$selected
EOF
      selected=$filtered
    fi
  fi

  if [ -n "$selected" ]; then
    printf '%s' "$selected" | awk 'NF'
  fi
  return 0
}

# pkg_metadata_ctx PKG -- writes a per-render tera context file by adding
# `.pkg = .pkgs_metadata[<pkg>] // {}` to the merged tackrc. Echoes path.
pkg_metadata_ctx() {
  pkg=$1
  ctx_dir=$(mktemp -d -t tack-pkgctx.XXXXXX)
  ctx="$ctx_dir/ctx.yml"
  yq ".pkg = (.pkgs_metadata[\"$pkg\"] // {})" "$MERGED_TACKRC" > "$ctx"
  printf '%s' "$ctx"
}

manifest_get() {
  manifest=$1; src_rel=$2; field=$3
  [ -f "$manifest" ] || { printf ''; return 0; }
  yq -r ".files[\"$src_rel\"].$field // \"\"" "$manifest"
}

manifest_unfold() {
  manifest=$1
  [ -f "$manifest" ] || return 0
  yq -r '.link.unfold[]?' "$manifest"
}

link_package() {
  pkg_dir=$1; target=$2
  log "link: $pkg_dir -> $target"
  run lnko link \
    --ignore '*.tera.*' \
    --ignore '*.copy.*' \
    --ignore '*.concat.*' \
    --ignore '*.merge.*' \
    --ignore 'tack-manifest.yml' \
    --ignore 'tack.yml' \
    -t "$target" \
    "$pkg_dir"
}

apply_unfold() {
  pkg_dir=$1; manifest=$2; target=$3
  manifest_unfold "$manifest" | while IFS= read -r d; do
    [ -n "$d" ] || continue
    log "unfold: $d"
    run mkdir -p "$target/$d"
  done
}

resolve_vars_from() {
  raw=$1; src_rel=$2
  case "$raw" in
    tackrc.yml|@consumer/tackrc.yml) printf '%s' "$MERGED_TACKRC" ;;
    /*)             printf '%s' "$raw" ;;
    \~/*)           printf '%s' "$HOME/${raw#\~/}" ;;
    '@tack/'*)      printf '%s' "$TACK_ROOT/${raw#@tack/}" ;;
    '@consumer/'*)  printf '%s' "$TACK_CONSUMER_ROOT/${raw#@consumer/}" ;;
    *)              printf '%s' "$TACK_CONSUMER_ROOT/$raw" ;;
  esac
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
    ctx=$(resolve_vars_from "$vars_from" "$src_rel")
  else
    ctx="$CURRENT_PKG_CTX"
  fi
  [ -f "$ctx" ] || [ "$DRY_RUN" -eq 1 ] || die "vars_from not found: $ctx (from $src_rel)"
  run tera --template "$src" --include-path "$TACK_ROOT" "$ctx" --out "$dest"
  if [ -n "$post" ]; then
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

merge_file() {
  src=$1; pkg_dir=$2; manifest=$3; target=$4
  src_rel=$(rel_in_pkg "$src" "$pkg_dir")
  ext=${src##*.}
  case "$ext" in
    json)     fmt=json ;;
    yml|yaml) fmt=yaml ;;
    toml)
      die "$src_rel: *.merge.toml not supported. Use *.concat.toml for textual append. See ADR-0002."
      ;;
    *)
      die "$src_rel: *.merge.$ext unsupported extension"
      ;;
  esac

  merge_target=$(manifest_get "$manifest" "$src_rel" target)
  [ -n "$merge_target" ] || die "merge file $src_rel requires files[\"$src_rel\"].target in $manifest"
  dest="$target/$merge_target"

  log "merge: $src_rel -> $merge_target"

  if [ ! -f "$dest" ]; then
    [ "$DRY_RUN" -eq 1 ] || die "merge target missing: $dest"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] yq deep-merge %s into %s (%s)\n' "$src" "$dest" "$fmt"
    return 0
  fi

  yq -p "$fmt" -o "$fmt" '.' "$src"  >/dev/null 2>&1 \
    || die "merge fragment is not valid $fmt: $src"
  yq -p "$fmt" -o "$fmt" '.' "$dest" >/dev/null 2>&1 \
    || die "merge target is not valid $fmt: $dest"

  tmp=$(mktemp)
  tack_cleanup_add "$tmp"
  # shellcheck disable=SC2016
  if ! yq -p "$fmt" -o "$fmt" ea '
        . as $i ireduce ({}; . *+ $i)
        | (.. | select(tag == "!!seq")) |= unique
      ' "$dest" "$src" > "$tmp"; then
    rm -f "$tmp"
    die "yq merge failed: $src into $dest"
  fi
  mv "$tmp" "$dest"
}

iterate_files() {
  pkg_dir=$1; pattern=$2; handler=$3; shift 3
  tmp=$(mktemp)
  tack_cleanup_add "$tmp"
  find "$pkg_dir" -type f -name "$pattern" > "$tmp"
  while IFS= read -r f; do
    "$handler" "$f" "$@"
  done < "$tmp"
  rm -f "$tmp"
  :
}

apply_package() {
  pkg=$1
  pkg_dir="$TACK_ROOT/$pkg"
  [ -d "$pkg_dir" ] || die "no such package: $pkg"
  manifest="$pkg_dir/tack-manifest.yml"

  # Build a per-package tera context: merged tackrc with .pkg bound to
  # pkgs_metadata[<this pkg path>] (or {} if absent).
  CURRENT_PKG_CTX=$(pkg_metadata_ctx "$pkg")

  apply_unfold  "$pkg_dir" "$manifest" "$TARGET"
  link_package  "$pkg_dir" "$TARGET"
  iterate_files "$pkg_dir" '*.tera.*'   _h_render "$pkg_dir" "$manifest" "$TARGET"
  iterate_files "$pkg_dir" '*.copy.*'   _h_copy   "$pkg_dir" "$TARGET"
  iterate_files "$pkg_dir" '*.concat.*' _h_concat "$pkg_dir" "$manifest" "$TARGET"
  iterate_files "$pkg_dir" '*.merge.*'  _h_merge  "$pkg_dir" "$manifest" "$TARGET"
}

_h_render() { render_file "$1" "$2" "$3" "$4"; }
_h_copy()   { copy_file   "$1" "$2" "$3"; }
_h_concat() { concat_file "$1" "$2" "$3" "$4"; }
_h_merge()  { merge_file  "$1" "$2" "$3" "$4"; }

print_version() {
  if command -v git >/dev/null 2>&1 && \
     git -C "$TACK_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    desc=$(git -C "$TACK_ROOT" describe --tags --always --dirty 2>/dev/null || true)
    branch=$(git -C "$TACK_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [ -n "$desc" ] && [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
      printf 'tack %s (%s)\n' "$desc" "$branch"
      return 0
    fi
    if [ -n "$desc" ]; then
      printf 'tack %s\n' "$desc"
      return 0
    fi
  fi
  printf 'tack %s\n' "$TACK_VERSION_FALLBACK"
}

usage() {
  cat <<EOF
Usage: ./tack.sh [options] [--] [<package-path>...]

Options:
  --dry-run        Print actions without executing
  --target DIR     Target directory (default: \$PWD)
  --               End of options; remaining args are package paths
  -V, --version    Print version (git describe + branch when available)
  -h, --help       Show this help

Selection precedence:
  1. If <package-path> args are given, they override pkgs and pkgs_exclude
     entirely.
  2. Otherwise: resolved pkgs minus resolved pkgs_exclude from the merged
     tackrc. Empty selection is a hard error.

Packages are paths relative to TACK_ROOT (e.g. configs/rust, scripts).
With no package args, packages are taken from the merged tackrc:
  pkgs:           list of path globs (e.g. "configs/*", "scripts")
  pkgs_exclude:   list of path globs subtracted from the resolved pkgs list
  pkgs_metadata:  mapping keyed by package path; the matching subtree is
                  exposed to tera as \`.pkg\` per render.

Control file:
  <tack>/tackrc-defaults.yml deep-merged with <consumer>/tackrc.yml.
  Required: tackrc-defaults.yml. Optional: consumer tackrc.yml.

Dispatch by filename marker:
  *.tera.*           render via tera
  *.copy.*           copy verbatim
  *.concat.*         append to manifest-declared target
  *.merge.json       deep-merge into manifest-declared target via yq
  *.merge.yml|.yaml  deep-merge into manifest-declared target via yq
  *.merge.toml       refused; use *.concat.toml instead
  (other)            symlink via lnko (skips tack-manifest.yml, tack.yml)

Environment:
  TACK_ROOT            Path to the tack repo (default: dir of tack.sh)
  TACK_CONSUMER_ROOT   Path to the consumer repo (default: --target)

Exit codes:
  0   success
  1   error (see [tack] error: ... message on stderr)
  130 interrupted (SIGINT)
  143 terminated (SIGTERM)

Requires: bash 4+, and lnko, tera, yq (Go yq) on PATH.
EOF
}

cli_pkgs=""
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run)     DRY_RUN=1 ;;
    --target)      shift; [ $# -gt 0 ] || die "--target requires a DIR"; TARGET=$1 ;;
    -V|--version)  print_version; exit 0 ;;
    -h|--help)     usage; exit 0 ;;
    --)            shift; break ;;
    -*)            die "unknown option: $1" ;;
    *)             cli_pkgs="$cli_pkgs $1" ;;
  esac
  shift
done

: "${TACK_CONSUMER_ROOT:=$TARGET}"

require_core_deps
load_tackrc

if [ -n "$cli_pkgs" ]; then
  pkgs_to_apply="$cli_pkgs"
else
  TACK_ERR_FILE=$(mktemp -t tack-err.XXXXXX)
  export TACK_ERR_FILE
  resolved=$(resolve_pkgs)
  if [ -s "$TACK_ERR_FILE" ]; then
    err=$(cat "$TACK_ERR_FILE")
    rm -f "$TACK_ERR_FILE"
    case "$err" in
      missing_literal:*)
        die "pkg literal does not resolve to a directory: ${err#missing_literal:}"
        ;;
      *)
        die "resolve_pkgs error: $err"
        ;;
    esac
  fi
  rm -f "$TACK_ERR_FILE"
  resolved=$(printf '%s' "$resolved" | awk 'NF' || true)
  [ -n "$resolved" ] || die "no packages selected: pass packages on CLI or set pkgs in tackrc.yml"
  pkgs_to_apply=$(printf '%s' "$resolved" | tr '\n' ' ')
fi

for p in $pkgs_to_apply; do apply_package "$p"; done
