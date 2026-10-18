# Renovate: Dependency Ownership Split Between `tack` and Consumers

`tack` uses two distinct Renovate configurations to separate **baseline tooling updates** (owned by `tack`) from **application/library dependency updates** (owned by each consumer repository), while still allowing both to coexist in shared root files like `package.json`.

Implementation:

- `.github/renovate.json5` — runs only on the `tomdavidson/tack` repository itself.
- `configs/renovate/default.json5` — shared preset hosted in `tack`, pulled by every consumer repository via `extends`.
- `configs/renovate/.github/renovate.json5` — seed-once (`overwrite: false`) stub copied into consumer repositories.

---

## 1. The Core Problem

When a consumer repo runs `tack.sh`, `tack` materializes or merges several root-level files (`package.json`, `pnpm-workspace.yaml`, `.prototools`, `dprint.json`, `.github/workflows/*`).

If Renovate ran with default settings in a consumer repo, two bad things would happen:

1. **Duplicate / conflicting tooling PRs**: Every consumer repo would get its own noisy PRs bumping `eslint`, `oxlint`, `typescript`, `vitest`, `dprint` plugins, and GitHub Actions—drifting out of sync with `.tack` and breaking the next `./.tack/tack.sh` run.
2. **Blocked root dependencies**: Conversely, if Renovate ignored the entire repo root (or only enabled `git-submodules`), any dependency a consumer legitimately added to their root `package.json`, `Cargo.toml`, `pyproject.toml`, or `composer.json` would never be updated.

---

## 2. How the Split Solves Both Nuances

### Nuance A: ADR-0009 Stub + Remote Preset (`configs/renovate`)

Renovate does not reliably follow symlinks into submodules, and consumers occasionally need repo-specific `packageRules` or `ignoreDeps`. Following ADR-0009:

1. `configs/renovate/.github/renovate.json5` is copied **once** (`overwrite: false` in `configs/renovate/tack.yml`) into the consumer repo:
   ```json5
   {
     $schema: "https://docs.renovatebot.com/renovate-schema.json",
     extends: ["github>tomdavidson/tack//configs/renovate/default.json5"],
   }
   ```
2. `configs/renovate/default.json5` stays inside `tack` (`ignore: [default.json5]`). Whenever policy changes in `tack`, every consumer inherits the new Renovate rules immediately without re-running `tack.sh`, while any local overrides added by the consumer in their `.github/renovate.json5` are preserved.

### Nuance B: Coexisting in Root `package.json` via `pnpm-workspace.yaml` Catalogs

In JavaScript/TypeScript consumers, `configs/javascript/package.merge.json` and `configs/web/package.merge.json` merge `tack`'s baseline devDependencies into the consumer's root `package.json`.

To prevent Renovate from fighting `tack` over root `package.json` while still updating consumer-added root dependencies:

1. **All `tack`-managed dependencies use `"catalog:"` or `"workspace:*"`** in `package.merge.json`:
   ```json
   {
     "devDependencies": {
       "@tack/eslint-config": "workspace:*",
       "eslint": "catalog:",
       "oxlint": "catalog:",
       "typescript": "catalog:",
       "vitest": "catalog:"
     }
   }
   ```
   Their actual version numbers live in `pnpm-workspace.yaml` (merged from `configs/*/pnpm-workspace.merge.yaml`).
2. **`configs/renovate/default.json5` puts `pnpm-workspace.yaml` in `ignorePaths`, NOT `package.json`**:
   ```json5
   ignorePaths: [
     "**/node_modules/**",
     ".tack/**",
     ".moon/**",
     ".github/workflows/**",
     ".github/actions/**",
     ".prototools",
     "dprint.json",
     "pnpm-workspace.yaml",
   ]
   ```
3. **Result**:
   - When Renovate scans the consumer's root `package.json`, it skips `"catalog:"` and `"workspace:*"` entries (because `pnpm-workspace.yaml` is ignored). Those tools only update when `.tack` bumps.
   - If the consumer adds their own dependency with a real semver range to root `package.json` (e.g., `"zod": "^4.0.0"`), root `Cargo.toml`, root `pyproject.toml`, root `composer.json`, or any Moon project (`apps/*`, `packages/*`, `plugins/*`, `services/*`, `crates/*`, `website`), Renovate updates it normally.

### Nuance C: Keeping `.tack` Updated (`git-submodules`)

Renovate's built-in `git-submodules` manager is disabled by default (`enabled: false`), and listing it in `enabledManagers` alone does not turn it on. `configs/renovate/default.json5` explicitly sets:

```json5
"git-submodules": {
  enabled: true,
},
```

and pairs it with a `packageRules` entry matching `matchDepNames: [".tack"]` (`minimumReleaseAge: "0 days"`, `commitMessagePrefix: "chore(tack):"`).

- If `.gitmodules` in the consumer repo does not set a `branch`, Renovate tracks the latest commit on `tack`'s default branch (`main`).
- If `.gitmodules` sets `branch = v0.1.0` (once `tack` tags releases) and `.tack` is checked out at a semver tag, Renovate automatically switches to `git` tag versioning and opens PRs for new `vX.Y.Z` tags.

---

## 3. How `tack` Updates Its Own Fragments (`.github/renovate.json5`)

Inside `tomdavidson/tack` itself, many dependencies live in ADR-0009 fragment files (`*.merge.yaml`, `*.merge.toml`, `*.tera.json`, `dprint-common.json`) whose filenames do not match Renovate's default patterns.

`tack`'s own `.github/renovate.json5` bridges those filenames so `tack` stays fresh:

| File in `tack`                                                                           | What Lives There                                                                                                  | How `.github/renovate.json5` Tracks It                                              |
| :--------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------- |
| `configs/common/.prototools`                                                             | `dprint`, `yq`, `moon`, `tera`, `shellcheck`, `shfmt`, `ruff`                                                     | `customManagers` (`customType: "regex"`, `managerFilePatterns: ["/(^                |
| `configs/javascript/prototools.merge.toml`                                               | `node`, `pnpm`                                                                                                    | `customManagers` (`managerFilePatterns: ["/(^                                       |
| `.moon/toolchains.yml` & `.github/actions/*/action.yml`                                  | `proto` (`version:` / `proto-version:`) & `cargo-binstall`                                                        | `customManagers` (`customType: "regex"`)                                            |
| `configs/common/dprint-common.json`                                                      | WASM plugins (`https://plugins.dprint.dev/...`) & `npm:@kachick/dprint-plugin-nix`                                | `extends: ["github>kachick/renovate-config-dprint"]` + custom regex manager on `/(^ |
| `configs/javascript/pnpm-workspace.merge.yaml` & `configs/web/pnpm-workspace.merge.yaml` | `catalog:` versions (`eslint`, `oxlint`, `oxlint-tsgolint`, `typescript`, `vitest`, `astro`, `@tailwindcss/vite`) | `npm.managerFilePatterns: ["/(^                                                     |
| `configs/drupal/variants/**/composer.tera.json`                                          | Drupal & PHP composer dependencies                                                                                | `composer.managerFilePatterns: ["/(^                                                |
