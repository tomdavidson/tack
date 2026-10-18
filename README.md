# tack

`tack` is dotfiles for your git repo: a small shell tool that materializes a curated kit of tooling, configs, and scripts into any project that vendors it.

## Why a Submodule, Not a Generator

Generator-style tools (Yeoman, cookiecutter, `create-*` CLIs, repo templates) optimize for a one-shot scaffold: they emit files, then disconnect. Fixes made in a consumer repo cannot flow back, drift accumulates, and every consumer eventually owns a slightly different fork of the baseline.

`tack` keeps the upstream connection alive. Distributing the kit as a vendored git submodule at `.tack` means a consumer can:

1. Pin a specific `tack` commit or release tag for reproducibility.
2. Edit `.tack` in place to improve a shared config and push a PR back upstream.
3. Receive automatic `.tack` bumps via Renovate while keeping consumer dependencies separate.

---

## 1. Mental Model

```text
tack repo (vendored at .tack)                   consumer repo
-----------------------------                   -------------------
tack.sh                                         tackrc.yml (optional)
tackrc-defaults.yml      ---- merge ---->       ...your project...
configs/<pkg>/...                               <files materialized via
scripts/...                                      link/copy/render/concat/merge>
```

- `tack.sh` lives in `.tack/tack.sh` (the `.tack` path is required; devenv modules and shared configs reference `.tack/configs/...`).
- `<consumer>/tackrc.yml` (optional) is deep-merged on top of `.tack/tackrc-defaults.yml` to select packages, set per-package overrides, and provide `vars` to Tera templates.
- Behavior per file is decided by filename markers (`*.tera.*`, `*.copy.*`, `*.concat.*`, `*.merge.*`) and `tack.yml` rules (default for unmarked files is a relative per-file symlink).

---

## 2. Quickstart (Consumer Repo)

```bash
# 1. Add tack as a submodule at .tack (required path)
git submodule add https://github.com/tomdavidson/tack .tack
git submodule update --init --recursive

# 2. (Optional) Configure selected packages in tackrc.yml
cat > tackrc.yml <<'YAML'
pkgs:
  - configs/common
  - configs/devenv
  - configs/renovate
  - configs/javascript
  - .moon
YAML

# 3. Materialize configs and trust .prototools
.tack/tack.sh
proto trust .prototools
```

Prerequisite: [`proto`](https://moonrepo.dev/docs/proto/install) (`curl -fsSL https://moonrepo.dev/install/proto.sh | bash`) and `bash` 4+. On every run, `tack.sh` provisions its own pinned `yq` and `tera` binaries from `.tack/configs/common/.prototools`.

---

## 3. Running `tack` & Moon Tasks

```bash
# Apply packages
.tack/tack.sh                       # apply pkgs from merged tackrc.yml
.tack/tack.sh --dry-run             # preview actions without writing
.tack/tack.sh --overwrite           # re-seed overwrite:false files
.tack/tack.sh configs/rust          # apply specific package(s)

# Workspace Moon tasks (inherited from .moon)
moon run :fmt                       # format all files via dprint
moon run :fmt-check                 # check formatting
moon run :lint                      # run linters across projects
moon run :test                      # run tests (bats in tack; vitest/pytest/nextest in consumers)
moon run :verify                    # typecheck + lint + test
```

---

## 4. Available Config Packages (`configs/*`)

| Package                | Summary                                                                                                                                             |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `configs/common`       | `.gitignore`, `.gitattributes`, `.editorconfig`, `.prototools`, `dprint.json` stub + `dprint-common.json` (`configs/common/lfs` opt-in for Git LFS) |
| `configs/devenv`       | `devenv.nix` / `devenv.yaml` templates and `bwrap-run` bubblewrap sandboxing for package managers                                                   |
| `configs/renovate`     | Seed-once `.github/renovate.json5` stub extending `configs/renovate/default.json5`                                                                  |
| `configs/javascript`   | Node/pnpm `.prototools` merge, `pnpm-workspace.yaml` catalog, `@tack/eslint-config`, `oxlintrc.json`, TypeScript Moon tasks                         |
| `configs/web`          | Astro + Tailwind + Vitest workspace additions, `@tack/eslint-config-astro`, `astro-plugin` template & Moon tasks                                    |
| `configs/rust`         | `.clippy.toml`, `.rustfmt.toml`, `Cargo.toml` workspace lints merge, Rust Moon tasks                                                                |
| `configs/python`       | `python.nix` (sandboxed `uv`), `ruff.toml` stub + shared rules, Python Moon tasks                                                                   |
| `configs/php`          | `php.nix` (PHP 8.3 + sandboxed `composer`), `phpcs`, `phpstan`, `dprint-php.json`, PHP Moon tasks                                                   |
| `configs/drupal`       | `drupal.nix` (FrankenPHP + drush), Drupal `phpcs`/`phpstan`/`phpunit`, variants (`dlg-ms`), Moon tasks & templates                                  |
| `configs/devcontainer` | `.devcontainer/devcontainer.json` Tera template                                                                                                     |
| `.moon`                | Shared root `moon.yml`, `.moon/workspace-base.yml`, `.moon/toolchains-*.yml`                                                                        |

---

## 5. Deep-Dive Documentation (`docs/` & `patterns/`)

- **[`docs/reference.md`](docs/reference.md)** — CLI flags, `tackrc.yml` & `tack.yml` schema, ADR-0009 file dispatch (`*.tera.*`, `*.copy.*`, `*.concat.*`, `*.merge.*`), Git LFS opt-in, troubleshooting, and shell discipline.
- **[`docs/stacks.md`](docs/stacks.md)** — Per-stack setup guides for JavaScript/TypeScript/Web, Python (`uv` + `ruff`), PHP/Drupal (`drupal.nix` & `dlg-ms`), and Rust.
- **[`docs/renovate.md`](docs/renovate.md)** — How Renovate separates `tack`-owned tooling updates (`pnpm-workspace.yaml` catalogs and `.tack` submodule bumps) from consumer-owned dependencies in root `package.json` and Moon projects.
- **[`docs/bwrap.md`](docs/bwrap.md)** & **[`docs/bwrap-moon-sandbox-scope.md`](docs/bwrap-moon-sandbox-scope.md)** — Unprivileged bubblewrap sandboxing (`bwrap-run.sh`) for devenv shells and package managers.
- **[`docs/adrs/`](docs/adrs/)** — Architecture Decision Records (including ADR-0007 sandboxing, ADR-0008 writable `.tack`, ADR-0009 config delivery modes, and ADR-0010 Moon task organization).
- **[`patterns/`](patterns/)** — Language and testing patterns (`toms-clean-code.md`, `toms-clean-arch.md`, `moon-workspace-pattern.md`, `lang-typescript.md`, `lang-rust.md`, `lang-python.md`, `lang-php.md`, `testing*.md`).
