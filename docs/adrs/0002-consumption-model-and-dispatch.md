---
number: 2
title: Consumption model and dispatch
date: 2026-04-23
status: proposed
tags:
  - consumption
  - dispatch
  - consumer-config
---

# 2. Consumption model and dispatch

Date: 2026-04-23

## Status

Proposed

## Context

Tack (ADR-0001) centralizes shared engineering assets across consumer repos.
Consumers integrate those assets through two layers: a dispatch mechanism that
decides per-file how each asset installs into the consumer filesystem, and a
policy layer that decides per-package whether the consumer binds to tack via
submodule (co-dev) or via remote URL (read-only).

Dispatch and policy are independent. A consumer may use submodule mode for
packages they want to edit in-place and URL mode for packages they only
consume. Within a package, the dispatch mechanism (link, render, copy, merge)
is uniform across files and determined by filename.

## Decision

### Layout

All shared assets live under `configs/`. Subdirectories are packages.

```
configs/
  common/     # cross-language foundation: .editorconfig, dprint.json, .gitignore, .prototools
  js/         # JS/TS toolchain: eslint, oxlint, tsconfig, package.json, pnpm-workspace.yaml
  rust/       # Rust toolchain: .clippy.toml, .rustfmt.toml, clippy-cargo.merge.toml
  moon/       # workspace.yml.tera, toolchain.yml.tera, tasks/, templates/, partials/, hooks/, scripts/
  github/     # composite actions, reusable workflows, workflow templates
  forgejo/    # parallel to github/, added when Forgejo support lands
patterns/
docs/
scripts/
```

`patterns/`, `docs/`, and `scripts/` are siblings of `configs/` because they are
categorically different: human-readable standards, tack's own documentation,
tack's own tooling.

### Dispatch: filename suffix determines mode

The interior marker between dots in a package file's basename tells `tack.sh`
how to install the file.

| Pattern     | Mode   | Behavior                                                                                 |
| ----------- | ------ | ---------------------------------------------------------------------------------------- |
| `*.tera.*`  | render | tera renders to a consumer-owned file with the marker stripped                           |
| `*.copy.*`  | copy   | verbatim copy to a consumer-owned file with the marker stripped                          |
| `*.merge.*` | merge  | tomlq deep-merges the fragment into a target declared in the package's tack-manifest.yml |
| (no marker) | link   | lnko symlink from consumer path into the submodule                                       |

Markers are always interior segments preserving the target extension so editor
syntax highlighting works on the source: `dprint.tera.json` renders to
`dprint.json`, `Cargo.copy.toml` copies to `Cargo.toml`,
`clippy-cargo.merge.toml` merges into a manifest-declared target.

### Package tack-manifest.yml: overrides and exclusions

Each package may contain a `tack-manifest.yml`. It declares parameters the
suffix cannot carry: merge target, template variables, post-hooks, and
subdirectory exclusions for paths that are neither installed nor rendered.
The name `tack-manifest.yml` (rather than the shorter `tack.yml`) makes the
package-scope role explicit and keeps it clearly distinct from the
consumer-level `tackrc.yml`.

```yaml
# configs/rust/tack-manifest.yml
files:
  clippy-cargo.merge.toml:
    target: ../../Cargo.toml
    enforced:
      - workspace.lints.rust.unsafe_code
      - workspace.lints.clippy.unwrap_used
      - workspace.lints.clippy.expect_used
      - workspace.lints.clippy.panic
```

```yaml
# configs/moon/tack-manifest.yml
exclude:
  - tasks/ # consumed via moon's native extends:
  - templates/ # moon handles its own templates
  - partials/
  - hooks/
  - scripts/
files:
  workspace.yml.tera:
    vars_from: ../../tackrc.yml
  toolchain.yml.tera:
    vars_from: ../../tackrc.yml
```

Absence of a `tack-manifest.yml` means pure suffix-driven defaults apply.

### tack.sh: single entrypoint

`tack.sh` lives at the tack repo root and runs four passes per package
argument:

1. **Link** via lnko with baked-in ignore patterns (`\.tera\.`, `\.copy\.`,
   `\.merge\.`, `tack-manifest.yml`) plus package `exclude:` entries.
2. **Render** every `*.tera.*` via tera, writing to the marker-stripped target.
3. **Copy** every `*.copy.*` verbatim.
4. **Merge** every `*.merge.*` into its manifest-declared target via tomlq,
   then re-apply enforced keys.

Invocation:

```sh
./.tack/tack.sh common js rust moon github
./.tack/tack.sh --dry-run common
```

### Consumer tackrc.yml: consumption policy

Consumer repos declare per-package consumption mode in `tackrc.yml` at the
repo root, sibling of `.tack/`. Consumer-owned, outside the submodule.

```yaml
# tackrc.yml
default:
  mode: submodule
  ref: v1.0.0
packages:
  common:
    mode: url
    ref: v1.0.0
  moon:
    mode: submodule # co-dev: edit-in-place contributes upstream
  github:
    mode: url
  rust:
    mode: submodule
```

`tack.sh` reads `tackrc.yml` and decides per package whether to render extends
paths as local submodule paths or raw GitHub URLs. Mode is per-package, not
per-file. Mixed mode within a package is not supported.

### Mode switching rules

- Switching a package from `submodule` to `url` or back rewrites the consumer's
  rendered files (extends targets change) on the next `tack.sh` run.
- Mode switching applies to rendered files only. Link-mode files require the
  submodule; a package whose contents are predominantly link-mode cannot be
  set to `url` mode.
- If any package requests submodule mode and `.tack/` does not exist, `tack.sh`
  errors with an instruction to add the submodule. It does not auto-clone.
- There are no CLI flags for mode or ref. Configuration lives in `tackrc.yml`
  so that what happens is visible in version-controlled code.

### Dependencies

| Tool       | Purpose                                          |
| ---------- | ------------------------------------------------ |
| git        | Submodule management                             |
| lnko       | Link pass (prebuilt binary from GitHub releases) |
| tera CLI   | Render pass                                      |
| tomlq / yq | Merge pass                                       |

moon, proto, and any language toolchain are consumer concerns, not tack.sh
dependencies.

## Consequences

- A new shared asset has one unambiguous home: under `configs/`, subdivided by
  what the asset is, with dispatch determined by filename.
- Consumer mode choice is visible in `tackrc.yml` rather than implicit in how
  files are referenced.
- Package directories mirror the consumer's target layout; mixed-mode files
  (link + render + merge) coexist in one package.
- URL-mode implementation is deferred. The schema ships now; `tack.sh`
  initially implements only submodule-mode. Attempting url mode against a
  `tack.sh` that predates the implementation must error cleanly, not silently
  skip.
- The consumer-level `tackrc.yml` and package-level `tack-manifest.yml` are
  distinctly named. `tackrc.yml` is the consumer's runtime policy (rc
  convention); `tack-manifest.yml` is the package's declared install
  parameters (manifest convention). No naming collision between the two
  scopes.
- Unknown interior suffixes (`foo.bak.toml`) currently fall through to link
  mode. A `--strict` mode that rejects unknown suffixes is deferred until
  needed.
- Consumers pin tack at a tag and expect `tackrc.yml` to keep parsing. The
  schema must stay stable across tack versions, or breaking changes must be
  gated on a new ADR and a major version bump.
