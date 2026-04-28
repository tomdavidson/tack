#!/usr/bin/env bash
set -euo pipefail

branch="$(git branch --show-current)"

# Find upstream; if none, do nothing and allow push
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" 2> /dev/null || true)"
if [[ -z $upstream ]]; then
  # No upstream to compare against, nothing to squash relative to remote
  exit 0
fi

git fetch "${upstream%%/*}" > /dev/null 2>&1 || true

ahead_count="$(git rev-list --count "${upstream}"..HEAD || echo 0)"
if [[ $ahead_count -le 1 ]]; then
  # Zero or one commit ahead, no need to squash
  exit 0
fi

echo "Branch '$branch' has $ahead_count commits ahead of '$upstream':"
git log --oneline "${upstream}"..HEAD
echo
read -r -p "Squash these into one commit before pushing? [y/N] " ans

case "$ans" in
  [Yy] | [Yy][Ee][Ss]) ;;
  *)
    echo "Leaving commits as-is. Push will continue."
    exit 0
    ;;
esac

msg_file="$(mktemp)"
git log "${upstream}"..HEAD --pretty=format:'%s%n%n%b%n----%n' > "$msg_file"

echo "Squashing commits into one. A combined message will open in your editor."
git reset --soft "${upstream}"

GIT_COMMIT_MSG_FILE="$msg_file" git commit --edit -F "$msg_file"
rm -f "$msg_file"

echo "New squashed commit on '$branch':"
git log -1 --oneline

exit 0
