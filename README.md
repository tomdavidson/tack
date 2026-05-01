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
scripts/...                                       via link/copy/render/
                                                  concat/merge>
```

- `tack.sh` lives in **the tack repo**.
- The tack repo is typically vendored into the consumer as a **git submodule**
  at a stable path (e.g. `vendor/tack` or `.tack`).
- The consumer's `tackrc.yml` (optional) is deep-merged on top of the tack
  repo's `tackrc-defaults.yml`. The merged result is the single runtime
  controller (which packages to apply, per-package overrides, metadata) and
  the default tera context for templated files.
- Packages are directories under `$TACK_ROOT`. Behavior per file is decided
  by filename markers (`*.tera.*`, `*.copy.*`, `*.concat.*`, `*.merge.*`)
  and, for everything else, by `mode` rules in the package's `tack.yml`
  (or in the consumer's `overrides.<pkg>.mode`). Default for unmarked
  files is symlink via `lnko`.

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
overrides:
  configs/experimental:
    exclude: ["**"]   # opt this whole package out
vars: {}
YAML

# 4. Commit.
git add .gitmodules vendor/tack tackrc.yml
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
cd vendor/tack
git fetch origin
git checkout main           # or a tag, e.g. v0.1.0
git pull origin main
cd ../..
git add vendor/tack
git commit -m "Bump tack to <short-sha>"
```

**Current pinned branch convention:** `main`. There are no semver tags yet;
the `main` branch is the rolling reference.

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
vendor/tack/tack.sh -- --weird-pkg-name   # end-of-options sentinel
vendor/tack/tack.sh --version             # tack <git-describe> (<branch>)
vendor/tack/tack.sh --help                # full usage
```

### CLI options

| Option              | Description                                                             |
| ------------------- | ----------------------------------------------------------------------- |
| `--dry-run`         | Print actions without executing                                         |
| `--target DIR`      | Target directory (default: `$PWD`)                                      |
| `--`                | End of options; remaining args are package paths                        |
| `-V`, `--version`   | Print version (git describe + branch when available, else fallback)     |
| `-h`, `--help`      | Show built-in usage                                                     |
| `<package-path>...` | Positional package paths relative to `$TACK_ROOT` (e.g. `configs/rust`) |

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

| Key                     | Type                               | Purpose                                                                                                                                                                                                                                                                                                                                                     |
| ----------------------- | ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `link.unfold`           | list of dirs (package-relative)    | Directories `mkdir -p`'d in the target before linking. Used to break a single submodule symlink into per-file links.                                                                                                                                                                                                                                        |
| `mode`                  | ordered list of single-key entries | Each entry is `{copy: <glob-or-list>}` or `{link: <glob-or-list>}`. First match wins. See §7.                                                                                                                                                                                                                                                               |
| `files.<src>.vars_from` | string                             | Override tera context for this source file. See resolution rules below.                                                                                                                                                                                                                                                                                     |
| `files.<src>.post`      | string                             | Post-render command; word-split on whitespace and run with the destination path appended.                                                                                                                                                                                                                                                                   |
| `files.<src>.target`    | path (target-relative)             | Override target for any file in the package (render, copy, concat, merge, and unmarked link/copy). Path is consumer-target-relative, bypassing any `path_prefix`. For unmarked files, setting this also forces `copy` mode (link mode can't redirect a single file inside a directory link). Defaults to `strip_marker(basename)` in the same relative dir. |
| `files.<src>.overwrite` | boolean (default `true`)           | When `false`, skip the file if its target already exists. Applies to every mode: render, copy, concat, merge, and unmarked link/copy. For unmarked files in link mode, `overwrite: false` forces copy mode (lnko operates per-package, not per-file). First run still creates the target; subsequent runs leave consumer edits alone.                       |
| `files.<src>.enforced`  | list (optional, advisory)          | Recorded for tooling; not interpreted by `tack.sh` directly.                                                                                                                                                                                                                                                                                                |

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
   - Implicit fallback: `link` (via `lnko`).

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

Consumer repo `myproj` with `vendor/tack` as a submodule.

```
myproj/
  vendor/tack/                    (submodule)
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
- **`yq` errors complaining about syntax** — you almost certainly have the
  Python `yq` installed, not Mike Farah's Go `yq`. Replace it.
- **Submodule directory empty after clone** — run
  `git submodule update --init --recursive`.

## 11. Shell discipline (for contributors)

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
