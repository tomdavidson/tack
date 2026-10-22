# `tack` Reference: `tackrc.yml`, `tack.yml`, Dispatch, and Troubleshooting

Complete reference for `tack`'s control files (`tackrc.yml` and `tack.yml`), file dispatch modes, CLI options, and contributor shell discipline.

---

## 1. CLI Options & Environment Variables

From the **consumer** repo root:

```bash
.tack/tack.sh                      # apply pkgs from merged tackrc
.tack/tack.sh --dry-run            # print actions, change nothing
.tack/tack.sh --overwrite          # re-seed overwrite:false files, discarding consumer edits
.tack/tack.sh --target some/dir    # apply into a different target
.tack/tack.sh configs/rust scripts # apply specific packages, ignoring tackrc pkgs
.tack/tack.sh -- --weird-pkg-name  # end-of-options sentinel
.tack/tack.sh --version            # tack <git-describe> (<branch>)
.tack/tack.sh --help               # full usage
```

| Option              | Description                                                                           |
| ------------------- | ------------------------------------------------------------------------------------- |
| `--dry-run`         | Print actions without executing                                                       |
| `--overwrite`       | Ignore `files.<src>.overwrite: false`; re-seed those files, discarding consumer edits |
| `--target DIR`      | Target directory (default: `$PWD`)                                                    |
| `--`                | End of options; remaining args are package paths                                      |
| `-V`, `--version`   | Print version (git describe + branch when available, else fallback)                   |
| `-h`, `--help`      | Show built-in usage                                                                   |
| `<package-path>...` | Positional package paths relative to `$TACK_ROOT` (e.g. `configs/rust`)               |

### Environment Variables

| Var                   | Default             | Purpose                                                                  |
| --------------------- | ------------------- | ------------------------------------------------------------------------ |
| `TACK_ROOT`           | dir of `tack.sh`    | Path to the tack repo                                                    |
| `TACK_CONSUMER_ROOT`  | value of `--target` | Path to the consumer repo (used for `vars_from` lookups)                 |
| `TACK_SKIP_BOOTSTRAP` | `0`                 | Set `1` to skip proto and use whatever `yq`/`tera` are on `PATH`         |
| `TACK_SANDBOX`        | `1`                 | Set `0` to disable `bwrap-run` sandboxing for `yq`/`tera`/`post` helpers |

### Selection Precedence

1. If `<package-path>` args are given, they override `pkgs` and `overrides` entirely. CLI-supplied packages bypass per-package `exclude` and `mode` overrides.
2. Otherwise: resolved `pkgs` minus any package whose `overrides.<pkg>.exclude` contains the literal `"**"` (whole-package opt-out). File-level patterns in `exclude` filter individual files inside the package; they do not remove the package.
3. Empty selection is a hard error: `no packages selected: pass packages on CLI or set pkgs in tackrc.yml`.

### Exit Codes

| Code  | Meaning                                   |
| ----- | ----------------------------------------- |
| `0`   | success                                   |
| `1`   | error (see `[tack] error: ...` on stderr) |
| `130` | interrupted (`SIGINT`)                    |
| `143` | terminated (`SIGTERM`)                    |

Any non-zero exit also produces a diagnostic line of the form `[tack] aborted: exit=N line=L cmd=...` on stderr from the `EXIT` trap.

---

## 2. Control File: `tackrc-defaults.yml` and `tackrc.yml`

The **defaults** file (`<tack>/tackrc-defaults.yml`) is required. The **consumer** file (`<consumer>/tackrc.yml`) is optional and is deep-merged on top via `yq ea '. as $i ireduce ({}; . * $i)'`.

| Key             | Type                      | Purpose                                                                                                |
| --------------- | ------------------------- | ------------------------------------------------------------------------------------------------------ |
| `pkgs`          | list of path-globs        | Packages to apply, relative to `$TACK_ROOT`. Globs like `configs/*` are expanded against `$TACK_ROOT`. |
| `overrides`     | map keyed by package path | Per-package settings (`exclude`, `mode`).                                                              |
| `pkgs_metadata` | map keyed by package path | Per-package data exposed to tera as `pkg` during render of files in that package.                      |
| `vars`          | arbitrary                 | Available in tera templates by their dotted path (e.g. `vars.user.email`).                             |
| `moon`          | map                       | Read by moon-related templates (`toolchains`, `workspace_base_source`, `workspace_base_ref`).          |

### `overrides.<pkg>` Sub-Keys

| Sub-key   | Type                       | Purpose                                                                                                                            |
| --------- | -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `exclude` | list of shell-glob strings | Filter files inside the package. The literal `"**"` removes the **whole package** from selection.                                  |
| `mode`    | ordered list of mode rules | Same shape as `mode` in a package's `tack.yml`. Consumer rules are evaluated **before** the package's own rules; first match wins. |

Glob notes:

- Recursive `**` and dotfile matching are enabled (`globstar`, `dotglob`, `nullglob`, `extglob`).
- A literal `pkgs` entry (no `*`, `?`, `[`) that does not resolve to a directory under `$TACK_ROOT` is a hard error (`pkg literal does not resolve to a directory`).
- Glob entries that match nothing are silently skipped.
- `exclude` patterns are matched against package-relative paths.

---

## 3. Per-Package Manifest: `tack.yml`

A package may contain a `tack.yml` declaring parameters that cannot be derived from filenames. All keys are optional.

```yaml
path_prefix: .moon

ignore:
  - "scripts/debug.sh"
  - "*.local.*"

link:
  unfold:
    - .moon/partials

mode:
  - copy: ".github/**"
  - link: "**"

files:
  moon.yml:
    target: moon.yml
  greeting.tera.yml:
    vars_from: tackrc.yml
    post: "shfmt -w"
  package.merge.json:
    overwrite: false
```

| Key                     | Type                               | Purpose                                                                                                                                                                          |
| ----------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `path_prefix`           | string                             | Prepended to derived target paths in the package (bypassed by `files.<src>.target`).                                                                                             |
| `link.unfold`           | list of dirs                       | Directories `mkdir -p`'d in the target before linking.                                                                                                                           |
| `ignore`                | list of shell-glob strings         | Package-declared file filters. Matching files are skipped during apply for every consumer (including under CLI selection).                                                       |
| `mode`                  | ordered list of single-key entries | Each entry is `{copy: <glob-or-list>}` or `{link: <glob-or-list>}`. First match wins.                                                                                            |
| `files.<src>.vars_from` | string                             | Override tera context for this source file (`tackrc.yml`, `@tack/...`, `@consumer/...`, `~/...`, or `/abs/path`).                                                                |
| `files.<src>.post`      | string                             | Post-render command; word-split on whitespace and run inside `bwrap-run` with the scratch file appended.                                                                         |
| `files.<src>.target`    | path (target-relative)             | Override target for any file in the package (render, copy, concat, merge, and unmarked link/copy). Bypasses `path_prefix`.                                                       |
| `files.<src>.overwrite` | boolean (default `true`)           | When `false`, skip the file if its target already exists as a regular file. A symlink at the target is never treated as seeded and is replaced. `--overwrite` disables the skip. |

---

## 4. File Dispatch Order (ADR-0009)

For each file in a selected package, `tack` chooses behavior in this order:

1. **Filename content marker** (always wins over `mode` rules):

   | Pattern                        | Behavior                                                                                                                                              |
   | ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
   | `*.tera.*`                     | Render via `tera`; target = `strip_marker(src)` in same relative dir                                                                                  |
   | `*.copy.*`                     | Copy verbatim; target = `strip_marker(src)`. Also resolves mode to `copy`.                                                                            |
   | `*.concat.*`                   | Append to line-oriented target (default = `strip_marker(src)`). Two-line signature dedup makes re-runs idempotent. Never used for Nix/JSON/YAML/TOML. |
   | `*.merge.json`                 | Deep-merge into target via `yq` (default target = `strip_marker(src)`). Missing target is created.                                                    |
   | `*.merge.yml` / `*.merge.yaml` | Same as above for YAML.                                                                                                                               |
   | `*.merge.toml`                 | Same as above for TOML (`yq -p toml -o toml`). Prefer stub+extend when the tool supports `extend` (e.g. `ruff.toml`).                                 |
   | `tack.yml`                     | Skipped (control file).                                                                                                                               |

2. **`mode` rules** for everything else, in this order, first match wins:
   - Consumer `overrides.<pkg>.mode` (skipped when packages come from CLI args).
   - Package `tack.yml` `mode`.
   - Implicit fallback: `link` (a relative per-file symlink via `ln -sfn`).

---

## 5. Opt-In Sub-Packages (`configs/common/lfs`)

A package may carry optional sub-packages in subdirectories. The parent lists them in `ignore` so its own walk skips them; a consumer enables one by naming it in `pkgs`.

- **`configs/common/lfs`**: Appends Git LFS filter rules (`.blend`, `.dwg`, `.skp`, `.3dm`, `.stl`, `.3mf`, `.glb`, `.fbx`, `.pdf`, `.exr`, `.hdr`, `.psd`, `.kra`, `.xcf`, `.tif`) to the root `.gitattributes`.
  ```yaml
  pkgs:
    - configs/common
    - configs/common/lfs
  ```
  Then run `git lfs install` once per clone. If files matching an LFS rule were committed before the rule existed, fix with `git lfs migrate import --no-rewrite <paths>`.

---

## 6. Troubleshooting

- **`[tack] aborted: exit=N line=L cmd=...`** — the diagnostic `EXIT` trap fired. `cmd` is the last command before the abort. Run with `bash -x ./tack.sh ...` for a full trace.
- **`pkg literal does not resolve to a directory: <path>`** — the literal entry in `pkgs` does not exist under `$TACK_ROOT`. Fix the path or convert it to a glob.
- **`no packages selected`** — both CLI args and the resolved `pkgs` list are empty (or every package was opted out via `overrides.<pkg>.exclude: ["**"]`).
- **`vars_from not found`** — the resolved path does not exist. Check the shorthand prefix (`@tack/`, `@consumer/`, `~/`, absolute, or bare = `$TACK_CONSUMER_ROOT/...`).
- **`proto not found on PATH`** — install proto and open a new shell, or `export PATH="${PROTO_HOME:-$HOME/.proto}/bin:$PATH"`.
- **`proto could not install yq` / `... tera`** — run `(cd .tack/configs/common && proto install yq && proto install tera)` to see proto's own error. On proto 0.63+ confirm `proto trust .tack/configs/common/.prototools` succeeded.
- **Submodule directory empty after clone** — run `git submodule update --init --recursive`.
- **devenv import fails with `.tack/... No such file`** — the submodule must be checked out at exactly `.tack`.

---

## 7. Shell Discipline (For Contributors)

`tack.sh` runs under `set -euo pipefail`:

1. Never end a function, subshell, or `while`/`for` body on a bare `cmd1 && cmd2` or `cmd1 || cmd2` standalone statement. Wrap in `if cmd1; then cmd2; fi` or terminate with `:` / `return 0`.
2. Functions called inside `var=$(fn)` must return `0` except on conditions the caller is prepared to distinguish; signal errors via stdout sentinels or `TACK_ERR_FILE`, not `die`.
3. The diagnostic `EXIT` trap (`_tack_on_exit`) must not be clobbered by inner functions; use `tack_cleanup_add` to register scratch paths for removal.

### Moon, Proto, and Bats Performance Discipline

1. **Leverage Moon and Proto built-ins before hand-rolling shell logic:**
   - Declare `toolchains` on Moon tasks (e.g. `toolchains: ["javascript", "node"]`) and use `script:` whenever shell expansion (`$(nproc)`, pipes, `eval`) is required (`command:` does not execute in a shell).
   - For tasks that spawn `.prototools` plugins (`yq`, `tera`, `dprint`, `shellcheck`) hundreds of times in tight loops, run `eval "$(proto activate bash --export)"` first so resolved tool binary directories sit ahead of `~/.proto/shims` on `PATH` (avoiding per-call shim dispatch and `ldd` probes).
   - Check `proto bin <tool>` before running `proto install <tool>`, and check whether `$PROTO_HOME/shims/<cmd>` exists before invoking `proto bin <cmd>` in wrappers like `bwrap-run.sh`.
2. **Keep hot per-file loops in pure Bash:**
   - Prefer parameter expansion (`${p%/*}`, `${p##*/}`) over forking `dirname`, `basename`, or `sed` inside per-file loops, and pre-check whether `tack.yml` is non-empty and contains a key (`manifest_has_key`) before spawning `yq`.
3. **Why `bats --jobs` uses `--no-parallelize-within-files`:**
   - Bats parallelizes **across** `.bats` files using GNU `parallel`, but parallelizes **within** a single `.bats` file using its own `lib/bats-core/semaphore.bash`.
   - `semaphore.bash` polls `find "$BATS_SEMAPHORE_DIR" -name 'slot-*' | wc -l` and blocks on a hardcoded `sleep 1` (1 full second) whenever all slots are occupied. When combined with file-level `parallel`, `N` files × `N` within-file jobs contend on the same `N`-slot semaphore directory, causing hundreds of 1-second sleeps.
   - Always pass `--no-parallelize-within-files` with `--jobs` so GNU `parallel` schedules `.bats` files across cores without triggering `semaphore.bash`.
4. **Tracing process-spawn and tree-walk regressions:**
   - To audit subprocess spawns (`execve`) or directory walks (`getdents64`) across `moon`, `bats`, and `bwrap` namespaces:
     ```bash
     strace -f -e trace=execve -o /tmp/exec.log moon run root:test-unit --cache=off
     awk -F'"' '/execve\(/ {print $2}' /tmp/exec.log | sort | uniq -c | sort -rn | head -n 20
     ```
