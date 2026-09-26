#!/usr/bin/env bash
# scripts/bootstrap.sh
#
# One-time setup for a tack consumer repo.
# Run this once after cloning. Commit the results. Never needs to run again
# unless you add a new tack package or update the .tack submodule.
#
# What it does:
#   1. Ensures the .tack submodule is initialised and checked out.
#   2. Runs tack.sh to materialise all configs into this repo.
#   3. Prints next steps (commit + devenv).
#
# Requirements (all present in the tack-dev container image):
#   git, bash, lnko, tera, yq
#
# Usage:
#   bash scripts/bootstrap.sh          # after first clone
#   bash scripts/bootstrap.sh --tack   # re-run tack only (skip submodule step)

set -euo pipefail

TACK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --tack) TACK_ONLY=1 ;;
    *)
      printf 'unknown arg: %s\n' "$arg" >&2
      exit 1
      ;;
  esac
done

log() { printf '[bootstrap] %s\n' "$*"; }
die() {
  printf '[bootstrap] error: %s\n' "$*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TACK_DIR="$REPO_ROOT/.tack"

cd "$REPO_ROOT"

# ── 1. Submodule ──────────────────────────────────────────────────────────────
if [ "$TACK_ONLY" -eq 0 ]; then
  if [ ! -f "$TACK_DIR/tack.sh" ]; then
    log "initialising .tack submodule..."
    git submodule update --init --recursive
  else
    log ".tack submodule already present"
  fi
fi

[ -f "$TACK_DIR/tack.sh" ] || die ".tack/tack.sh not found. Run without --tack or init the submodule manually."

# ── 2. Run tack ───────────────────────────────────────────────────────────────
log "running tack..."
bash "$TACK_DIR/tack.sh" --target "$REPO_ROOT"

# ── 3. Next steps ─────────────────────────────────────────────────────────────
cat << 'EOF'

[bootstrap] done.

Next steps:
  1. Review what tack materialised:
       git status
       git diff

  2. Commit the generated configs (they are consumer-owned):
       git add -A
       git commit -m 'chore: bootstrap tack configs'

  3. Start your dev environment:
       devenv shell

  To re-run tack after updating .tack or adding packages:
       bash scripts/bootstrap.sh --tack
EOF
