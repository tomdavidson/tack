---
date: 2026-09-27
status: proposed
tags:
  - moon
  - tasks
  - packages
  - devex
---

# 0008. Moon task organization: canonical names, folder per package, file per scope

## Status

Proposed.

Relates to [0002 Consumption model and dispatch](0002-consumption-model-and-dispatch.md) (how packages deliver files via `path_prefix` and `files.<src>.target`).

## Scope

This ADR sets the convention for all tack packages. It is applied first to the Drupal package in PR #22 only.

Other packages (Rust, JavaScript/TypeScript, Astro, gh-pkg-npm) keep their current files in `.moon/tasks/` until they are migrated separately. Nothing in this ADR requires migrating them at the same time.

## Context

Tack delivers moon task files to consumers. Today every task file lives in the generic `.moon` package under `.moon/tasks/`, so every consumer receives all of them, including `drupal-site.yml` and `drupal-module.yml`.

Three problems follow for Drupal.

1. **Leakage.** A consumer that isn't using Drupal receives the Drupal task files. PR #22 already fixed one instance of this by moving `localgov-microsite.yml` out of `.moon/tasks/` and into the localgov-multisite package.

2. **Duplication and drift.** `drupal-site.yml` and `drupal-module.yml` define the same tasks (`lint`, `lint-fix`, `analyse`, `test-unit`, `test-integration`, `test-e2e`, `test`) with different paths. When the port-state-file fix landed in `drupal-site.yml` (commit 191080d), `drupal-module.yml` did not get it. Module `test-integration` and `test-e2e` still call `devenv tasks run drupal:deploy` inline and rely on the static `SIMPLETEST_BASE_URL`. Module integration tests also run the site-wide `--testsuite=kernel` instead of being scoped to the module.

3. **Tag-only inheritance.** Every file is selected by tag. Site vs module is expressed as two tags (`drupal-site`, `drupal-module`), even though moon already records that difference as a project `layer`.

### Moon v2 inheritance

Moon v2 selects task files through an `inheritedBy` map inside each file. File names and folder layout under `.moon/tasks/**/*` no longer affect inheritance.

- One file has one `inheritedBy` map.
- Different condition keys (`files`, `languages`, `layers`, `stacks`, `tags`, `toolchains`) are ANDed.
- The values listed under one key are ORed.
- `tags` and `toolchains` also accept `and`, `or` and `not`.
- A project inherits from every file that matches it, so tasks from several files add up.
- If a project-level fileGroup has the same name as an inherited one, the project's version overrides it.

### Merging tasks with the same name

When the same task name is defined in more than one place, moon merges the definitions. It builds each task in this order:

1. global tasks from `.moon/tasks/**`
2. tasks pulled in through `extends`
3. local tasks in the project's `moon.yml`

Six list and map fields (`args`, `deps`, `env`, `inputs`, `outputs`, `toolchains`) are merged by a strategy set in the task's own options:

- `merge` sets the strategy for all of them at once.
- `mergeArgs`, `mergeDeps`, `mergeEnv`, `mergeInputs`, `mergeOutputs` and `mergeToolchains` set it per field.
- Each option takes `append`, `prepend`, `replace` or `preserve`.

How two definitions combine is therefore set by the tasks themselves, not by fixed rules.

A project's `moon.yml` controls what it inherits with `inheritedTasks`:

- `include`: inherit only these tasks
- `exclude`: skip these tasks
- `rename`: inherit a task under a different local name

### Naming collision

Tack calls `localgov-multisite` a "stack", as in `configs/drupal/stacks/` and `vars.drupal.stack`. In moon, `stack` is a fixed project category (frontend, backend, infrastructure, systems, data).

## Decision

### 1. Canonical task vocabulary

Every package uses the same task names with the same meaning, whatever the language or framework. `moon run :test-e2e` does the same kind of thing for a Drupal module, a Drupal site, a crate or an Astro site.

| Task | Meaning | Services | Cache | `runInCI` |
|---|---|---|---|---|
| `lint` | Static style and lint checks, read-only | none | yes | yes |
| `lint-fix` | Auto-fix what `lint` reports | none | no | no |
| `format` | Apply the formatter, where it is separate from lint | none | no | no |
| `analyse` | Static analysis and type checks (phpstan, tsc, clippy) | none | yes | yes |
| `test-unit` | Fast tests with no external services | none | yes | yes |
| `test-integration` | Tests that need backing services (DB, cache) | required | no | yes |
| `test-e2e` | Full stack or browser tests against a running app | required | no | yes |
| `test` | Umbrella: the full test suite a package defines for CI | as needed | no | yes |
| `build` | Produce artifacts | none | yes | yes |
| `deploy` | Apply code/config to a running environment | required | no | no (local) |

Rules:

- A package may leave out a task that doesn't apply to it. It may not reuse a canonical name for a different meaning.
- Lifecycle tasks specific to a package (for example Drupal's `services-up`, `test-prepare`, `reset`) use plain, descriptive names and are documented next to the task file that defines them.
- Tool binaries are called through the project-local path (`$workspaceRoot/vendor/bin/...`, `node_modules/.bin/...`) rather than whatever is first on `PATH`.

### 2. Folder per package, file per scope

Task files live under `.moon/tasks/<package>/<scope>.yml`.

- **`<package>`** is the tack package that owns the file and its tools. A package delivers only into its own folder, which prevents leakage by construction: a consumer that doesn't include `configs/drupal` never receives `.moon/tasks/drupal/`.
- **`<scope>`** says who the tasks are for, for example `all`, `app`, `module` or `microsite`. How moon matches those projects is written in the file's `inheritedBy` map, not in its name.
- A variant of a package (see decision 5) nests under its parent: `.moon/tasks/<package>/<variant>/<scope>.yml`.

Inside a package, the source layout mirrors the target path wherever the package's `path_prefix` allows. Where it doesn't, a `files.<src>.target` override sends the file to `.moon/tasks/<package>/...`. This follows the existing pattern in the localgov-multisite `tack.yml`.

### 3. Match each concern with the matching moon condition

| Concern | `inheritedBy` condition | Example |
|---|---|---|
| Framework | `tags` | `.moon/tasks/drupal/all.yml` → `tags: ['drupal']` |
| Application vs library | `tags` + `layers` | `.moon/tasks/drupal/app.yml` → `tags: ['drupal']`, `layers: ['application']` |
| Package variant | `tags` | `.moon/tasks/drupal/localgov-multisite/microsite.yml` → `tags: ['localgov-microsite']` |
| Language or toolchain tools | `languages` / `toolchains` | future: `.moon/tasks/rust/all.yml` → `toolchains: ['rust']` |
| Detectable by marker file | `files` | Only where no tag or toolchain would do |

Tack does not use moon's `stacks` condition. Moon's fixed categories (frontend, backend, ...) don't line up with tack's packages.

When a task definition differs by layout, the difference goes into the paths, not into a second copy of the task. Shared tasks read their paths from a named fileGroup such as `sources`. The file sets a default for the common layout, and a project's `moon.yml` overrides that fileGroup for its own layout.

### 4. Same-named tasks: one base definition, explicit merge strategy

A canonical task name may be defined in more than one matching file, or refined in a project's `moon.yml`. When that happens:

- **One base definition.** The broadest file for a package (for example `drupal/all.yml`) defines the task in full: command, args, inputs and options.
- **Refinements state their strategy.** A narrower file, or a project `moon.yml`, adds only what differs and sets `merge`, or the relevant `mergeArgs`, `mergeDeps`, `mergeEnv`, `mergeInputs`, `mergeOutputs` or `mergeToolchains`, explicitly. Nobody relies on the default strategy.
- **When to use each strategy:**
  - `append` adds deps or inputs, for example a module adding its own test fixtures to `inputs`.
  - `replace` changes the task outright, for example an app swapping `args`.
  - `preserve` keeps the inherited value and ignores the refinement.
- **Paths through fileGroups.** Where a refinement would only change paths, override the fileGroup instead of the task. That keeps the task definition in one place.
- **Opting out.** Projects use `inheritedTasks.exclude` rather than redefining a task as a no-op.

### 5. Rename tack "stack" to "variant"

A variant is a specialisation of a package, for example LocalGov multisite as a variant of Drupal. Because only the Drupal package uses stacks today, this rename happens in PR #22.

| Before | After |
|---|---|
| `configs/drupal/stacks/` | `configs/drupal/variants/` |
| `configs/drupal/stacks/localgov-multisite.nix` | `configs/drupal/variants/localgov-multisite.nix` |
| `vars.drupal.stack` | `vars.drupal.variant` |
| `configs/drupal/stacks/README.md` | `configs/drupal/variants/README.md` |

### 6. Project templates carry project facts, not tasks

Tack seeds (`overwrite: false`) a `moon.yml` template for each project shape a package supports. A template sets:

- `tags`
- `layer`
- fileGroup overrides such as `sources`
- `inheritedTasks` include, exclude or rename lists

It does not redefine inherited tasks, except for small refinements that follow decision 4. That way tack keeps updating the tasks themselves in the tack-owned files under `.moon/tasks/<package>/`, and a consumer who edits a seeded `moon.yml` still receives task fixes.

## Drupal application (PR #22)

### Target layout

```text
.moon/tasks/
  drupal/
    all.yml                              # tags: [drupal]
    app.yml                              # tags: [drupal], layers: [application]
    localgov-multisite/
      microsite.yml                      # tags: [localgov-microsite]
```

Project templates delivered by the Drupal package:

| Template | Delivered by | Sets |
|---|---|---|
| Drupal app `moon.yml` | `configs/drupal` | `tags: [drupal, drupal-app]`, `layer: application`, `sources` → `web/modules/custom/**`, `web/themes/custom/**` |
| Drupal module `moon.yml` | `configs/drupal` | `tags: [drupal]`, `layer: library` (uses the default `sources`: `src/**`) |
| LocalGov app `moon.yml` | `variants/localgov-multisite` | the Drupal app facts, plus any LocalGov-specific fileGroups |
| Microsite `moon.yml` (placeholder) | `variants/localgov-multisite` | `tags: [localgov-microsite]`. The microsite design isn't settled yet |

### `drupal/all.yml`

This file holds the canonical tasks shared by sites and modules. Its paths default to the module layout.

```yaml
inheritedBy:
  tags: ['drupal']

fileGroups:
  sources: ['src/**/*']                  # app moon.yml overrides
  tests: ['tests/**/*']
  configs:
    - '/phpcs.xml.dist'
    - '/phpstan.neon.dist'
    - '/phpunit.xml.dist'
    - '/composer.json'
    - '/composer.lock'

tasks:
  lint:
    command: '$workspaceRoot/vendor/bin/phpcs'
    args: ['@dirs(sources)', '--standard=$workspaceRoot/phpcs.xml.dist']
    inputs: ['@group(sources)', '@group(configs)']
  lint-fix:
    command: '$workspaceRoot/vendor/bin/phpcbf'
    args: ['@dirs(sources)', '--standard=$workspaceRoot/phpcs.xml.dist']
    options: { cache: false, runInCI: false }
  analyse:
    command: '$workspaceRoot/vendor/bin/phpstan'
    args: ['analyse', '@dirs(sources)', '-c', '$workspaceRoot/phpstan.neon.dist']
  test-unit:
    # phpunit --testsuite=unit, scoped to $projectRoot
  test-integration:
    # deps: ['#drupal-app:test-prepare']; scoped to $projectRoot
  test-e2e:
    # deps: ['#drupal-app:test-prepare']; scoped to $projectRoot
  test:
    # devenv test
```

### `drupal/app.yml`

This file holds the lifecycle tasks that only the Drupal application has:

```yaml
inheritedBy:
  tags: ['drupal']
  layers: ['application']

tasks:
  services-up:  # devenv up --detach
  test-prepare: # read $DEVENV_STATE/web.port; install if absent, else deploy
  deploy:       # scripts/drupal/deploy.sh
  reset:        # scripts/drupal/install.sh --force
```

Module integration and e2e tests depend on the application's `test-prepare`. There is then one site and one piece of port-file logic, and the drift described in the Context section can't recur.

### Changes in PR #22

| Current | Target |
|---|---|
| `.moon/tasks/drupal-site.yml` | `.moon/tasks/drupal/all.yml` + `.moon/tasks/drupal/app.yml` (source in `configs/drupal`) |
| `.moon/tasks/drupal-module.yml` | merged into `.moon/tasks/drupal/all.yml` |
| localgov-multisite `localgov-microsite.yml` → `.moon/tasks/localgov-microsite.yml` | `.moon/tasks/drupal/localgov-multisite/microsite.yml` |
| `configs/drupal/stacks/**` | `configs/drupal/variants/**` |
| `vars.drupal.stack` | `vars.drupal.variant` |

Tag changes for consumers:

- Sites: `drupal-site` → `drupal` + `drupal-app`, with `layer: application`.
- Modules: `drupal-module` → `drupal`, with `layer: library`.

## Consequences

### Positive

- Consumers who don't use Drupal no longer receive Drupal task files.
- Each Drupal task is defined once, so the site and module versions can't drift apart.
- The same task names across project types keep the commands the same, both locally and in CI.
- The folder shows which package owns a file, and `inheritedBy` shows which projects get it. Neither depends on naming conventions.
- The site vs module split uses moon's `layer` instead of an extra tag.
- Whenever tasks with the same name meet, the merge strategy is written into the task, where a reviewer can see it.

### Negative

- It's a breaking change for Drupal consumers: they must update the tags in their `moon.yml`, and the variant rename changes the `devenv.nix` import path.
- There's a period where the layout is mixed: Drupal follows this ADR while the other packages still use flat files in `.moon/tasks/`.
- Paths inside task files are written through fileGroups and tokens, which is harder to read than literal paths.

## Alternatives considered

- **Keep tag-only inheritance with flat files (status quo).** Rejected: it doesn't fix leakage or drift.
- **Put the inheritance condition in the file name (`tag-drupal.yml`, `layer-application.yml`).** Rejected: this is moon v1's convention. It can't express combined conditions, and the name can fall out of sync with `inheritedBy`.
- **Flat files named by target (`drupal-app.yml`).** Readable, but it gives no package ownership boundary, so delivery can still leak.
- **A separate module file (`drupal/module.yml`).** Rejected: modules need nothing beyond `all.yml` once paths come from fileGroups.
- **Lifecycle tasks in the seeded app `moon.yml`.** Rejected: seeded files belong to the consumer, so tack could never update those tasks.

## Open questions

1. **Order between matching global files.** `append` and `prepend` depend on which definition counts as the parent. Confirm how moon v2 orders two matching `.moon/tasks/**` files, for example `drupal/all.yml` and `drupal/app.yml`, before either one refines a task from the other. Until that's confirmed, the files avoid defining the same task names.
2. **Tag targets in `deps`.** Confirm that `#drupal-app:test-prepare` works in moon v2.
3. **Tokens in `args`.** Confirm that `@dirs(sources)` works, and how it resolves for the app, which runs from the workspace root, versus modules, which run from their project root.
4. **PHP language package.** Should there eventually be a `.moon/tasks/php/all.yml` for PHP that isn't Drupal, with Drupal building on it? Deferred. It isn't needed for PR #22.
