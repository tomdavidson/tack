repo="tomdavidson/$(basename "$PWD")"

gh repo create "$repo" \
  --source=. \
  --remote=origin \
  --push \
  --private \
  --disable-issues \
  --disable-wiki

gh repo edit "$repo" \
  --enable-projects=false \
  --enable-discussions=false \
  --delete-branch-on-merge \
  --enable-squash-merge \
  --enable-merge-commit=false \
  --enable-rebase-merge=false
