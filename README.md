# tack

`tack` is dotfiles for your git repo: a small shell tool that materializes a curated kit of tooling, configs, and scripts into any project that vendors it.

It is intentionally infrequently used: you set up a consumer repo once, run
`tack` to materialize the configuration, and only re-run it when packages or
`tackrc.yml` change. This README is verbose on purpose so the next person (you,
in six months) can re-derive how it works without reading `tack.sh`.

## Why a submodule, not a generator

Generator-style tools (Yeoman, cookiecutter, `create-*` CLIs, repo templates)
optimize for a one-shot scaffold: they emit files, then disconnect. The
upstream contribution loop dies at that point — fixes made in a consumer repo
cannot flow back, drift accumulates, and every consumer eventually owns a
slightly different fork of the same baseline.

`tack` is built around the opposite priority: **keep the upstream connection
alive**. Distributing the kit as a vendored git submodule means a consumer can
(a) pin to a specific tack commit for reproducibility, (b) edit `.tack`
in place to fix or improve a config, and (c) push that change back upstream as
a normal PR from inside the consumer repo. Re-running `tack.sh` in the
consumer is then just `git submodule update` plus a re-apply, with the same
deterministic dispatch rules. Other distribution shapes considered (npm/cargo
package, curl-piped installer, generator template, OCI artifact) all break
that round-trip in some way, so the submodule is load-bearing, not
incidental.

## 1. Mental model

```
tack repo (this repo, a submodule at .tack)     consumer repo
--------------------------------------          -------------------
tack.sh                                          tackrc.yml (optional)
tackrc-defaults.yml      ---- merge ---->        ...your project...
configs/<pkg>/...                                <files appear here
scripts/...                                       via link/copy/render/
                                                  concat/merge>
```

- `tack.sh` lives in **the tack repo**.
- The tack repo is vendored into the consumer as a **git submodule at
  `.tack`**. This path is fixed, not a suggestion: devenv modules and scripts
  shipped by tack reference `.tack/configs/...` directly (for example
  `imports = [ ./.tack/configs/drupal/drupal.nix ];`).
- The consumer's `tackrc.yml` (optional) is deep-merged on top of the tack
  repo's `tackrc-defaults.yml`. The merged result is the single runtime
  controller (which packages to apply, per-package overrides, metadata) and
  the default tera context for templated files.
- Packages are directories under `$TACK_ROOT`. Behavior per file is decided
  by filename markers (`*.tera.*`, `*.copy.*`, `*.concat.*`, `*.merge.*`)
  and, for everything else, by `mode` rules in the package's `tack.yml`
  (or in the consumer's `overrides.<pkg>.mode`). Default for unmarked
  files is a per-file symlink (`ln -sfn`).

## 2. Setting up tack as a git submodule in a consumer repo

From the **consumer** repo root:

```bash
# 1. Add the tack repo as a submodule at .tack (this path is required).
git submodule add https://github.com/tomdavidson/tack .tack

# 2. Initialize and fetch.
git submodule update --init --recursive

# 3. (Optional) create a consumer-side tackrc.yml to override defaults.
cat > tackrc.yml <<'YAML'
pkgs:
  - configs/*
overrides:
  configs/experimental:
    exclude: ["**"]   # opt this whole package out
vars: {}
YAML

# 4. Commit.
git add .gitmodules .tack tackrc.yml
git commit -m "Vendor tack and add tackrc"
```

### Cloning a consumer repo that already uses tack

```bash
git clone --recurse-submodules <consumer-url>
# or, after a plain clone:
git submodule update --init --recursive
```

### Updating the pinned tack version

The submodule pins a specific commit. To advance:

```bash
cd .tack
git fetch origin
git checkout main           # or a tag, e.g. v0.1.0
git pull origin main
cd ..
git add .tack
git commit -m "Bump tack to <short-sha>"
```

**Current pinned branch convention:** `main`. There are no semver tags yet;
the `main` branch is the rolling reference.

## 3. Dependencies

Install on PATH before running tack:

- `bash` (4+; `tack.sh` uses `BASH_LINENO` and `${BASH_COMMAND}`)
- [`proto`](https://moonrepo.dev/docs/proto/install) — version manager.
  `curl -fsSL https://moonrepo.dev/install/proto.sh | bash`, then open a new
  shell (or `export PATH="${PROTO_HOME:-$HOME/.proto}/bin:$PATH"`).
- Standard POSIX userland: `awk`, `sed`, `find`, `mktemp`, `cp`, `mv`, `cat`,
  `grep`, `tr`, `dirname`, `basename`, `printf`

You do not install `yq` or `tera` by hand. On every run `tack.sh` has proto
install the versions pinned in `configs/common/.prototools` (a no-op once
they are present) and calls those binaries directly, so a stray Python `yq`
on your PATH is never used. `tack.sh` dies with install directions if
`proto` is missing.

proto 0.63+ only honors `[plugins]`, `[settings]`, and third-party tool pins
from trusted config files. `tack.sh` runs `proto trust` on
`.tack/configs/common/.prototools` for you. After the first apply, trust the
copy linked into your repo root too, so `moon`, `dprint`, and the other pinned
tools resolve: `proto trust .prototools`. (`CI=1` is auto-trusted.)

Escape hatch: `TACK_SKIP_BOOTSTRAP=1 .tack/tack.sh` skips proto and uses
whatever `yq`/`tera` are on PATH. The bats suite effectively runs this way
because fixture roots carry no pinfile.

## 4. Running tack

From the **consumer** repo root:

```bash
.tack/tack.sh                       # apply pkgs from merged tackrc
.tack/tack.sh --dry-run             # print actions, change nothing
.tack/tack.sh --target some/dir     # apply into a different target
.tack/tack.sh configs/rust scripts  # apply specific packages, ignoring tackrc pkgs
.tack/tack.sh -- --weird-pkg-name   # end-of-options sentinel
.tack/tack.sh --version             # tack <git-describe> (<branch>)
.tack/tack.sh --help                # full usage
```

### CLI options

| Option              | Description                                                                           |
| ------------------- | ------------------------------------------------------------------------------------- |
| `--dry-run`         | Print actions without executing                                                       |
| `--overwrite`       | Ignore `files.<src>.overwrite: false`; re-seed those files, discarding consumer edits |
| `--target DIR`      | Target directory (default: `$PWD`)                                                    |
| `--`                | End of options; remaining args are package paths                                      |
| `-V`, `--version`   | Print version (git describe + branch when available, else fallback)                   |
| `-h`, `--help`      | Show built-in usage                                                                   |
| `<package-path>...` | Positional package paths relative to `$TACK_ROOT` (e.g. `configs/rust`)               |

### Environment variables

| Var                  | Default             | Purpose                                                  |
| -------------------- | ------------------- | -------------------------------------------------------- |
| `TACK_ROOT`          | dir of `tack.sh`    | Path to the tack repo                                    |
| `TACK_CONSUMER_ROOT` | value of `--target` | Path to the consumer repo (used for `vars_from` lookups) |

### Selection precedence

1. If `<package-path>` args are given, they override `pkgs` and `overrides`
   entirely. CLI-supplied packages bypass per-package `exclude` and `mode`
   overrides.
2. Otherwise: resolved `pkgs` minus any package whose
   `overrides.<pkg>.exclude` contains the literal `"**"` (whole-package
   opt-out). File-level patterns in `exclude` filter individual files
   inside the package; they do not remove the package.
3. Empty selection is a hard error: `no packages selected: pass packages on
   CLI or set pkgs in tackrc.yml`.

### Exit codes

| Code | Meaning                                   |
| ---- | ----------------------------------------- |
| 0    | success                                   |
| 1    | error (see `[tack] error: ...` on stderr) |
| 130  | interrupted (SIGINT)                      |
| 143  | terminated (SIGTERM)                      |

Any non-zero exit also produces a diagnostic line of the form
`[tack] aborted: exit=N line=L cmd=...` on stderr from the EXIT trap.

## 5. Control file: `tackrc-defaults.yml` and `tackrc.yml`

The **defaults** file (`<tack>/tackrc-defaults.yml`) is required. The
**consumer** file (`<consumer>/tackrc.yml`) is optional and is deep-merged
on top via `yq ea '. as $i ireduce ({}; . * $i)'`.

Top-level keys tack reads:

| Key             | Type                      | Purpose                                                                                                                           |
| --------------- | ------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `pkgs`          | list of path-globs        | Packages to apply, relative to `$TACK_ROOT`. Globs like `configs/*` are expanded against `$TACK_ROOT`.                            |
| `overrides`     | map keyed by package path | Per-package settings. See sub-keys below.                                                                                         |
| `pkgs_metadata` | map keyed by package path | Per-package data exposed to tera as `pkg` during render of files in that package.                                                 |
| `vars`          | arbitrary                 | Available in tera templates by their dotted path (e.g. `vars.user.email`).                                                        |
| `moon`          | map                       | Read by moon-related templates. Common keys: `toolchains` (list), `workspace_base_source` (`local`\|`url`), `workspace_base_ref`. |
| (other keys)    | arbitrary                 | Anything else is available to tera by dotted path.                                                                                |

### `overrides.<pkg>` sub-keys

| Sub-key   | Type                       | Purpose                                                                                                                                     |
| --------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `exclude` | list of shell-glob strings | Filter files inside the package. The literal `"**"` is special: it removes the **whole package** from selection.                            |
| `mode`    | ordered list of mode rules | Same shape as `mode` in a package's `tack.yml` (see §7). Consumer rules are evaluated **before** the package's own rules; first match wins. |

Glob notes:

- Recursive `**` and dotfile matching are enabled (`globstar`, `dotglob`,
  `nullglob`, `extglob`).
- A literal `pkgs` entry (no `*`, `?`, `[`) that does not resolve to a
  directory under `$TACK_ROOT` is a hard error
  (`pkg literal does not resolve to a directory`).
- Glob entries that match nothing are silently skipped.
- `exclude` patterns are matched against package-relative paths.

### Example consumer `tackrc.yml`

```yaml
pkgs:
  - configs/*
  - scripts

overrides:
  configs/rust:
    exclude: ["**"] # whole-package opt-out
  configs/common:
    exclude:
      - .prototools # file-level filter
  configs/github:
    mode:
      - copy: ".github/**" # consumer override; evaluated before package mode
      - link: "**"

pkgs_metadata:
  configs/rust:
    toolchains: [stable, nightly]

vars:
  user:
    name: Tom
    email: tom@example.com
```

## 6. Per-package context: `tack.yml`

A package may contain a `tack.yml` declaring parameters that cannot be
derived from filenames. **All keys are optional.** If `tack.yml` is omitted,
every target is derived by stripping the dispatch marker from the source
basename and writing into the same relative path under `--target`.

```yaml
link:
  unfold:
    - .config/nvim # ensure these dirs exist in target before linking
    - .moon/partials

mode:
  - copy: ".github/**" # ordered rules for non-marker files; first match wins
  - copy: [".moon/**/*.yml", "oxlintrc.json"]
  - link: "**" # default fallback within the package

files:
  greeting.tera.yml:
    vars_from: tackrc.yml # override default tera context for this file
    post: "prettier --write" # post-render hook (word-split; trusted source)
  fragment.concat.toml:
    target: pyproject.toml # optional: override default concat target
  patch.merge.json:
    target: package.json # optional: override default merge target
```

### `tack.yml` schema

| Key                     | Type                               | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ----------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `link.unfold`           | list of dirs (package-relative)    | Directories `mkdir -p`'d in the target before linking. Used to break a single submodule symlink into per-file links.                                                                                                                                                                                                                                                                                                                                                                                                 |
| `ignore`                | list of shell-glob strings         | Package-declared file filters (bash `case`-glob; `*` crosses `/`). Matching files are skipped during apply for every consumer. Unioned with `overrides.<pkg>.exclude`. Applies even under CLI selection (it is the package's own contract). See §6.1.                                                                                                                                                                                                                                                                |
| `mode`                  | ordered list of single-key entries | Each entry is `{copy: <glob-or-list>}` or `{link: <glob-or-list>}`. First match wins. See §7.                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `files.<src>.vars_from` | string                             | Override tera context for this source file. See resolution rules below.                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `files.<src>.post`      | string                             | Post-render command; word-split on whitespace and run with the destination path appended.                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `files.<src>.target`    | path (target-relative)             | Override target for any file in the package (render, copy, concat, merge, and unmarked link/copy). Path is consumer-target-relative, bypassing any `path_prefix`. Mode rules apply as usual: in link mode the symlink is placed at the overridden path (this is how the shared root `moon.yml` is linked out of `.moon/`; see ADR-0009). Defaults to `strip_marker(basename)` in the same relative dir.                                                                                                              |
| `files.<src>.overwrite` | boolean (default `true`)           | When `false`, skip the file if its target already exists. Applies to every mode: render, copy, concat, merge, and unmarked link/copy. For unmarked files in link mode, `overwrite: false` forces copy mode (a symlink cannot hold consumer edits, so there is nothing to preserve). First run still creates the target; subsequent runs leave consumer edits alone. A symlink at the target is never treated as seeded (it holds no consumer edits) and is replaced by a real file. `--overwrite` disables the skip. |
| `files.<src>.enforced`  | list (optional, advisory)          | Recorded for tooling; not interpreted by `tack.sh` directly.                                                                                                                                                                                                                                                                                                                                                                                                                                                         |

### 6.1 Package-level `ignore`

Use `ignore` for files that live in the package directory but should never
be tacked into a consumer (local-only helpers, drafts, examples, fixtures).
It is the package's own contract: every consumer inherits it without
repeating themselves in `overrides.<pkg>.exclude`.

```yaml
path_prefix: .moon

ignore:
  - "scripts/debug.sh"
  - "*.local.*"
  - "templates/example/*"

files:
  moon.yml:
    target: moon.yml # consumer-root-relative; escapes path_prefix
```

Semantics:

- Same shell-glob syntax as `overrides.<pkg>.exclude` in `tackrc.yml`.
  Patterns are matched with bash `case` against the package-relative
  path, so `*` already crosses `/` (e.g. `*.local.*` matches
  `src/debug/a.local.sh`). `**` has no special meaning in this
  context; treat it as equivalent to `*`. Use `?` for one character
  and `[...]` for a class.
- Unioned with consumer `overrides.<pkg>.exclude`. Both apply.
- Always honored, including when the package is CLI-selected.
  Consumer-side `exclude` is bypassed under CLI selection (existing
  behavior); package-declared `ignore` is not.
- Applies uniformly to every dispatch path: render, copy, concat, merge,
  and unmarked link/copy.
- `ignore: ["**"]` (or `["*"]`) short-circuits the entire package and
  is consistent with the consumer-side whole-package opt-out, but rarely
  useful at the package level (just don't ship the package).

### 6.2 Nested opt-in packages

A package may carry optional sub-packages in subdirectories. The parent
lists them in `ignore` so its own walk skips them; a consumer enables one
by naming it in `pkgs`. Nothing under `configs/*` is selected by the glob
below the first level, so nested packages are always opt-in.

| Package                          | Parent           | Delivers                                            |
| -------------------------------- | ---------------- | --------------------------------------------------- |
| `configs/drupal/variants/dlg-ms` | `configs/drupal` | LocalGov DLG-MS extras (see §9)                     |
| `configs/common/lfs`             | `configs/common` | Git LFS rules appended to the root `.gitattributes` |

#### `configs/common/lfs`

The universal `.gitattributes` marks CAD, 3D, and design formats as
`binary` or `text -diff`, but never sets `filter=lfs`: that is a storage
policy, not a content fact. It requires `git-lfs` on every machine that
touches the repo, and LFS objects count against the hosting account's
quota. Repos that hold large assets opt in:

```yaml
pkgs:
  - configs/common # copies .gitattributes
  - configs/common/lfs # appends the LFS block (order matters)
```

Then once per clone: `git lfs install`. The fragment covers `.blend`, `.dwg`,
`.skp`, `.3dm`, `.stl`, `.3mf`, `.glb`, `.fbx`, `.pdf`, and raster/render
formats (`.exr`, `.hdr`, `.psd`, `.kra`, `.xcf`, `.tif`). Re-running tack
re-copies `.gitattributes` and re-appends the block; the result is stable.

To narrow or extend LFS for one directory, add a nested `.gitattributes`
there; it overrides the root for that path. Example: keep small PNGs plain
at the root but LFS renders under `studies/`:

```gitattributes
# studies/.gitattributes
*.png  filter=lfs diff=lfs merge=lfs -text
```

If files matching an LFS rule were committed before the rule existed (or
on a machine without `git-lfs`), later checkouts fail with
`Encountered N files that should have been pointers, but weren't`. Fix with
`git lfs migrate import --no-rewrite <paths>`.

### `vars_from` resolution shorthands

| Form                                   | Resolves to                       |
| -------------------------------------- | --------------------------------- |
| `tackrc.yml` or `@consumer/tackrc.yml` | the merged tackrc                 |
| `/abs/path`                            | absolute                          |
| `~/relative`                           | relative to `$HOME`               |
| `@tack/...`                            | relative to `$TACK_ROOT`          |
| `@consumer/...`                        | relative to `$TACK_CONSUMER_ROOT` |
| anything else                          | relative to `$TACK_CONSUMER_ROOT` |

## 7. File dispatch

For each file in a selected package, `tack` chooses behavior in this order:

1. **Filename content marker** (always wins over `mode` rules):

   | Pattern                        | Behavior                                                                                                                      |
   | ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
   | `*.tera.*`                     | Render via `tera`; target = `strip_marker(src)` in same relative dir                                                          |
   | `*.copy.*`                     | Copy verbatim; target = `strip_marker(src)`. Also acts as a fallback signal that resolves the file's mode to `copy`.          |
   | `*.concat.*`                   | Append to target (default = `strip_marker(src)`; override via `tack.yml`). Two-line signature dedup makes re-runs idempotent. |
   | `*.merge.json`                 | Deep-merge into target via `yq` (default target = `strip_marker(src)`). Missing target is created.                            |
   | `*.merge.yml` / `*.merge.yaml` | Same as above for YAML.                                                                                                       |
   | `*.merge.toml`                 | **Refused.** Use `*.concat.toml` (see ADR-0002 / ADR-0004).                                                                   |
   | `tack.yml`                     | Skipped (control file).                                                                                                       |

2. **`mode` rules** for everything else, in this order, first match wins:
   - Consumer `overrides.<pkg>.mode` (skipped when packages come from CLI args).
   - Package `tack.yml` `mode`.
   - Implicit fallback: `link` (a relative per-file symlink via `ln -sfn`).

   Each rule is `{ copy: <glob-or-list> }` or `{ link: <glob-or-list> }`,
   matched against the package-relative path.

**Idempotency:** linking and merging are safe to re-run. Concat is
deduplicated by a two-line signature so re-running won't double-append the
same fragment. Merge with a missing destination synthesizes an empty seed
(`{}` for JSON/YAML) and is therefore a create-or-update operation.

**Per-render tera context:** tack computes the context as the merged tackrc
with `.pkg = pkgs_metadata[<this pkg path>] // {}` bound for the duration
of that package's renders. `files.<src>.vars_from` replaces this entirely
for a specific file.

## 8. End-to-end example

Consumer repo `myproj` with `.tack` as a submodule.

```
myproj/
  .tack/                          (submodule)
    tack.sh
    tackrc-defaults.yml
    configs/
      git/
        .gitconfig.tera           -> rendered to ~/.gitconfig
        tack.yml
      rust/
        .cargo/
          config.toml.copy.toml   -> copied to .cargo/config.toml
        rust-toolchain.toml       -> symlinked
  tackrc.yml                      (consumer override)
```

`.tack/tackrc-defaults.yml`:

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
.tack/tack.sh --target $HOME
```

Result: `~/.gitconfig` rendered, `~/.cargo/config.toml` copied, and
`~/rust-toolchain.toml` symlinked back to the package.

## 9. Drupal stacks

The `configs/drupal` package is a base for any Drupal application. Variants
under `configs/drupal/variants/` layer a database and object store on top.
The `.tack` submodule path is required: the nix modules and task scripts
reference `.tack/configs/drupal/...`.

| Piece                                            | What it provides                                                                                                                               |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `configs/drupal` (tack package)                  | phpcs, phpstan, phpunit configs; Moon task files; `drupal-module` Moon template; Fly.io cron and db scaffolding; shell scripts                 |
| `configs/drupal/drupal.nix` (devenv)             | PHP 8.3, FrankenPHP, composer, `app:composer`, `drupal:deploy`, `drupal:reset`. **No database and no S3.** Bring your own (PostgreSQL, SQLite) |
| `configs/drupal/variants/dlg-ms` (package)       | LocalGov DLG Microsites extras: Caddyfile, post-install hook, Moon task file, `dlg-ms` Moon template                                           |
| `configs/drupal/variants/dlg-ms.nix`             | Imports `drupal.nix`; adds MariaDB 11.4, RustFS (S3), `db:user`, `s3:buckets`, `drupal:setup`, DB and S3 env vars, `urls`                      |
| `configs/drupal/variants/localgov-multisite.nix` | Compatibility shim that imports `dlg-ms.nix`. Update consumers to `dlg-ms.nix`                                                                 |

MariaDB and RustFS belong to `dlg-ms` only. Other Drupal apps import
`drupal.nix` and add their own database; not every app needs RustFS.

### Base Drupal (bring your own database)

```yaml
# tackrc.yml
pkgs:
  - configs/common
  - configs/devenv
  - configs/drupal
```

```nix
# devenv.nix
{ pkgs, lib, config, ... }:
{
  imports = [ ./.tack/configs/drupal/drupal.nix ];

  env.APP_ROOT = "${config.devenv.root}/apps/my-app";

  # Add your own database, e.g. PostgreSQL:
  services.postgres.enable = true;
}
```

### LocalGov DLG Microsites (`dlg-ms`)

```yaml
# tackrc.yml
pkgs:
  - configs/common
  - configs/devenv
  - configs/drupal
  - configs/drupal/variants/dlg-ms
vars:
  project:
    name: your-org/your-project
```

```nix
# devenv.nix
{ pkgs, lib, config, ... }:
{
  imports = [ ./.tack/configs/drupal/variants/dlg-ms.nix ];

  env.APP_ROOT  = "${config.devenv.root}/apps/hub";
  env.HASH_SALT = "your-project-specific-value";
}
```

```bash
.tack/tack.sh                         # deliver nix, tasks, templates, Caddyfile
moon generate dlg-ms -- --name hub    # scaffold apps/hub/
devenv up                             # MariaDB, RustFS, composer, FrankenPHP
devenv tasks run drupal:setup         # first-time install (+ demo content)
```

### Layout and `APP_ROOT`

`APP_ROOT` defaults to the repo root. Set it in `devenv.nix` when Drupal
lives in a subdirectory such as `apps/hub`. Scripts, drush, composer, and the
web server all resolve relative to it.

Each Drupal app owns its own `composer.json`, `composer.lock`, and `vendor/`;
there is no shared root manifest. `composer.json` is not delivered by tack.
`moon generate dlg-ms` creates it per app, with a `../../packages/drupal/*`
path repository (symlinked) for local modules. Running the generator again
with a different `--name` creates an independent app.

## 10. Python projects

`configs/python` is a tooling baseline, not an interpreter manager. Each
Moon project owns its Python version and environment; the pack supplies
uv, ruff, shared lint/format rules, and Moon tasks.

| Piece                                   | What it provides                                                                                                                                                                                 |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `configs/python/python.nix` (devenv)    | `pkgs.uv`, `UV_MANAGED_PYTHON=1`, and a sandboxed `uv` script via `bwrap-run`. Imported from `.tack`                                                                                             |
| `configs/python/ruff.toml`              | Shared lint rules, read through `.tack`. The repo root gets a seed-once stub (`extend = ".tack/configs/python/ruff.toml"`) for overrides; project `ruff.toml` files `extend = "../../ruff.toml"` |
| `configs/common/.prototools`            | Pins `ruff` for `ruff check` in the Moon `lint` task (dprint formats via its own Wasm build of ruff)                                                                                             |
| `configs/common/dprint.json`            | `@dprint/ruff` plugin with a `"ruff"` block (indent 4, import sorting); excludes `.venv`, caches, `uv.lock`                                                                                      |
| `configs/python/.moon/tasks/python.yml` | Delivered to `.moon/tasks/python.yml` (ADR-0010, like drupal): `lint`, `lint-fix`, `typecheck`, `test`, `verify` for projects tagged `python`                                                    |

```yaml
# tackrc.yml
pkgs:
  - configs/common
  - configs/devenv
  - configs/python
  - .moon
vars:
  devenv:
    imports:
      - ./.tack/configs/python/python.nix
```

`devenv.nix` is seeded once, so existing consumers add the import by hand:

```nix
imports = [ ./.tack/configs/python/python.nix ];
```

Do not add `uv` to `vars.bwrap.tools`; `python.nix` already defines that
script and a second definition is a module conflict.

### Interpreter versions

Nothing in tack pins Python. uv downloads a managed interpreter per
project from `.python-version` / `requires-python`, so a FreeCAD helper
on 3.11.x and a Home Assistant integration on 3.14 coexist in one repo.
Keep incompatible projects independent (own `pyproject.toml`, `uv.lock`,
`.venv`); do not force them into one uv workspace.

```bash
cd apps/my-tool
uv python pin 3.14          # writes .python-version
uv add --dev pytest basedpyright
uv sync
```

`UV_MANAGED_PYTHON=1` forbids falling back to a host Python. Inside the
sandbox, interpreters persist under the bwrap cache root
(`UV_PYTHON_INSTALL_DIR`), so `.venv` symlinks resolve on the host too.
Running a bare host `uv` outside the devenv shell uses uv's default
interpreter directory instead and will re-download; use the shell.

Scripts that run inside FreeCAD use FreeCAD's embedded interpreter; an
external interpreter must match FreeCAD's exact patch release to import
its modules.

### Lint, format, types, tests

- Format: `dprint fmt` (root task) formats `.py`/`.pyi` with the `@dprint/ruff`
  plugin. Settings live in `dprint.json` under `"ruff"` (indent 4, import
  sorting; line width and line endings inherit dprint's globals). The plugin
  does not read `ruff.toml`, which is lint-only.
- Lint: `moon run <project>:lint` runs `ruff check`; import sorting is
  rule `I`, applied by `lint-fix`.
- Types: `typecheck` runs `uv run --frozen basedpyright` (default
  `recommended` mode; set `[tool.basedpyright]` per project to relax).
- Tests: `test` runs `uv run --frozen pytest`.

Projects opt in with `tags: [python]` in `moon.yml`. Moon's
`unstable_python` toolchain is intentionally not enabled.

## 11. Testing

```bash
bats tests/                # full suite
shellcheck tack.sh         # static lint
```

The bats suite shapes isolated `ALT_ROOT` / `CONSUMER` trees per test, so
running the suite does not touch your real configs.

## 12. Troubleshooting

- **`[tack] aborted: exit=N line=L cmd=...`** — the diagnostic EXIT trap
  fired. `cmd` is the last command before the abort. Run with
  `bash -x ./tack.sh ...` for a full trace.
- **`pkg literal does not resolve to a directory: <path>`** — the literal
  entry in `pkgs` does not exist under `$TACK_ROOT`. Either fix the path
  or convert it to a glob (silent on no-match).
- **`no packages selected`** — both CLI args and the resolved `pkgs` list
  are empty (or every package was opted out via `overrides.<pkg>.exclude:
  ["**"]`). Pass packages on the CLI or adjust tackrc.
- **`*.merge.toml not supported`** — replace with `*.concat.toml` and set
  `files.<src>.target` if needed (see ADR-0002 / ADR-0004).
- **`vars_from not found`** — the resolved path does not exist. Check the
  shorthand prefix (`@tack/`, `@consumer/`, `~/`, absolute, or bare =
  `$TACK_CONSUMER_ROOT/...`).
- **`proto not found on PATH`** — install proto (see §3) and open a new
  shell, or `export PATH="${PROTO_HOME:-$HOME/.proto}/bin:$PATH"`.
- **`proto could not install yq` / `... tera`** — run
  `(cd .tack/configs/common && proto install yq && proto install tera)` to
  see proto's own error (one tool per `proto install`; a second positional
  is parsed as a version). On proto 0.63+ confirm `proto trust .tack/configs/common/.prototools`
  succeeded; untrusted configs make plugin-based tools silently unavailable.
- **`yq` errors complaining about syntax** — only possible with
  `TACK_SKIP_BOOTSTRAP=1`; you have the Python `yq` on PATH, not Mike
  Farah's Go `yq`. Unset the variable and let proto supply it.
- **Submodule directory empty after clone** — run
  `git submodule update --init --recursive`.
- **devenv import fails with `.tack/... No such file`** — the submodule must
  be checked out at exactly `.tack`. Move it with `git mv <old-path> .tack`.

## 13. Shell discipline (for contributors)

`tack.sh` runs under `set -euo pipefail`. The header in `tack.sh` documents
the rules; the short version:

1. Never end a function, subshell, or `while`/`for` body on a bare
   `cmd1 && cmd2` or `cmd1 || cmd2` standalone statement. Wrap in
   `if cmd1; then cmd2; fi` or terminate with `:` / `return 0`.
2. Functions called inside `var=$(fn)` must return 0 except on conditions
   the caller is prepared to distinguish; signal errors via stdout
   sentinels or a side file (e.g. `TACK_ERR_FILE`), not via `die`.
3. Conditional contexts (`if`, `while`, `||`, `&&` as the test of a
   compound) suppress `set -e`; standalone statements do not. When in
   doubt, wrap in `if`.

The diagnostic EXIT trap (`_tack_on_exit`) is the safety net and must not
be clobbered by inner functions; use `tack_cleanup_add` to register paths
for removal instead of registering a new EXIT trap.
