# gh-settings

Merge org-enforced + default GitHub settings with per-repo overrides, then
`plan` or `apply` via OpenTofu.

## Model

Three layers, merged in this order:

1. `config/defaults.yml` — org baseline (bundled with this action).
2. `.github/repo-settings.yml` — per-repo overrides (in the calling repo).
3. `config/enforced.yml` — org-wide non-overrideable policy (bundled).

```
stripped_local = repo_settings - enforced_keys
merged         = deep_merge(defaults, stripped_local)
final          = deep_merge(merged, enforced)
```

Enforced keys present in a repo override are **stripped** before merging and
surfaced as a warning + PR-comment notice. They are then reapplied last, so
policy cannot be weakened by a project repo.

## Distribution model

- **Central `github-management` repo** owns `enforced.yml`, `defaults.yml`,
  the merge script, and the OpenTofu module. It publishes this action under
  a tag (e.g. `@v1`).
- **Project repos** call the published action from a small workflow. They
  provide only their `.github/repo-settings.yml` and the trigger.
- **State** is stored per-repo in an OCI registry (GHCR) via ORAS. Each repo
  gets its own artifact tag: `ghcr.io/<org>/repo-state/<repo>:latest`.

## Usage (project repo)

```yaml
# .github/workflows/github-settings.yml
name: GitHub Settings

on:
  push:
    branches: [main]
    paths: [".github/repo-settings.yml"]
  pull_request:
    paths: [".github/repo-settings.yml"]

jobs:
  settings:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: your-org/github-management/.github/actions/gh-settings@v1
        with:
          mode: ${{ github.event_name == 'push' && 'apply' || 'plan' }}
          github-token: ${{ secrets.GH_SETTINGS_TOKEN }}
          oras-registry: ghcr.io/your-org/repo-state
```

## Usage (local iteration in astro-bay)

While developing the action inside this repo, call it with a local path:

```yaml
- uses: ./.github/actions/gh-settings
  with:
    mode: plan
    github-token: ${{ secrets.GH_SETTINGS_TOKEN }}
```

## Files

- `action.yml` — composite action definition.
- `merge.js` — builds `blueprint.auto.tfvars.json` from the three layers.
- `comment.js` — upserts a PR comment with the plan output.
- `config/enforced.yml` — example enforced policy (replace with yours).
- `config/defaults.yml` — example defaults (replace with yours).
- `tofu/` — OpenTofu module that consumes the blueprint.
- `package.json` — declares `js-yaml` as the one runtime dep for the merge
  script. `actions/github-script@v7` runs the script in a Node context that
  already has `@actions/*` and Octokit available; `js-yaml` is the only
  thing we need to install explicitly at action time.

## Installing the js-yaml dep at action time

`actions/github-script` does not auto-install arbitrary npm deps. For now
the merge script uses `js-yaml` which is already present in the runner's
`actions/github-script` bundle. If that changes, add a step that runs
`npm install --prefix "${{ github.action_path }}" --no-audit --no-fund`
before the merge step.
