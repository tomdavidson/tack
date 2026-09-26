#!/usr/bin/env bash
# pkgs/sbx.sh
#
# sbx: run a development tool inside an unprivileged bubblewrap sandbox.
#
# The sandbox hides the real $HOME (ssh keys, cloud creds, shell history),
# the Nix daemon socket, agent sockets in /run, /media and /mnt, and gives
# the wrapped tool write access to exactly one tree: the repo root (plus a
# shared dev root holding other projects and package caches, when the repo
# lives under it). Everything else is mounted read-only.
#
# Tool resolution happens on the HOST, before bwrap starts, because
# `proto bin <tool>` and $HOME lookups must run outside the sandbox:
#
#   1. explicit path (contains /)            -> used verbatim
#   2. `proto bin <name>`                    -> proto tool (node, pnpm, moon)
#   3. $PROTO_HOME/shims/<name>              -> proto bin (npx, npm, corepack)
#   4. $CARGO_HOME/bin/<name>                -> rust (proto keeps bins there)
#   5. PATH, skipping */.devenv* wrappers    -> anything else
#
# devenv scripts call `sbx <tool>`, so wrapped tools resolve through this
# chain on every invocation. Re-entering sbx from inside a sandbox is a
# no-op: SBX_ACTIVE is set in the sandbox environment and sbx execs the
# resolved command directly (no nesting).
#
# pnpm note: hardlinks only work inside ONE mount. When the repo is under
# SBX_DEV_ROOT (default ~/dev), the store lives at $SBX_DEV_ROOT/.sbx/pnpm-store
# inside the same bind mount and hardlinks work. Otherwise pnpm silently
# falls back to copying. See docs/sbx.md.
#
# Environment variables:
#   SBX_BWRAP           bwrap binary (default: from PATH; baked by pkgs/sbx.nix)
#   SBX_DEV_ROOT        shared writable root holding projects + caches
#                       (default: ~/dev when the repo lives under it)
#   SBX_STRICT          1 = bind only the repo root (no sibling projects);
#                       pnpm loses hardlink dedup in this mode
#   SBX_NO_NET          1 = --unshare-net
#   SBX_ALLOW_USERNS    1 = allow nested user namespaces (Chromium/Playwright)
#   SBX_ACTIVE          set inside the sandbox; sbx re-entry execs directly
#
# Usage: sbx [--print-cmd] [--strict] <command> [args...]
#   --print-cmd  resolve and print the exec target, then exit (no sandbox)

set -euo pipefail

progname=${0##*/}

die() {
  printf '%s: error: %s\n' "$progname" "$*" >&2
  exit 1
}

log() {
  printf '%s: %s\n' "$progname" "$*" >&2
}

# ---------- tool resolution (host side) ----------

# path_lookup NAME -- first executable NAME on PATH, skipping devenv script
# wrappers (they call back into sbx; SBX_ACTIVE makes that safe, but resolving
# the real binary directly avoids the extra hop) and skipping non-files.
path_lookup() {
  needle=$1
  # PATH entries originate from the trusted environment, not user input.
  # shellcheck disable=SC2016
  found=""
  saved_ifs=$IFS
  IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    case "$dir" in
      */.devenv* | .devenv*) continue ;;
    esac
    if [ -f "$dir/$needle" ] && [ -x "$dir/$needle" ]; then
      found=$dir/$needle
      break
    fi
  done
  IFS=$saved_ifs
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# resolve_cmd CMD -- absolute path of the binary to exec.
resolve_cmd() {
  cmd=$1
  case "$cmd" in
    */*)
      [ -x "$cmd" ] || die "not executable: $cmd"
      printf '%s\n' "$cmd"
      return 0
      ;;
  esac

  proto_home=${PROTO_HOME:-$HOME/.proto}
  cargo_home=${CARGO_HOME:-$HOME/.cargo}

  if command -v proto > /dev/null 2>&1; then
    if p=$(proto bin "$cmd" 2> /dev/null) && [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  fi
  if [ -f "$proto_home/shims/$cmd" ] && [ -x "$proto_home/shims/$cmd" ]; then
    printf '%s\n' "$proto_home/shims/$cmd"
    return 0
  fi
  if [ -f "$cargo_home/bin/$cmd" ] && [ -x "$cargo_home/bin/$cmd" ]; then
    printf '%s\n' "$cargo_home/bin/$cmd"
    return 0
  fi
  if p=$(path_lookup "$cmd"); then
    printf '%s\n' "$p"
    return 0
  fi
  die "cannot resolve '$cmd': not a proto tool, shim, cargo bin, or on PATH"
}

# ---------- repo root ----------

# find_repo_root -- nearest ancestor of $PWD containing .git. Never shells out
# to git: a repo's own config can execute code (core.fsmonitor, aliases).
find_repo_root() {
  d=$PWD
  while :; do
    if [ -e "$d/.git" ]; then
      printf '%s\n' "$d"
      return 0
    fi
    if [ "$d" = "/" ]; then
      break
    fi
    d=$(dirname "$d")
  done
  printf '%s\n' "$PWD"
}

# under DIR -- exit 0 when $PWD is under DIR.
under() {
  root=$1
  case "$PWD/" in
    "$root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- main ----------

usage() {
  cat << EOF
Usage: sbx [--print-cmd] [--strict] <command> [args...]

Run <command> inside a bubblewrap sandbox. See docs/sbx.md for the mount
layout, cache handling, and settings (SBX_DEV_ROOT, SBX_STRICT, SBX_NO_NET,
SBX_ALLOW_USERNS).
EOF
}

main() {
  print_cmd=0
  strict=${SBX_STRICT:-0}
  while [ $# -gt 0 ]; do
    case $1 in
      --print-cmd)
        print_cmd=1
        ;;
      --strict)
        strict=1
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        break
        ;;
    esac
    shift
  done
  [ $# -gt 0 ] || die "missing command (see --help)"
  cmd=$1
  shift

  # Already inside a sandbox: exec directly. Devenv script wrappers resolve
  # through sbx again when a sandboxed tool invokes them by name; this makes
  # that a plain exec of the real binary instead of a nested bwrap attempt.
  if [ -n "${SBX_ACTIVE:-}" ]; then
    exec "$(resolve_cmd "$cmd")" "$@"
  fi

  exec_cmd=$(resolve_cmd "$cmd")

  if [ "$print_cmd" -eq 1 ]; then
    printf '%s\n' "$exec_cmd"
    exit 0
  fi

  bwrap_bin=${SBX_BWRAP:-$(command -v bwrap || true)}
  [ -n "$bwrap_bin" ] || die "bwrap not found; set SBX_BWRAP or add bubblewrap to PATH"

  repo_root=$(find_repo_root)
  proto_home=${PROTO_HOME:-$HOME/.proto}
  cargo_home_host=${CARGO_HOME:-$HOME/.cargo}
  rustup_home_host=${RUSTUP_HOME:-$HOME/.rustup}

  # ----- writable roots and caches -----
  # bind_cache: 1 when the cache tree is not under a bound writable root and
  # needs its own --bind. In single-root mode everything (projects, caches,
  # pnpm store) is ONE bind mount so pnpm hardlinks survive.
  default_dev_root=$HOME/dev
  if [ "$strict" -eq 1 ]; then
    writable_roots=$repo_root
    cache_root=${XDG_CACHE_HOME:-$HOME/.cache}/sbx
    bind_cache=1
  elif [ -n "${SBX_DEV_ROOT:-}" ]; then
    dev_root=$SBX_DEV_ROOT
    cache_root=$dev_root/.sbx
    if under "$dev_root"; then
      writable_roots=$dev_root
      bind_cache=0
    else
      writable_roots="$dev_root
$repo_root"
      bind_cache=0
    fi
  elif [ -d "$default_dev_root" ] && under "$default_dev_root"; then
    writable_roots=$default_dev_root
    cache_root=$default_dev_root/.sbx
    bind_cache=0
  else
    writable_roots=$repo_root
    cache_root=${XDG_CACHE_HOME:-$HOME/.cache}/sbx
    bind_cache=1
    log "repo is not under $default_dev_root; pnpm will copy instead of hardlink"
    log "set SBX_DEV_ROOT or move the repo under it for dedup"
  fi
  mkdir -p \
    "$cache_root/pnpm-store" \
    "$cache_root/pnpm-cache" \
    "$cache_root/pip" \
    "$cache_root/uv" \
    "$cache_root/cargo/registry" \
    "$cache_root/cargo/git" \
    "$cache_root/cargo-home" \
    "$cache_root/proto" 2> /dev/null || true

  pnpm_store=$cache_root/pnpm-store

  # ----- mount list -----
  args=()

  # Root filesystem: read-only, minus the noisy parts. /run is an empty
  # tmpfs (hides ssh-agent, gpg-agent, D-Bus, Wayland, the nix daemon
  # socket) with systemd-resolved data bound back for DNS.
  args+=(
    --ro-bind /usr /usr
    --ro-bind /etc /etc
    --dev /dev
    --proc /proc
    --tmpfs /tmp
    --tmpfs /run
    --die-with-parent
    --new-session
    --unshare-user
    --unshare-pid
    --unshare-ipc
    --unshare-uts
  )
  if [ -d /run/systemd/resolve ]; then
    args+=(--ro-bind /run/systemd/resolve /run/systemd/resolve)
  fi
  if [ -d /nix ]; then
    args+=(--ro-bind /nix /nix)
  fi
  if [ -d /opt ]; then
    args+=(--ro-bind /opt /opt)
  fi
  # usrmerge systems symlink these into /usr; older layouts have real dirs.
  for d in /bin /lib /lib64 /sbin; do
    if [ -L "$d" ]; then
      args+=(--symlink "$(readlink "$d")" "$d")
    elif [ -d "$d" ]; then
      args+=(--ro-bind "$d" "$d")
    fi
  done

  # Home: empty tmpfs, then bind back only toolchains (read-only) and
  # writable caches. Host credentials (~/.ssh, ~/.aws, ~/.config, gitconfig
  # tokens) stay hidden.
  args+=(--tmpfs "$HOME")
  if [ -d "$proto_home" ]; then
    args+=(--ro-bind "$proto_home" "$proto_home")
    if [ -d "$proto_home/cache" ]; then
      args+=(--bind "$cache_root/proto" "$proto_home/cache")
    fi
  fi
  if [ -d "$cargo_home_host" ]; then
    args+=(--ro-bind "$cargo_home_host" "$cargo_home_host")
    args+=(--bind "$cache_root/cargo/registry" "$cargo_home_host/registry")
    args+=(--bind "$cache_root/cargo/git" "$cargo_home_host/git")
  fi
  if [ -d "$rustup_home_host" ]; then
    args+=(--ro-bind "$rustup_home_host" "$rustup_home_host")
  fi
  # Git identity without secrets: ~/.gitconfig and ~/.config/git stay
  # readable so `git commit` inside the sandbox still has user.name/email.
  if [ -f "$HOME/.gitconfig" ]; then
    args+=(--ro-bind "$HOME/.gitconfig" "$HOME/.gitconfig")
  fi
  if [ -d "$HOME/.config/git" ]; then
    args+=(--ro-bind "$HOME/.config/git" "$HOME/.config/git")
  fi

  # Writable roots.
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    args+=(--bind "$root" "$root")
  done << EOF
$writable_roots
EOF
  if [ "$bind_cache" -eq 1 ]; then
    args+=(--bind "$cache_root" "$cache_root")
  fi

  # Repo files that later execute OUTSIDE the sandbox are read-only, so
  # sandboxed code cannot plant persistence (.git hooks, direnv, devenv,
  # nix expressions, the .tack submodule).
  for rel in .git/hooks .envrc devenv.nix devenv.yaml devenv.lock flake.lock nix .tack; do
    if [ -e "$repo_root/$rel" ]; then
      args+=(--ro-bind "$repo_root/$rel" "$repo_root/$rel")
    fi
  done

  if [ "${SBX_ALLOW_USERNS:-0}" != "1" ]; then
    args+=(--disable-userns)
  fi
  if [ "${SBX_NO_NET:-0}" = "1" ]; then
    args+=(--unshare-net)
  fi

  # ----- environment -----
  # bwrap --clearenv removes everything; add back an allowlist. Anything
  # that looks like a secret is dropped even when its name is allowlisted
  # (NIX_GITHUB_TOKEN etc). Compiler variables survive so nix-built native
  # dependencies keep working.
  args+=(--clearenv)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=${line%%=*}
    value=${line#*=}
    [ -n "$name" ] || continue
    case "$name" in
      PATH | HOME | USER | LOGNAME | SHELL | TERM | COLORTERM | LANG | LC_* | TZ | PWD | TMPDIR | PROTO_HOME | CARGO_HOME | RUSTUP_HOME | NIX_* | PKG_CONFIG* | CPATH | LD_LIBRARY_PATH)
        case "$name" in
          *TOKEN* | *SECRET* | *PASSWORD* | *PASS* | *CRED* | *KEY*) continue ;;
        esac
        args+=(--setenv "$name" "$value")
        ;;
    esac
  done < <(env)
  args+=(
    --setenv SBX_ACTIVE 1
    --setenv pnpm_config_store_dir "$pnpm_store"
    --setenv pnpm_config_cache_dir "$cache_root/pnpm-cache"
    --setenv PIP_CACHE_DIR "$cache_root/pip"
    --setenv UV_CACHE_DIR "$cache_root/uv"
    --setenv PYTHONDONTWRITEBYTECODE 1
  )
  if [ ! -d "$cargo_home_host" ]; then
    # No rust toolchain on the host (cargo likely from nix/devenv): point
    # CARGO_HOME at the persistent sandbox cache so registry and git
    # checkouts survive between runs.
    args+=(--setenv CARGO_HOME "$cache_root/cargo-home")
  fi

  args+=(--chdir "$PWD")
  exec "$bwrap_bin" "${args[@]}" -- "$exec_cmd" "$@"
}

main "$@"
