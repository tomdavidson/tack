---
status: proposed
date: 2026-09-27
decision-makers: Tom Davidson
---

# Organize moon tasks by package and scope, with canonical task names

## Context and Problem Statement

Tack previously delivered moon task definitions from a generic `.moon` package, causing every consumer repository to inherit every task file regardless of relevance. Inheritance relied strictly on project tags, and site versus module tasks drifted across duplicate definitions. Furthermore, task names across toolchains lacked consistent semantics.

How should tack organize, scope, and deliver moon tasks across packages with a unified command vocabulary?

## Decision Drivers

* Consumers receive only task definitions for packages they actively include.
* A single canonical definition exists for each task within an owning package.
* Standardized task names share identical developer semantics across all tech stacks (for example, `moon run :test-e2e` or `moon run :dev`).
* Interactive foreground processes like `dev` eliminate extraneous lifecycle tasks (`start`, `stop`, `services-up`).
* Task options and inheritance leverage native moon v2 capabilities (`inheritedBy`, `order`, explicit `merge*`, presets).

## Considered Options

* Flat files in `.moon/tasks/` with tag-only inheritance (status quo)
* Condition-encoded filenames (`tag-drupal.yml`, `toolchain-rust.yml`)
* Flat files named by project target (`drupal-app.yml`, `drupal-module.yml`)
* Package-scoped directory hierarchy (`.moon/tasks/<package>/<scope>.yml`)

## Decision Outcome

Chosen option: "Package-scoped directory hierarchy", combined with a canonical task naming contract.

### 1. Canonical Task Vocabulary

Packages declare only tasks relevant to their domain. If declared, tasks must conform strictly to canonical names and behavior.

#### Core Tasks

| Task | Purpose | Execution & Cache |
|---|---|---|
| `format` | Validate code formatting without modification | Cached, runs in CI |
| `format-write` | Format code in place | Uncached, local only |
| `lint` | Execute linters, prose checks, and schema validation | Cached, runs in CI |
| `lint-fix` | Apply linter auto-fixes in place | Uncached, local only |
| `fix` | Run `format-write` then `lint-fix` sequentially (`runDepsInParallel: false`) | Uncached, local only |
| `typecheck` | Static analysis and type checking (`tsc`, `cargo check`, `phpstan`) | Cached, runs in CI |
| `audit` | Dependency vulnerability and security audits | Cached, `runInCI: always` |
| `test-unit` | Unit tests requiring no running services | Cached, runs in CI |
| `test-integration` | Tests requiring backing dependencies (database, storage) | Uncached, CI when services present |
| `test-e2e` | End-to-end browser or system tests against running platform | Uncached, CI when services present |
| `test` | Aggregate test runner executing all defined suites for the project | Uncached, local only |
| `build` | Compile release or distribution artifacts (`outputs` declared) | Cached, runs in CI |
| `dev` | Foreground development server or environment (`preset: server`) | Persistent, uncached, local only |
| `publish` | Publish artifacts to an upstream registry | Uncached, workflow-driven |
| `review` | Dry-run publish or snapshot preview artifact generation | Uncached, workflow-driven |

#### Optional Universal Tasks

* `fuzz`: Run local fuzzing harness (`fuzz-triage` for crash isolation).
* `build-release`: Produce optimized production binaries or assets.
* `generate`: Run code, schema, or binding generators.
* `bench`: Execute performance benchmarks.
* `clean`: Remove local build caches and generated artifacts.
* `preview`: Serve built distribution output locally (`preset: server`).
* `test-watch`: Run unit test suite in watch mode (`preset: watcher`).

#### Domain and Workflow-Specific Tasks

* **GitOps**: `plan` and `apply` for infrastructure and configuration state reconciliation.
* **Review Apps and Artifacts (RAA)**: Configured dynamically per project via `project.metadata.raa.run` and `raa.rm` (such as `publish-preview`, `review-app`).
* **Framework Lifecycle**: Specialized setup steps (such as Drupal's `test-prepare`, `deploy`, `reset`) run under their own descriptive names and avoid clashing with universal verbs.

### 2. Directory Layout and Scoping

Task configuration is delivered into package-scoped directories:

```text
.moon/tasks/<package>/<scope>.yml
```

* `<package>` matches the delivering tack package (e.g. `drupal`, `rust`).
* `<scope>` defines the target context (e.g. `all.yml`, `app.yml`, `library.yml`).
* Broad tasks (`all.yml`) apply before specialized ones (`app.yml`) via `order` weighting.

### 3. Inheritance and Tooling

* Toolchains and languages use `inheritedBy.toolchains` or `inheritedBy.languages`.
* Frameworks and stacks use `inheritedBy.tags`.
* Target archetypes combine tags with `inheritedBy.layers` (`application` vs `library`).
* Tool sub-tasks follow `<canonical>-<tool>` (such as `lint-es`, `lint-ox`); parent canonical tasks aggregate these sub-tasks.
* Paths are parameterized via `fileGroups` (`sources`, `tests`, `configs`) rather than duplicated task blocks.

### 4. Same-Named Tasks and Merging

When broader and narrower task files define identical task names, refinements declare explicit merge strategies (`mergeArgs`, `mergeDeps`, `mergeEnv`). Projects opt out of specific inherited tasks using `workspace.inheritedTasks.exclude`.

### 5. Project-Level Configuration

Seeded `moon.yml` files (marked `overwrite: false`) establish project metadata: tags, layers, `fileGroups` overrides, and task inclusion/exclusion. They never duplicate inherited task commands.

## Consequences

### Positive

* Elimination of task configuration leakage into unrelated consumer repositories.
* Consistent developer experience: commands like `moon run :dev`, `moon run :fix`, and `moon run :typecheck` behave predictably everywhere.
* Simplified lifecycle management: `dev` running in the foreground avoids split `start`, `stop`, and `services-up` scripts.
* Reliable sequential formatting via `fix` with `runDepsInParallel: false`.

### Negative

* Existing consumer projects must update tags and layers to align with `inheritedBy` queries.
* Tasks spanning multiple sub-linters require aggregation via file-scoped child tasks.

## Pros and Cons of the Options

### Flat files in `.moon/tasks/` with tag-only inheritance

* Good: No directory nesting.
* Bad: Leaks all definitions to every repository; requires redundant tags for intrinsic project attributes; causes drift across identical tasks.

### Condition-encoded filenames

* Good: Single filename indicates query rule.
* Bad: Incompatible with multi-condition matches; deviates from moon v2 conventions.

### Flat files named by project target

* Good: Clear file naming.
* Bad: Lacks namespace boundaries, causing package file collisions during tack synchronization.

### Package-scoped directory hierarchy

* Good: Clear ownership per tack package; prevents accidental cross-package file clobbering; cleanly supports `inheritedBy` composability.
* Bad: Requires directory path awareness in `tack.yml` configuration mapping.

## Appendix: Tasks Considered and Not Adopted

The following task names were evaluated during review and discarded, consolidated, or scoped out:

* `check` / `check-full`: Discarded. Clashes with native `moon check` command. CI execution is governed by `runInCI` and native `moon ci`.
* `verify`: Discarded. Redundant with `moon check` and core task definitions.
* `fmt` / `fmt-check`: Discarded in favor of standard moonrepo convention `format` (read-only check) and `format-write` (mutating).
* `analyse`: Consolidated into `typecheck` (for language/compiler typing and tools like phpstan) or nested under `lint` (for prose/schema linters).
* `check-types` / `check-type`: Standardized to `typecheck`.
* `docs`: Discarded as a standalone universal task. Documentation builds should be pre-requisite dependencies of project `build` or app tasks.
* `coverage`: Discarded as a separate task; supplied via argument/environment flag to `test-unit`.
* `start` / `stop`: Discarded. Foreground `dev` starts the interactive stack and Ctrl+C terminates it.
* `services-up`: Discarded as a universal task. Background services are started by framework setup tasks (e.g. `test-prepare`) or invoked directly via devenv/compose.
* `fuzz-ci`: Discarded. Handled by configuring `FUZZ_MAXTIME` on standard `fuzz`.
* `publish-preview` / `unpublish-preview`: Scoped out of universal list; defined via RAA metadata.
* `review-app` / `review-app-rm`: Scoped out of universal list; defined via RAA metadata.
* `validate-schema` / `validate-prose`: Scoped as linter sub-tasks (`lint-schema`, `lint-prose`).

## More Information

* Native `moon check` runs all build and test tasks across projects.
* Native `moon ci` automatically coordinates affected CI runs.
* First implemented for the Drupal package in PR #22.
