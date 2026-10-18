# Language & Framework Stacks (`configs/*`)

Detailed setup and architecture notes for the language and framework packs shipped under `configs/`.

---

## 1. JavaScript, TypeScript, and Web (`configs/javascript` & `configs/web`)

| Piece                                                    | What it provides                                                                                                                                                                       |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `configs/javascript/prototools.merge.toml`               | Merges `node` and `pnpm` pins into the consumer's `.prototools` (`target: .prototools`) so non-JS repos never download Node/pnpm                                                       |
| `configs/javascript/pnpm-workspace.merge.yaml`           | Workspace globs (`.tack/packages/*`, `apps/*`, `packages/*`, `plugins/*`, `website`) and `catalog:` pins (`eslint`, `oxlint`, `oxlint-tsgolint`, `typescript`, `vitest`, `fast-check`) |
| `configs/javascript/package.merge.json`                  | Root `devDependencies` referencing `"catalog:"` and `"@tack/eslint-config": "workspace:*"` (never sets `name`, `version`, or `packageManager`)                                         |
| `configs/javascript/eslint.config.mjs` & `oxlintrc.json` | Root lint configs extending `@tack/eslint-config` (and `@tack/eslint-config-astro` dynamically when `astro` is present)                                                                |
| `configs/javascript/.moon/tasks/typescript.yml`          | Inherited Moon tasks (`lint`, `lint-fix`, `typecheck`, `test`, `verify`, `wf`)                                                                                                         |
| `configs/web`                                            | Adds Astro / Tailwind / Vitest catalog entries, `@tack/eslint-config-astro`, `.moon/tasks/astro-plugin.yml` & `astro-website.yml`, and the `astro-plugin` Moon template                |

See [`patterns/lang-typescript.md`](../patterns/lang-typescript.md) and [`patterns/testing-typescript.md`](../patterns/testing-typescript.md) for clean-architecture layer rules (`*.domain.ts`, `*.app.ts`, `*.infra.ts`).

---

## 2. Python (`configs/python`)

`configs/python` is a tooling baseline, not an interpreter manager. Each Moon project owns its Python version and environment; the pack supplies `uv`, `ruff`, shared lint/format rules, and Moon tasks.

| Piece                                   | What it provides                                                                                                                                                                                 |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `configs/python/python.nix` (devenv)    | `pkgs.uv`, `UV_MANAGED_PYTHON=1`, and a sandboxed `uv` script via `bwrap-run`. Imported from `.tack`                                                                                             |
| `configs/python/ruff.toml`              | Shared lint rules, read through `.tack`. The repo root gets a seed-once stub (`extend = ".tack/configs/python/ruff.toml"`) for overrides; project `ruff.toml` files `extend = "../../ruff.toml"` |
| `configs/common/.prototools`            | Pins `ruff` for `ruff check` in the Moon `lint` task (dprint formats via its own Wasm build of ruff)                                                                                             |
| `configs/common/dprint-common.json`     | `@dprint/ruff` plugin with a `"ruff"` block (indent 4, import sorting); excludes `.venv`, caches, `uv.lock`                                                                                      |
| `configs/python/.moon/tasks/python.yml` | Delivered to `.moon/tasks/python.yml` (ADR-0010): `lint`, `lint-fix`, `typecheck`, `test`, `verify` for projects tagged `python`                                                                 |

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

### Interpreter Versions

Nothing in `tack` pins Python. `uv` downloads a managed interpreter per project from `.python-version` / `requires-python`, so incompatible projects coexist with their own `pyproject.toml`, `uv.lock`, and `.venv`:

```bash
cd apps/my-tool
uv python pin 3.14          # writes .python-version
uv add --dev pytest basedpyright
uv sync
```

Projects opt in with `tags: [python]` in `moon.yml`:

- **Format**: `moon run :fmt` (`dprint fmt` with `@dprint/ruff`).
- **Lint**: `moon run <project>:lint` (`ruff check`).
- **Types**: `moon run <project>:typecheck` (`uv run --frozen basedpyright`).
- **Tests**: `moon run <project>:test` (`uv run --frozen pytest`).

---

## 3. PHP & Drupal (`configs/php` & `configs/drupal`)

`configs/php` provides the base PHP 8.3 + Composer + `phpcs` + `phpstan` + `dprint-php.json` stack. `configs/drupal` layers FrankenPHP, Drupal coding standards, and deployment scripts on top, with optional variants under `configs/drupal/variants/`.

| Piece                                | What it provides                                                                                                                            |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `configs/php`                        | `php.nix` (PHP 8.3 + sandboxed `composer`), `phpcs.xml.dist`, `phpstan.neon.dist`, `dprint-php.json`, `.moon/tasks/php.yml`                 |
| `configs/drupal`                     | `phpcs.xml.dist`, `phpstan.neon.dist`, `phpunit.xml.dist`, `.moon/tasks/drupal/`, `drupal-module` Moon template, Fly.io cron/db scaffolding |
| `configs/drupal/drupal.nix` (devenv) | Imports `php.nix`; adds FrankenPHP, `app:composer`, `drupal:deploy`, `drupal:reset`. **No database and no S3** (bring your own)             |
| `configs/drupal/variants/dlg-ms`     | LocalGov DLG Microsites extras: Caddyfile, post-install hook, `dlg-ms` Moon template                                                        |
| `configs/drupal/variants/dlg-ms.nix` | Imports `drupal.nix`; adds MariaDB 11.4, RustFS (S3), `db:user`, `s3:buckets`, `drupal:setup`, DB and S3 env vars                           |

### Base Drupal (Bring Your Own Database)

```yaml
# tackrc.yml
pkgs:
  - configs/common
  - configs/devenv
  - configs/php
  - configs/drupal
```

```nix
# devenv.nix
{ pkgs, lib, config, ... }:
{
  imports = [ ./.tack/configs/drupal/drupal.nix ];
  env.APP_ROOT = "${config.devenv.root}/apps/my-app";
  services.postgres.enable = true;
}
```

### LocalGov DLG Microsites (`dlg-ms`)

```yaml
# tackrc.yml
pkgs:
  - configs/common
  - configs/devenv
  - configs/php
  - configs/drupal
  - configs/drupal/variants/dlg-ms
vars:
  project:
    name: your-org/your-project
```

```bash
.tack/tack.sh                         # deliver nix, tasks, templates, Caddyfile
moon generate dlg-ms -- --name hub    # scaffold apps/hub/
devenv up                             # MariaDB, RustFS, composer, FrankenPHP
devenv tasks run drupal:setup         # first-time install (+ demo content)
```

---

## 4. Rust (`configs/rust`)

| Piece                                         | What it provides                                                                                             |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `configs/rust/.clippy.toml` & `.rustfmt.toml` | Symlinked to the consumer root (`rustfmt` runs via `dprint` exec plugin)                                     |
| `configs/rust/clippy-cargo.merge.toml`        | Merges `[workspace.lints.rust]` and `[workspace.lints.clippy]` into root `Cargo.toml` (`target: Cargo.toml`) |
| `configs/rust/.moon/tasks/rust.yml`           | Inherited Moon tasks (`build`, `typecheck`, `lint`, `test`, `verify`, `audit`) for `toolchains: "rust"`      |
