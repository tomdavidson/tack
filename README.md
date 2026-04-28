# tack

`tack` is dotfiles for your git repo: a small shell tool that materializes a curated kit of tooling, configs, and scripts into any project that vendors it.

It is intentionally infrequently used: you set up a consumer repo once, run
`tack` to materialize the configuration, and only re-run it when packages or
`tackrc.yml` change. This README is verbose on purpose so the next person (you,
in six months) can re-derive how it works without reading `tack.sh`.

## 1. Mental model

```
tack repo (this repo, often a submodule)        consumer repo
--------------------------------------          -------------------
tack.sh                                          tackrc.yml (optional)
tackrc-defaults.yml      ---- merge ---->        ...your project...
configs/<pkg>/...                                <files appear here
scripts/...                                       via link/render/copy>
```

- `tack.sh` lives in **the tack repo**.
- The tack repo is typically vendored into the consumer as a **git submodule** at
  a stable path (e.g. `vendor/tack` or `.tack`).
- The consumer's `tackrc.yml` (optional) is deep-merged on top of the tack repo's
  `tackrc-defaults.yml`. The merged result is both the runtime controller
  (which packages to apply, exclusions, metadata) and the default tera context
  for templated files.
- Packages are directories. The shape of each package's files (filename markers,
  `tack-manifest.yml`) determines what `tack` does with them.

## 2. Setting up tack as a git submodule in a consumer repo

From the **consumer** repo root:

```bash
# 1. Add the tack repo as a submodule. Pin to a stable path.
git submodule add https://github.com/tomdavidson/tack vendor/tack

# 2. Initialize and fetch.
git submodule update --init --recursive

# 3. (Optional) create a consumer-side tackrc.yml to override defaults.
cat > tackrc.yml <<'YAML'
pkgs:
  - configs/*
pkgs_exclude: []
pkgs_metadata: {}
vars: {}
YAML

# 4. Commit.
git add .gitmodules vendor/tack tackrc.yml
git commit -m "Vendor tack and add tackrc"
```

### Cloning a consumer repo that already uses tack

```bash
git clone --recurse-submodules sumer-url>
# or, after a plain clone:
git submodule update --init --recursive
```

### Updating the pinned tack version

The submodule pins a specific commit. To advance:

```bash
cd vendor/tack
git fetch origin
git checkout main           # or a tag, e.g. v0.1.0
git pull origin main
cd ../..
git add vendor/tack
git commit -m "Bump tack to <short-sha>"
```

**Current pinned branch convention:** `main`. There are no semver tags yet; the
`main` branch is the rolling reference.

## 3. Dependencies

Install on PATH before running tack:

- `bash` (4+; `tack.sh` uses `BASH_LINENO` and `${BASH_COMMAND}`)
- [`lnko`](https://github.com/tomdavidson/lnko) — symlink helper
- `tera` (Rust) — install with `cargo install tera-cli`
- `yq` (Go yq by Mike Farah) — https://github.com/mikefarah/yq, **not** the
  Python yq
- Standard POSIX userland: `awk`, `sed`, `find`, `mktemp`, `cp`, `mv`, `cat`,
  `grep`, `tr`, `dirname`, `basename`, `printf`

`tack.sh` checks for `lnko`, `tera`, and `yq` at startup and dies with an
actionable message if any are missing.

## 4. Running tack

From the **consumer** repo root:

```bash
vendor/tack/tack.sh                       # apply pkgs from merged tackrc
vendor/tack/tack.sh --dry-run             # print actions, change nothing
vendor/tack/tack.sh --target some/dir     # apply into a different target
vendor/tack/tack.sh configs/rust scripts  # apply specific packages, ignoring tackrc pkgs
vendor/tack/tack.sh --help                # full usage
```

**Selection precedence:**

1. CLI args, if any, override `pkgs` and `pkgs_exclude` entirely.
2. Otherwise: resolved `pkgs` minus resolved `pkgs_exclude` from the merged
   tackrc.

If neither produces packages, tack exits with `no packages selected: pass
packages on CLI or set pkgs in tackrc.yml`.

## 5. Control file: `tackrc-defaults.yml` and `tackrc.yml`

The **defaults** file (`<tack>/tackrc-defaults.yml`) is required. The
**consumer** file (`sumer>/tackrc.yml`) is optional and is deep-merged on
top. Top-level keys tack reads:

| Key                         | Type                      | Purpose                                                                                                  |
| --------------------------- | ------------------------- | -------------------------------------------------------------------------------------------------------- |
| `pkgs`                      | list of path-globs        | Packages to apply, relative to tack repo root. Globs like `configs/*` are expanded against `$TACK_ROOT`. |
| `pkgs_exclude`              | list of path-globs        | Subtracted from resolved `pkgs`.                                                                         |
| `pkgs_metadata`             | map keyed by package path | Per-package data exposed to tera as `pkg` during render.                                                 |
| `vars` (and any other keys) | arbitrary                 | Available in tera templates by their dotted path.                                                        |

**Glob rules:**

- A literal entry (no `*`, `?`, `yaml
  pkgs:
  - configs/*
  - scripts
    pkgs_exclude:
  - configs/experimental-*
    pkgs_metadata:
    configs/rust:
    toolchains: [stable, nightly]
    vars:
    user:
    name: Tom
    email: tom@example.com

````
## 6. Per-package context: `tack-manifest.yml`

A package may contain a `tack-manifest.yml` declaring what cannot be derived
from filenames:

```yaml
link:
  unfold:
    - .config/nvim       # ensure these dirs exist in target before linking
files:
  some.tera.yml:
    vars_from: '@consumer/tackrc.yml'   # override default tera context for this file
    post: 'prettier --write'            # post-render hook
  fragment.concat.toml:
    target: pyproject.toml              # required for *.concat.* and *.merge.*
  patch.merge.json:
    target: package.json
````

**`vars_from` resolution shorthands:**

- `tackrc.yml` or `@consumer/tackrc.yml` — the merged tackrc
- `/abs/path` — absolute
- `~/relative` — relative to `$HOME`
- `@tack/...` — relative to `$TACK_ROOT`
- `@consumer/...` — relative to `$TACK_CONSUMER_ROOT`
- anything else — relative to `$TACK_CONSUMER_ROOT`

## 7. File dispatch by filename marker

For each file in a selected package, `tack` chooses a behavior based on the
filename:

| Pattern                        | Behavior                                                                        |
| ------------------------------ | ------------------------------------------------------------------------------- |
| `*.tera.*`                     | Render with `tera`, strip the `.tera` marker for the target name                |
| `*.copy.*`                     | Copy verbatim, strip the `.copy` marker                                         |
| `*.concat.*`                   | Append to manifest-declared `target`; signature-dedup so re-runs are idempotent |
| `*.merge.json`                 | Deep-merge into manifest-declared `target` via `yq`                             |
| `*.merge.yml` / `*.merge.yaml` | Same, YAML                                                                      |
| `*.merge.toml`                 | **Refused.** Use `*.concat.toml` (see ADR-0002)                                 |
| `tack.yml`                     | Skipped (control files)                                                         |
| anything else                  | Symlinked into the target via `lnko`                                            |

**Idempotency note:** linking and merging are safe to re-run. Concat is
deduplicated by a two-line signature, so re-running won't double-append the
same fragment.

## 8. End-to-end example

Consumer repo `myproj` with `vendor/tack` as a submodule.

```
myproj/
  vendor/tack/                    (submodule)
    tack.sh
    tackrc-defaults.yml
    configs/
      git/
        .gitconfig.tera           -> rendered to ~/.gitconfig
        tack-manifest.yml
      rust/
        .cargo/
          config.toml.copy.toml     -> copied to .cargo/config.toml
        rust-toolchain.toml         -> symlinked
  tackrc.yml                      (consumer override)
```

`vendor/tack/tackrc-defaults.yml`:

```yaml
pkgs:
  - configs/git
```

`myproj/tackrc.yml`:

```yaml
pkgs:
  - configs/git
  - configs/rust
vars:
  user:
    name: Tom
    email: tom@example.com
```

Run:

```bash
cd myproj
vendor/tack/tack.sh --target $HOME
```

Result: `~/.gitconfig` rendered, `~/.cargo/config.toml` copied, and
`~/rust-toolchain.toml` symlinked back to the package.

## 9. Testing

```bash
bats tests/                # full suite
shellcheck tack.sh         # static lint
```

The bats suite shapes isolated `ALT_ROOT` / `CONSUMER` trees per test, so
running the suite does not touch your real configs.

## 10. Troubleshooting

- **`[tack] aborted: exit=N line=L cmd=...`** — the diagnostic EXIT trap fired.
  `cmd` is the last command before the abort. Run with `bash -x ./tack.sh ...`
  for full trace.
- **`pkg literal does not resolve to a directory: <path>`** — the literal entry
  in `pkgs` does not exist under `$TACK_ROOT`. Either fix the path or convert
  it to a glob (silent on no-match).
- **`no packages selected`** — both CLI args and the resolved `pkgs` list are
  empty. Pass packages on the CLI or set `pkgs` in tackrc.
- **`yq` errors complaining about syntax** — you almost certainly have the
  Python `yq` installed, not Mike Farah's Go `yq`. Replace it.
- **Submodule directory empty after clone** — run
  `git submodule update --init --recursive`.

## 11. Shell discipline (for contributors)

`tack.sh` runs under `set -euo pipefail`. The header in `tack.sh` documents the
rules; the short version:

1. Never end a function, subshell, or while/for body on a bare
   `cmd1 && cmd2` standalone statement.
2. Functions called inside `var=$(fn)` must return 0 except on caller-handled
   conditions; signal errors via stdout sentinels or the side-file mechanism
   already in place (`$TACK_ERR_FILE`), not via `die`.
3. Prefer `if cmd; then ...; fi` over `cmd && ...` at statement scope.

A diagnostic EXIT trap reports any silent `set -e` abort with status, line, and
command. If you add a new `trap ... EXIT`, route cleanups through
`tack_cleanup_add` so you don't clobber the diagnostic trap.
