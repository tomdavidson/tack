# Moon Workspace Pattern

> Pattern for using [Moon](https://moonrepo.dev) as the standard workspace orchestrator, task runner, toolchain manager, and CI coordinator. Applies to monorepos and single-project repos alike.
>
> **Official Documentation:** [https://moonrepo.dev/docs](https://moonrepo.dev/docs)

## When to Use

Apply this pattern when a Rust or TypeScript project needs consistent tooling, declarative tasks, Git hook management, and CI coordination. The core logic lives in your language-specific tools (cargo, bun, pnpm, etc.) while Moon orchestrates them.

Use Moon even in single-project repos. The overhead is one `.moon/` directory. The payoff is reproducible builds, managed toolchains, and a single task interface for every contributor.

## Configuration & Schema Validation

Moon configuration files are strictly validated YAML. The underlying JSON schemas use `additionalProperties: false`, meaning any typo, unknown key, or deprecated field will cause immediate failures.

To maintain integrity and usability across the team:

1. **Always use `$schema` comments**: Inject the official schema URL at the top of every config file. Your editor will automatically validate your YAML and provide autocomplete.
2. **Do not vendor schema JSON files**: Do not commit `workspace.json`, `tasks.json`, etc., to your repo. Rely on the remote schema URLs so they stay perfectly aligned with Moon's current specifications.
3. **Validate early**: Rely on your IDE's YAML validation and `moon query projects` / `moon ci` in CI (never run `moon check` in CI; see [CI Integration](#ci-integration) and ADR-0010).

## Architecture

Moon sits above your languages and package managers and below Git/CI:

```text
┌───────────────────────────────┐
│           Git / CI            │
│  (push, PRs, pipelines)       │
└───────────────┬───────────────┘
                │  moon ci / hooks
┌───────────────▼───────────────┐
│             moon              │
│  workspace, tasks, toolchain  │
└───────────────┬───────────────┘
        ┌───────┴────────┬────────┐
        │                │        │
┌───────▼───────┐ ┌──────▼──────┐ ┌──────▼──────┐
│  TypeScript   │ │    Rust     │ │   Other     │
│  (pnpm/bun)   │ │  (cargo)    │ │  tools      │
└───────────────┘ └─────────────┘ └─────────────┘
```

Moon does not replace language-native tooling. It standardizes how tasks are declared and run.

## Workspace Structure

```text
moon.yml                   # root project (id: root): fmt, fmt-check, lint-sh, verify
.moon/
├── workspace.yml          # workspace-level settings, projects, VCS pre-push hook
├── toolchains.yml         # pinned tool versions (proto, node, pnpm, rust)
└── tasks/                 # pack-delivered tag-inherited task definitions (ADR-0010)
    ├── typescript.yml     # delivered by configs/javascript (tags: ["typescript"])
    ├── rust.yml           # delivered by configs/rust       (tags: ["rust"])
    ├── python.yml         # delivered by configs/python     (tags: ["python"])
    └── drupal/            # delivered by configs/drupal     (tags: ["drupal"])
<project>/
├── moon.yml               # project config: layer/type, tags, minimal overrides
├── src/
└── ...
```

For single-project repos, the project root and workspace root are the same directory. Moon handles this with a single project entry in `workspace.yml`.

## Toolchain Management

Moon manages tool versions via proto (its built-in version manager). Every tool is pinned to an explicit version so that all machines (dev, CI, containers) use the same binaries.

```yaml
# $schema: https://moonrepo.dev/schemas/toolchain.json
# .moon/toolchains.yml
node:
  version: "22.12.0"
  packageManager: "pnpm"
  pnpm:
    version: "9.15.0"

bun:
  version: "1.2.4"

rust:
  version: "1.85.0"
```

Rules:

- Pin full versions (`22.12.0`), not partials (`22`) or aliases (`latest`).
- Update versions via PR with CI validation instead of ad-hoc on dev machines.
- Use `MOON_TOOLCHAIN_FORCE_GLOBALS=true` in pre-configured environments (Docker images, locked-down CI) where tools are already installed.
- For personal defaults outside the repo, rely on `~/.prototools` instead of modifying the repo's `toolchains.yml`.

## Task Definitions

Tasks are defined at two levels: inherited (workspace-wide defaults) and project-level (overrides).

### Inherited Tasks & Canonical Vocabulary (ADR-0010)

Define once in `.moon/tasks/` (delivered by each `tack` language pack and scoped via `inheritedBy.tags`), applied to every project that declares the matching tag (`tags: ["typescript"]`, `tags: ["rust"]`, `tags: ["python"]`, `tags: ["drupal"]`).

Every stack exposes the same canonical task names:

| Task                | `runInCI`      | Purpose                                                                                                |
| ------------------- | -------------- | ------------------------------------------------------------------------------------------------------ |
| `fmt` / `fmt-check` | `false`/`true` | Root `dprint fmt` / `dprint check` across all languages                                                |
| `lint` / `lint-fix` | `true`/`false` | Stack linter (`oxlint`+`eslint`, `cargo clippy`, `ruff`, `phpcs`)                                      |
| `typecheck`         | `true`         | Type / static analysis (`tsc`, `cargo check`, `basedpyright`, `phpstan`)                               |
| `test`              | `true`         | Fast, hermetic unit + property tests (`vitest`, `cargo nextest`, `pytest`, `phpunit --testsuite=unit`) |
| `test-integration`  | `false`        | Service-backed / DB / kernel tests (explicit opt-in)                                                   |
| `test-e2e`          | `false`        | Browser / full-stack E2E tests (explicit opt-in)                                                       |
| `verify`            | `false`        | Local developer aggregator (`~:lint` + `~:typecheck` + `~:test`)                                       |

### Project-Level Overrides

Projects can extend, override, or exclude inherited tasks.

```yaml
# $schema: https://moonrepo.dev/schemas/project.json
# <project>/moon.yml
type: "application"
tags: ["backend"]

tasks:
  build:
    command: "cargo"
    args: ["build", "--release"]
    deps: ["~:lint", "~:test"]
    inputs:
      - "src/**/*.rs"
      - "Cargo.toml"
    outputs:
      - "target/release/myapp"
```

### Task Dependencies

Use `deps` to express ordering. Moon builds a dependency graph and runs tasks in parallel where possible.

```yaml
build:
  command: "cargo build --release"
  deps:
    - "~:lint" # same project
    - "~:test" # same project
    - "shared-lib:build" # another project
```

`~:` refers to the current project. Named projects create cross-project dependencies.

### Scripts vs Commands

- `command` + `args`: simple commands (single binary, no pipes or redirects).
- `script`: compound shell commands (pipes, redirects, `&&` chains).

```yaml
# Simple — use command
lint:
  command: "oxlint"
  args: ["--fix", "."]

# Compound — use script
check-all:
  script: "cargo fmt --check && cargo clippy -- -D warnings && cargo test"
```

## Templates and Code Generation

Moon templates provide lightweight code generation. Use them to scaffold new projects and standard files (configs, task files), not to encode business logic.

### Template Layout

Place templates in a dedicated directory, for example:

```text
.moon/
  templates/
    ts-app/
      template.yml
      files/
        package.json.tera
        tsconfig.json.tera
        src/index.ts.tera
    rust-lib/
      template.yml
      files/
        Cargo.toml.tera
        src/lib.rs.tera
```

Each template has:

- `template.yml`: metadata and variables.
- `files/`: Tera (`.tera`) templates.

Example `template.yml`:

```yaml
# $schema: https://moonrepo.dev/schemas/template.json
# .moon/templates/ts-app/template.yml
name: "ts-app"
description: "Standard TypeScript application"

variables:
  name:
    type: string
    prompt: "Project name"
  scope:
    type: string
    prompt: "NPM scope (without @)"
    default: "zflow"
```

Render with:

```bash
moon generate ts-app my-new-app
```

Guidelines:

- Use templates to enforce standard layout and configs (moon.yml, tsconfig, lint config, basic README).
- Keep templates declarative. No application-specific logic.
- Prefer a small number of well-maintained templates over many one-offs.

## Git Hooks

Moon manages Git hooks directly. This replaces Husky and lint-staged.

### Philosophy

- **No pre-commit hooks.** Commits on feature branches must be cheap to create. Frequent commits and experiments should not be blocked by tooling.
- **Single pre-push hook.** Before sharing work, code must be formatted, linted, and tested. Pushes are the quality gate.

### Pre-Push Hook

Configure a `pre-push` hook in `.moon/workspace.yml` (shipped by `tack`'s `.moon` package):

```yaml
# $schema: https://moonrepo.dev/schemas/workspace.json
# .moon/workspace.yml (sketch)
vcs:
  manager: "git"
  defaultBranch: "main"
  syncHooks: true
  hooks:
    pre-push:
      - "moon run :fmt"
      - "moon run :lint-fix --affected --upstream"
      - "git diff --exit-code"
      - "moon run :fmt-check --affected --upstream"
      - "moon run :lint --affected --upstream"
```

Policy:

- **Lint** and **format check** run on affected projects only.
- **Typecheck** runs on affected projects only.
- **Unit tests**:
  - If the test framework supports efficient affected test selection (e.g. Vitest/Jest with path filters), configure the test task to run tests for affected projects only.
  - Otherwise, the test task runs all unit tests for affected projects (project-level), even if the runner itself cannot select individual tests.

The pattern is:

1. Filter by affected **projects** via Moon (`--affected`).
2. Inside each affected project, use test runner support for affected tests if available.
3. Otherwise, run that project’s unit test task in full.

### What This Replaces

- No Husky configuration.
- No lint-staged.
- No ad-hoc `.git/hooks/*` scripts.

Moon is the single source of truth for Git hooks and what runs before push.

## CI Integration

Moon's `moon ci` command handles affected-target detection, dependency installation, and parallel execution.

```yaml
# GitHub Actions example
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0 # needed for Git diff
      - uses: moonrepo/setup-toolchain@v2
      - run: moon ci
```

> **Why `moon ci` instead of `moon check` or a `:check` task?**
>
> - `moon ci` runs only affected tasks where `runInCI: true` (`fmt-check`, `lint`, `typecheck`, `test-unit`/`test`, `build`).
> - `moon check` (or `moon c`) is a built-in Moon CLI command that runs _every_ `build` and `test`-type task regardless of `runInCI: false` (sweeping up slow integration/E2E tests and mutating tasks).
> - For a fast local or pre-push gate that runs only lightweight checks (`lint` + `typecheck` + `test-unit`), define a `verify` task (`command: "noop"`, `runInCI: false`) rather than `:check` (see ADR-0010).

`moon ci`:

1. Determines changed files by comparing HEAD against base branch.
2. Identifies affected projects and their dependent projects.
3. Builds a dependency graph of all required tasks.
4. Installs toolchain and dependencies.
5. Runs actions in parallel via thread pool.
6. Reports pass/fail/cached stats.

### Parallelism

Split work across CI jobs using Moon's built-in partitioning:

```yaml
jobs:
  ci:
    strategy:
      matrix:
        index: [0, 1, 2, 3]
    steps:
      - uses: moonrepo/setup-toolchain@v2
      - run: moon ci --job-total 4 --job ${{ matrix.index }}
```

## Caching

Moon caches task outputs based on input hashing. If inputs have not changed, the task is skipped and results are restored from cache.

Inputs include:

- File contents (matched by `inputs` globs).
- Environment variables (configured per task).
- Tool versions from toolchain.
- Dependencies and lock files.

Remote caching uses a Bazel REAPI-compatible backend (moonbase or self-hosted). Evaluate whether shared cache complexity is justified for your team size.

## Single-Project Setup

For repos with one project, Moon still provides value: managed toolchain, strict schema validation, task runner, Git hooks, CI support.

```yaml
# $schema: https://moonrepo.dev/schemas/workspace.json
# .moon/workspace.yml
projects:
  - "."

vcs:
  manager: "git"
  defaultBranch: "main"
  hooks:
    pre-push:
      - "moon run root:lint --affected"
      - "moon run root:fmt-check --affected"
      - "moon run root:test --affected-or-all"
      - "moon run root:typecheck --affected"
```

```yaml
# $schema: https://moonrepo.dev/schemas/project.json
# moon.yml (project root)
type: "application"
language: "rust"

tasks:
  lint:
    command: "cargo clippy -- -D warnings"
  test:
    command: "cargo test"
  build:
    command: "cargo build --release"
    deps: ["~:lint", "~:test"]
```

Run tasks with `moon run root:build` or `moon run :build` (shorthand when unambiguous).

## Growing into a Monorepo

When a single-project repo grows to multiple projects, Moon scales without changing the task model:

1. Add project directories to `workspace.yml`.
2. Move shared tasks into `.moon/tasks/`.
3. Add cross-project deps where needed.

No migration of task syntax, CI config, or hook setup required.

## Anti-Patterns

| Smell                                         | Problem                                     | Instead                                        |
| --------------------------------------------- | ------------------------------------------- | ---------------------------------------------- |
| Omitting `$schema` in YAML headers            | Silent configuration drift and typos        | Add `$schema` headers to all configs           |
| Committing `*.json` schemas                   | Stale schemas causing validation mismatches | Use remote `https://moonrepo...` schemas       |
| Alias versions (`latest`, `lts`) in toolchain | Non-deterministic builds                    | Pin full semver (`22.12.0`)                    |
| Duplicate task definitions across projects    | DRY violation                               | Inherited tasks in `.moon/tasks/`              |
| Any pre-commit hooks that run tools           | Slows down frequent commits and experiments | Use only pre-push hook                         |
| Slow tasks in Git hooks                       | Blocks pushes                               | Fast lint/format/tests only; heavy tasks in CI |
| Integration tests in hooks                    | Long-running, flaky pushes                  | CI only (`moon ci`)                            |
| Manual tool installation docs                 | Drift across machines                       | Moon toolchain manages it                      |
| Separate Makefile/Justfile alongside Moon     | Two task models to maintain                 | Consolidate into Moon                          |
| Skipping `fetch-depth: 0` in CI checkout      | Inaccurate affected detection               | Always fetch full history for `moon ci`        |

## Checklist

- [ ] Files start with `$schema` comments for IDE validation
- [ ] Local JSON schemas are removed in favor of remote URLs
- [ ] `.moon/workspace.yml` configured with projects and VCS settings
- [ ] `.moon/toolchains.yml` pins all tool versions (full semver)
- [ ] Inherited tasks in `.moon/tasks/` for each language
- [ ] Project `moon.yml` overrides only where needed
- [ ] Templates defined for common project types (TS app, Rust lib, etc.)
- [ ] No Husky or lint-staged; Git hooks managed by Moon only
- [ ] No pre-commit hooks; pre-push hook runs lint/format/unit tests/typecheck
- [ ] Pre-push tasks filtered to affected projects (`--affected --upstream`)
- [ ] Each stack exposes `lint`, `typecheck`, `test`, and `verify` (`command: "noop"`, `runInCI: false`)
- [ ] Never use `:check` as a custom task name (collides with `moon check`; see ADR-0010)
- [ ] CI uses `moon ci` with affected-target detection
- [ ] CI checkout includes `fetch-depth: 0`
- [ ] `moonrepo/setup-toolchain` action in CI
- [ ] Task `inputs` defined for cache correctness
- [ ] Task `deps` express ordering, enabling parallel execution
- [ ] No duplicate task definitions across projects
- [ ] No tool version aliases in toolchain config

## Task Architecture and Reusability

To maintain a scalable, DRY monorepo, split your task definitions into two distinct tiers: **Implicit Workflows** and **Explicit Outcomes**.

### 1. Implicit Workflows (Global Task Inheritance)

The standard developer tasks (building, linting, testing, formatting) should be defined in `.moon/tasks/*.yml` files. Moon will automatically apply these tasks across the workspace using the `inheritedBy` attribute based on a project's `language` or `type`.

**Rule of Thumb:** If 90% of the projects of a certain language need the task, it belongs in global inheritance. Individual project `moon.yml` files should remain virtually empty for standard workflows.

### 2. Explicit Outcomes (Outcome-Based Partials)

Highly specialized, complex, or heavy pipelines (such as generating `.deb` files, publishing OCI containers, or pushing to `crates.io`) should not be globally inherited. Instead, isolate them in a `.moon/partials/` directory.

Design these partials around the **outcome** rather than the technical implementation (e.g., `publish-cli.yml` rather than `dist-oci.yml`).

Example `.moon/partials/publish-cli.yml`:

```yaml
tasks:
  release-native:
    command: "cargo dist build"
  release-system:
    command: "cargo packager --formats deb,rpm,msi"
    deps: ["release-native"]
  release-oci:
    command: "zbuild containerize"
    deps: ["release-system"]
  publish:
    command: "noop"
    deps:
      - "release-native"
      - "release-system"
      - "release-oci"
```

### 3. Generator Templates and `extends`

Do not use Tera's `{% include %}` syntax to inject partials directly into generated configurations. This hardcodes the tasks and breaks future maintainability.

Instead, your Tera templates should dynamically generate a `moon.yml` that uses Moon's native `extends` keyword. This allows the newly generated project to opt-in to the shared partial while retaining a single source of truth.

Example `.moon/templates/cli/moon.yml.tera`:

```yaml
language: "rust"
type: "application"
tags: ["cli"]

# Opt-in to the CLI publishing lifecycle
extends:
  - "../../.moon/partials/publish-cli.yml"

tasks: {}
```
