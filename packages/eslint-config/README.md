# @astro-bay/eslint-config

Shared ESLint flat config for TypeScript projects using clean architecture with functional
programming enforcement, architectural boundary rules, and oxlint deduplication.

## What it enforces

- **Functional programming** via `eslint-plugin-functional`: no classes, no let, no loops, no
  try/catch, immutable data, expression-only code
- **Architectural boundaries** via `eslint-plugin-boundaries`: domain cannot import infra, app
  cannot import infra, dependency inversion enforced
- **Arrow functions** via `eslint-plugin-prefer-arrow-functions`: all functions must be arrow
  expressions
- **AST selector bans**: boolean parameters, `_unsafeUnwrap()`, `_unsafeUnwrapErr()`
- **Oxlint deduplication** via `eslint-plugin-oxlint`: disables ESLint rules that oxlint already
  handles

## What it bundles

| Dependency                             | Purpose                                                       |
| -------------------------------------- | ------------------------------------------------------------- |
| `eslint-plugin-functional`             | FP rules (no-classes, no-let, no-throw, immutable-data, etc.) |
| `eslint-plugin-boundaries`             | Architectural layer enforcement                               |
| `eslint-plugin-prefer-arrow-functions` | Arrow function enforcement                                    |
| `eslint-plugin-oxlint`                 | ESLint/oxlint rule deduplication                              |
| `oxlint`                               | Fast Rust-based linter                                        |
| `oxlint-tsgolint`                      | Type-aware oxlint support                                     |

## Architecture

Three layers identified by file suffix, plus tests as a file type:

| Layer          | Suffix / Glob                                | Strictness                                                                                    |
| -------------- | -------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Domain         | `*.domain.ts`, `domain/**/*.ts`              | Strictest: pure functions, no IO imports, readonly types enforced                             |
| Application    | `*.app.ts`, `app/**/*.ts`                    | Default FP rules, boundary enforcement                                                        |
| Infrastructure | `*.infra.ts`, `infra/**/*.ts`, `cli/**/*.ts` | Relaxed: try/catch allowed, side effects allowed, classes with architectural suffixes allowed |
| Tests          | `*.spec.ts`, `*.test.ts`, `test/**/*.ts`     | All FP rules off                                                                              |

Dependency flow: Domain ← Application ← Infrastructure. Tests can import anything.

## Install

```bash
pnpm add -Dw @astro-bay/eslint-config eslint
```

## Usage

### ESLint config

```js
// eslint.config.mjs
import tsConfig from '@astro-bay/eslint-config'
import { defineConfig } from 'eslint/config'

export default defineConfig(...tsConfig({ tsconfigRootDir: import.meta.dirname }))
```

### With @astro-bay/eslint-config-astro

```js
// eslint.config.mjs
import tsConfig from '@astro-bay/eslint-config'
import astroConfig from '@astro-bay/eslint-config-astro'
import { defineConfig } from 'eslint/config'

export default defineConfig(
  ...tsConfig({ tsconfigRootDir: import.meta.dirname }),
  ...astroConfig({ tsconfigRootDir: import.meta.dirname }),
)
```

### Editor oxlintrc.json

Editor plugins (VS Code oxlint extension, etc.) need an `oxlintrc.json` at the workspace root. Run
the bundled script to create or update it:

```bash
pnpm exec install-oxlintrc
```

This creates (or patches) a root `oxlintrc.json` that extends the bundled config:

```json
{
  "$schema": "./node_modules/oxlint/configuration_schema.json",
  "extends": ["./node_modules/@astro-bay/eslint-config/src/oxlintrc.json"]
}
```

The script is idempotent. It only touches `$schema` and `extends`, preserving any local overrides
you add.

## Options

```js
tsConfig({
  // Required
  tsconfigRootDir: import.meta.dirname,

  // Optional
  oxlintConfig: '/custom/path/to/oxlintrc.json', // default: bundled oxlintrc.json
  files: ['src/**/*.ts'], // default: ['src/**/*.ts']
  ignores: ['generated/**'], // merged with node_modules, dist, eslint.config.mjs
  rules: { 'functional/no-let': 'warn' }, // override/extend global rules
})
```

## Exports

### Main (`@astro-bay/eslint-config`)

- `default` / `tsConfig` — config factory function
- `oxlintConfigPath` — absolute path to the bundled `oxlintrc.json`
- All re-exports from `./rules` and `./layers`

### Rules (`@astro-bay/eslint-config/rules`)

| Export               | Description                                                                 |
| -------------------- | --------------------------------------------------------------------------- |
| `functionalRules`    | Core FP rules (no-let, no-classes, no-throw, immutable-data, etc.)          |
| `arrowFunctionRules` | prefer-arrow-functions config                                               |
| `restrictedSyntax`   | AST selector bans (boolean params, unsafeUnwrap)                            |
| `domainRules`        | Domain layer overrides (banned IO imports, readonly enforced)               |
| `infraRules`         | Infrastructure relaxations (try/catch, side effects, classes with suffixes) |
| `testRules`          | Test relaxations (all FP rules off)                                         |

### Layers (`@astro-bay/eslint-config/layers`)

| Export                | Description                              |
| --------------------- | ---------------------------------------- |
| `domainFiles`         | Glob patterns for domain layer           |
| `appFiles`            | Glob patterns for application layer      |
| `infraFiles`          | Glob patterns for infrastructure layer   |
| `testFiles`           | Glob patterns for test files             |
| `frameworkInfraFiles` | Glob patterns for framework entry points |
| `boundaryElements`    | Boundary plugin element definitions      |
| `boundaryRules`       | Boundary plugin dependency rules         |

### Oxlint config (`@astro-bay/eslint-config/oxlintrc.json`)

Direct import of the canonical oxlint configuration. Useful for programmatic access.

## Layer rule summary

| Rule                                  | Domain | App   | Infra                         | Tests |
| ------------------------------------- | ------ | ----- | ----------------------------- | ----- |
| `functional/no-let`                   | error  | error | warn                          | off   |
| `functional/no-classes`               | error  | error | error (with suffix allowlist) | off   |
| `functional/no-try-statements`        | error  | error | off                           | off   |
| `functional/no-throw-statements`      | error  | error | off                           | off   |
| `functional/no-expression-statements` | error  | error | off                           | off   |
| `functional/no-return-void`           | error  | error | off                           | off   |
| `functional/immutable-data`           | warn   | warn  | off                           | off   |
| `functional/prefer-readonly-type`     | error  | warn  | warn                          | off   |
| `no-restricted-imports` (IO ban)      | error  | —     | —                             | —     |
| `no-restricted-syntax`                | error  | error | error                         | off   |
| `boundaries/element-types`            | error  | error | error                         | error |
