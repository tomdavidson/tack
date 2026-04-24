#!/usr/bin/env bash
# ach-manifest.sh — Generate a project manifest + bundled text files for AI context.
# Run from the package root (e.g. packages/astro-content-hub).
#
# Usage:
#   ./ach-manifest.sh                  # manifest only (stdout)
#   ./ach-manifest.sh -o manifest.txt  # manifest to file
#   ./ach-manifest.sh -b               # manifest (stdout) + bundled source files
#   ./ach-manifest.sh -b -o out.txt    # manifest to file + bundled source files
#
# With -b, produces a single <dirname>-bundle.txt containing every source file
# with strong delimiters. Attach manifest.txt + the bundle + any individual
# files you want high-fidelity reads on (10 file limit total).

set -eo pipefail

BUNDLE=false
OUTFILE=""

while getopts "bo:" opt; do
  case $opt in
    b) BUNDLE=true ;;
    o) OUTFILE="$OPTARG" ;;
    *)
      echo "Usage: $0 [-b] [-o manifest.txt]" >&2
      exit 1
      ;;
  esac
done

PROJ="$(basename "$PWD")"
BUNDLE_FILE="${PROJ}-bundle.txt"

# Collect tracked + untracked source files, excluding noise.
file_list() {
  git ls-files --cached --others --exclude-standard |
    grep -E '\.(ts|astro|json|md|mjs|yml|yaml)$' |
    grep -v -E '(node_modules/|dist/|\.astro/|\.turbo/)' |
    sort
}

# --- Manifest ---
{
  echo "# ${PROJ} — project manifest"
  echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "## Tree"
  echo ""
  if command -v tree &> /dev/null; then
    tree --gitignore -I 'node_modules|dist|.astro|.turbo' 2> /dev/null || true
  else
    find . -not -path '*/node_modules/*' \
      -not -path '*/dist/*' \
      -not -path '*/.astro/*' \
      -not -name '*.lock' \
      -type f | sort | sed 's|^\./||'
  fi
  echo ""
  echo "## File previews (first 4 lines each)"
  echo ""
  file_list | while IFS= read -r f; do
    lines=$(wc -l < "$f" 2> /dev/null || echo "?")
    printf '########## %s (%s lines) ##########\n' "$f" "$lines"
    head -4 "$f" 2> /dev/null || true
    echo "..."
    echo ""
  done
} | if [ -n "$OUTFILE" ]; then
  tee "$OUTFILE"
else
  cat
fi

# --- Bundle ---
if [ "$BUNDLE" = true ]; then
  rm -f "$BUNDLE_FILE"
  {
    echo "# ${PROJ} — full source bundle"
    echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    file_list | while IFS= read -r f; do
      echo "########## FILE: ${f} ##########"
      cat "$f"
      echo ""
      echo "########## END: ${f} ##########"
      echo ""
    done
  } > "$BUNDLE_FILE"
  echo "" >&2
  echo "Bundle created: $BUNDLE_FILE ($(du -h "$BUNDLE_FILE" | cut -f1))" >&2
  echo "" >&2
fi
