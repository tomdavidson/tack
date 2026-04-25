# @astro-bay/eslint-config-astro

ESLint flat config for `.astro` files. Treats Astro components as the **infrastructure/view layer** in a clean architecture, applying FP relaxations, structural complexity limits, unicorn, and node rules.

This config **only applies to `.astro` files**. It will not affect your `.ts`, `.js`, or any other files. The file patterns are `**/*.astro` for frontmatter and `**/*.astro/*.ts` / `**/*.astro/*.js` for client-side `<script>` tags (virtual paths created by `eslint-plugin-astro`).

## Philosophy

Astro files are the outermost shell. They connect HTTP requests to your pure domain/app layers and render responses. This config enforces:

- **Structural limits** (`max-depth: 3`, `complexity: 8`, `max-statements: 15`) to prevent sprawling frontmatter
- **FP relaxations** for the imperative shell: `try/catch` and `throw` are allowed (Astro uses `throw` for redirects and error pages)
- **Side-effect allowances**: `Astro.cookies`, `Astro.locals`, `Astro.response` mutations are expected
- **Declarative iteration** via unicorn: prefer `.find()`, `.some()`, `.flatMap()` over imperative loops
- **Architectural nudges**: warns when functions are defined inline or DB drivers are imported directly

## Install

```bash
pnpm add -D @astro-bay/eslint-config-astro eslint
```

`typescript-eslint` is bundled as a dependency (not a peer dep). No need to install it separately.

## Usage

### Standalone

```js
// eslint.config.mjs
import astroConfig from '@astro-bay/eslint-config-astro'
import { defineConfig } from 'eslint/config'

export default defineConfig(...astroConfig({ tsconfigRootDir: import.meta.dirname }))
```

Then run:

```bash
pnpm eslint '**/*.astro'
```

### Composed with @astro-bay/eslint-config

Place `astroConfig()` **after** `tsConfig()` so astro-specific rules take precedence over any oxlint dedup turn-offs:

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

### Rules only (bring your own parser/plugins)

```js
import { astroFrontmatterRules, structuralRules } from '@astro-bay/eslint-config-astro/rules'
```

## Options

| Option              | Type          | Default          | Description                                                  |
| ------------------- | ------------- | ---------------- | ------------------------------------------------------------ |
| `tsconfigRootDir`   | `string`      | -                | Root dir for tsconfig resolution (use `import.meta.dirname`) |
| `files`             | `string[]`    | `['**/*.astro']` | Additional file globs (merged with default)                  |
| `rules`             | `RulesRecord` | `{}`             | Override/extend frontmatter rules                            |
| `clientScriptRules` | `RulesRecord` | `{}`             | Override/extend client script rules                          |

## Rule Groups

All rule groups are individually importable from `@astro-bay/eslint-config-astro/rules`:

| Export                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `structuralRules`        | max-depth, complexity, max-params, no-else-return, no-nested-ternary, max-statements |
| `functionalRules`        | FP relaxations: no-let warn, try/throw/expression-statements off                     |
| `unicornRules`           | Declarative iteration, error quality, no-null, prefer-spread                         |
| `nodeRules`              | process.env allowed, module hygiene                                                  |
| `immutabilityRules`      | no-var error, prefer-const error                                                     |
| `hygieneRules`           | no-console, no-eval, eqeqeq, no-throw-literal                                        |
| `boundaryRules`          | Warns on inline function defs, bans direct DB/IO imports                             |
| `astroFrontmatterRules`  | All of the above composed                                                            |
| `astroClientScriptRules` | Client script variant (tighter statements, no boundary rules)                        |

## Dependencies

`astro-eslint-parser` is **not needed** as a separate dependency. It is a transitive dependency of `eslint-plugin-astro`, which this package includes.

`typescript-eslint` is a direct dependency of this package. It is imported internally to provide the TypeScript parser. pnpm will deduplicate it with `@astro-bay/eslint-config` if both are installed.

## License

MIT
