# Web App Testing

Extends [TypeScript Testing](./testing-typescript.md). Do not duplicate patterns defined there. This document covers testing concerns specific to web applications: framework-rendered components, browser behavior, network-dependent rendering, and the conservative escalation from fast pure-function tests to slow browser-based tests.

## Core Principle: Extract, Don't Exercise

The more logic extracted from `.astro` pages, JSX components, and framework templates into pure functions, the more code stays testable at Layer 1 speed. Templates should be thin shells that call pure functions and render their output.

BAD: Test pagination logic by rendering a full Astro page and counting links.
GOOD: Extract paginate(items, pageSize, currentPage) into a .domain.ts file.
Layer 1 tests the pure function. Layer 2 tests the component calls it correctly.

A component test should verify that the component _wires_ domain logic to markup correctly, not re-verify the domain logic itself. If a test requires complex setup to exercise a component, that complexity likely belongs in extracted functions tested at Layer 1.

## Tools

All tools from [TypeScript Testing](./testing-typescript.md) apply. This table covers web-app-specific additions only.

| Purpose                       | Tool                              | Layer   |
| ----------------------------- | --------------------------------- | ------- |
| Component HTML assertions     | Vitest + Astro Container API      | 2       |
| Component browser rendering   | `@vitest/browser-playwright`      | 2       |
| Network interception (Node)   | MSW `setupServer`                 | 2       |
| Schema-derived arbitraries    | `zod-fast-check` (Astro uses Zod) | 1, 2    |
| Static type checking (.astro) | `astro check`                     | CI gate |
| Full-app browser behavior     | Playwright                        | 3       |

### Rejected Tools

**`@testing-library/*`**: Playwright's locator API (`getByRole`, `getByLabel`, `getByText`) provides the same accessible, user-centric querying. `@vitest/browser-playwright` uses Playwright locators directly. Testing-library occupies a jsdom middle ground that this stack skips entirely. Every layer uses either raw HTML strings or a real browser.

## Component Testing: Vitest + Astro Container API

The Astro Container API renders `.astro` components to HTML strings in Node.js without a browser. It is currently experimental (`experimental_AstroContainer`). Use it at Layer 2 to verify component markup contracts.

### What to Test

- Props produce expected HTML structure and text content.
- Slot content renders in the correct location.
- Conditional rendering (e.g., draft badge hidden when `draft: false`).
- CSS class hooks (namespaced classes like `ch-card`, `ch-card__title`) are present.
- `class` prop forwarding to the root element.

### What Not to Test

- Styles (produces HTML strings, not rendered pixels).
- Client-side interactivity (islands, event handlers, hydration).
- Virtual module resolution (Container API does not resolve Vite virtual modules).
- Domain logic already covered by Layer 1 tests.

### Pattern

```typescript
// src/tests/components.spec.ts — Layer 2
// @vitest-environment node
import { it } from '@fast-check/vitest'
import { experimental_AstroContainer as AstroContainer } from 'astro/container'
import { beforeAll, describe, expect } from 'vitest'
import ArticleCard from '../components/ArticleCard.astro'
import { buildEntry } from '../test/builders.ts'

let container: Awaited<ReturnType<typeof AstroContainer.create>>

beforeAll(async () => {
  container = await AstroContainer.create()
})

describe('ArticleCard', () => {
  it('should render title from entry prop', async () => {
    const entry = buildEntry({ title: 'How Courts Work' })
    const html = await container.renderToString(ArticleCard, { props: { entry } })
    expect(html).toContain('How Courts Work')
  })

  it('should omit date element when date is undefined', async () => {
    const entry = buildEntry({ date: undefined })
    const html = await container.renderToString(ArticleCard, { props: { entry } })
    expect(html).not.toContain('<time')
  })

  it('should render slot content in the footer', async () => {
    const entry = buildEntry()
    const html = await container.renderToString(ArticleCard, {
      props: { entry },
      slots: { footer: '<p class="custom-footer">More info</p>' },
    })
    expect(html).toContain('custom-footer')
  })

  it('should preserve ch-card class hook on root element', async () => {
    const entry = buildEntry()
    const html = await container.renderToString(ArticleCard, { props: { entry } })
    expect(html).toContain('ch-card')
  })
})
```

### Framework Islands (React, Svelte, Vue, Solid)

Pass `renderers` to the container for island SSR output:

```typescript
import react from '@astrojs/react/server.js'

const container = await AstroContainer.create({
  renderers: [{ name: '@astrojs/react', ssr: react }],
})
```

This renders SSR HTML only. It does **not** hydrate the component. Client-side behavior cannot be tested here.

### Virtual Module Stubbing

Components that import virtual modules (e.g., `import config from 'my-plugin/config'`) will fail because Vite's virtual module resolution is not active. Stub via Vitest aliasing:

```typescript
// vitest.config.ts
export default defineConfig({
  test: { alias: { 'my-plugin/config': './src/test/stubs/config.ts' } },
})
```

Testing that the real virtual module wires correctly belongs at Layer 3.

## Component Browser Testing: @vitest/browser-playwright

When the Container API cannot cover the test, `@vitest/browser-playwright` renders a single component in a real browser via Vitest's Browser Mode. Heavier than Container API, lighter than full Playwright E2E.

### When to Use

- Real DOM interaction (focus management, scroll, resize observers).
- Screenshot regression for Design System components.
- `client:only` components (zero SSR HTML, cannot use Container API).

### When Not to Use

- Component HTML structure (Container API sufficient).
- Domain logic (Layer 1).
- Full-app routing, navigation, build artifacts (Layer 3 Playwright).

### Pattern

```typescript
// src/tests/counter.browser.spec.ts — Layer 2 (browser)
import { describe, expect } from 'vitest'
import { render } from 'vitest-browser-react'
import Counter from '../components/Counter'

describe('Counter', () => {
  it('should increment count on click', async () => {
    const screen = render(<Counter initial={0} />)
    await screen.getByRole('button', { name: 'Increment' }).click()
    await expect.element(screen.getByText('1')).toBeVisible()
  })
})
```

Uses Playwright's locator API directly. No `@testing-library/*` needed.

## MSW: When Typed Fakes Cannot Reach

MSW (`setupServer`) intercepts HTTP at the Node.js network layer. Runs at Layer 2 speed inside Vitest. See [TypeScript Testing](./testing-typescript.md) for the Typed Fakes pattern that MSW replaces only when injection is impossible.

### When to Use MSW

- `.astro` component frontmatter that calls `fetch()` to an external API.
- Framework island components that fetch data during SSR.
- Middleware or API endpoints that proxy to external services.

### When Not to Use MSW

- Domain logic (Typed Fakes).
- Application orchestrators (Typed Fakes with dependency injection).
- Anything where a function parameter could accept a fake.
- Components that do not call `fetch()`.

### Pattern

```typescript
// src/tests/api-components.spec.ts — Layer 2
// @vitest-environment node
import { experimental_AstroContainer as AstroContainer } from 'astro/container'
import { http, HttpResponse } from 'msw'
import { setupServer } from 'msw/node'
import { afterAll, afterEach, beforeAll, describe, expect } from 'vitest'
import WeatherWidget from '../components/WeatherWidget.astro'

const server = setupServer()

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => server.resetHandlers())
afterAll(() => server.close())

describe('WeatherWidget', () => {
  it('should render temperature from API response', async () => {
    server.use(
      http.get('https://api.weather.example/current', () =>
        HttpResponse.json({ temp: 72, unit: 'F' })),
    )
    const container = await AstroContainer.create()
    const html = await container.renderToString(WeatherWidget, { props: { city: 'Lindon' } })
    expect(html).toContain('72')
    expect(html).toContain('°F')
  })

  it('should render fallback on API error', async () => {
    server.use(http.get('https://api.weather.example/current', () => HttpResponse.error()))
    const container = await AstroContainer.create()
    const html = await container.renderToString(WeatherWidget, { props: { city: 'Lindon' } })
    expect(html).toContain('Weather unavailable')
  })
})
```

### Fuzzing MSW Responses

Instead of hardcoding mock responses, use fast-check arbitraries (see [TypeScript Testing](./testing-typescript.md)) to fuzz-test component resilience to unexpected data:

```typescript
import { fc, it } from '@fast-check/vitest'
import { describe, expect } from 'vitest'

const weatherResponseArb = fc.record({
  temp: fc.integer({ min: -60, max: 140 }),
  unit: fc.constantFrom('F', 'C'),
})

describe('WeatherWidget', () => {
  it.prop([weatherResponseArb])('should never crash on valid API shapes', async data => {
    server.use(http.get('https://api.weather.example/current', () => HttpResponse.json(data)))
    const container = await AstroContainer.create()
    const html = await container.renderToString(WeatherWidget, { props: { city: 'test' } })
    expect(html).toContain('<div')
  })
})
```

## Playwright: Conservative, Last-Resort Browser Testing

Playwright tests are slow, expensive, and test too much surface area. Use them exclusively for behavior that **cannot** be verified without a full application running in a real browser.

### Exclusively Playwright

1. **Client-side hydration.** Verifying that `client:load`, `client:visible`, `client:idle` islands activate and respond to user interaction.
2. **Hydration error detection.** Catching React/Vue/Svelte hydration mismatches via console listeners.
3. **Route injection and navigation.** Confirming that injected routes return 200, pagination links navigate correctly, and 404s fire for invalid routes.
4. **View Transitions.** Verifying page transitions, `<head>` updates, and history behavior.
5. **Virtual module wiring.** Confirming that data passed through a real Vite virtual module appears in the rendered page output.
6. **Build artifact verification.** Asserting that `astro build` produces expected files (RSS, sitemaps, JSON manifests) in `dist/`.

### Never Playwright

- Domain logic (Layer 1).
- Component HTML structure (Layer 2, Container API).
- Component DOM interaction (Layer 2, `@vitest/browser-playwright`).
- API response handling (Layer 2, MSW).

### Fixture Projects

Playwright tests run against minimal fixture Astro projects that consume the plugin or app under test.

test/
fixtures/
basic-site/
astro.config.mjs # imports your plugin
src/content/ # minimal test content
ssr-site/
astro.config.mjs # SSR mode fixture
e2e/
routes.spec.ts
hydration.spec.ts
base.ts # shared fixtures (hydration error detection)

text

### Playwright Config

```typescript
// playwright.config.ts
import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './test/e2e',
  webServer: {
    command:
      'pnpm astro build --root test/fixtures/basic-site && pnpm astro preview --root test/fixtures/basic-site',
    port: 4321,
    reuseExistingServer: !process.env.CI,
  },
  use: { baseURL: 'http://localhost:4321' },
})
```

### Network Mocking in Playwright

- **Simple, one-off mocks:** `page.route()`. No extra dependencies.
- **Complex API contracts already defined in MSW handlers:** Reuse MSW via `playwright-msw` adapter.

### Hydration Error Detection

Extend Playwright's `test` fixture to catch framework hydration mismatches.

```typescript
// test/e2e/base.ts
import { type ConsoleMessage, expect, test as base } from '@playwright/test'

const HYDRATION_PATTERNS = [
  /hydration failed/i,
  /hydration mismatch/i,
  /hydration completed but contains mismatches/i,
]

export const test = base.extend<{ hydrationErrors: string[] }>({
  hydrationErrors: async ({ page }, use) => {
    const errors: string[] = []
    page.on('console', (msg: ConsoleMessage) => {
      const text = msg.text()
      if (HYDRATION_PATTERNS.some(p => p.test(text))) errors.push(text)
    })
    await use(errors)
  },
})

export { expect }
```

```typescript
// test/e2e/hydration.spec.ts
import { expect, test } from './base.ts'

test.describe('ReactCounter island', () => {
  test('should hydrate and respond to clicks without errors', async ({ page, hydrationErrors }) => {
    await page.goto('/page-with-react-island')
    await page.getByRole('button', { name: 'Increment' }).click()
    await expect(page.getByText('1')).toBeVisible()
    expect(hydrationErrors).toEqual([])
  })
})
```

### Workflow

Playwright runs in a separate CI job, never in TDD watch mode.

```jsonc
// package.json
{
  "scripts": {
    "test": "vitest run",
    "test:tdd": "TDD=1 vitest",
    "test:e2e": "playwright test",
    "test:types": "astro check && tsc --noEmit"
  }
}
```

## Astro-Specific Concerns

### Content Collections API

Astro's Content Collections (`getCollection`, `getEntry`) provide typed, validated data from local files.

- **Layer 1:** Extract all content transformation logic into pure `.domain.ts` functions that accept plain arrays. The functions never import `astro:content`.
- **Layer 2:** Use the Container API with builder-generated props matching the collection schema shape. Do not call `getCollection` in the test.
- **Layer 3:** The fixture project's `src/content/` directory contains real files. `astro build` exercises the full content pipeline. Playwright asserts on built output. This is the only layer that exercises `getCollection` end-to-end.

When Content Collections use Zod schemas, derive arbitraries with `zod-fast-check` per [TypeScript Testing](./testing-typescript.md):

```typescript
import { ZodFastCheck } from 'zod-fast-check'
import { entrySchema } from '../schema.ts'

export const entryArb = ZodFastCheck.inputOf(entrySchema)
```

### Islands (Client Directives)

| Directive        | Container API (Layer 2)  | @vitest/browser-playwright (Layer 2) | Playwright E2E (Layer 3)            |
| ---------------- | ------------------------ | ------------------------------------ | ----------------------------------- |
| `client:load`    | Renders SSR HTML only    | Renders + hydrates                   | Full app context                    |
| `client:visible` | Renders SSR HTML only    | Cannot trigger scroll context        | Verifies scroll-triggered hydration |
| `client:idle`    | Renders SSR HTML only    | Cannot trigger idle context          | Verifies idle-triggered hydration   |
| `client:only`    | Renders nothing (no SSR) | Renders + hydrates (isolated)        | Full app context                    |
| No directive     | Renders full static HTML | Not needed                           | Not needed                          |

`client:visible` and `client:idle` depend on full-page context that isolated rendering cannot provide. These are Playwright-exclusive.

### `astro check`

Runs the Astro compiler's type checker across `.astro` files. Catches type errors in component props, slot usage, and template expressions that `tsc --noEmit` cannot reach. Run as a CI gate, not in TDD watch mode.

```yaml
# CI pipeline
- run: pnpm astro check
- run: pnpm tsc --noEmit
- run: pnpm test
- run: pnpm test:e2e
```

### `astro:env` and Environment Variables

- **Layer 1:** Functions accept config as a parameter, never import `astro:env` directly.
- **Layer 2:** Stub `astro:env` via Vitest's `alias` config.
- **Layer 3:** Set real environment variables in the fixture project's `.env` file or via Playwright's `webServer.env`.

### Astro Actions

Extract the action's business logic into pure functions tested at Layer 1. The Action handler becomes a thin shell: parse input, call pure function, return response. Test wiring at Layer 3 by posting to the action endpoint from Playwright.

## Escalation Hierarchy

Never use a heavier tool when a lighter one suffices. Each level down is an order of magnitude slower.

Layer 1: Pure functions (Vitest, colocated .spec.ts)
↓ only if component wiring needs verification
Layer 2: Astro Container API (Vitest, no browser, HTML string assertions)
↓ only if component calls fetch() and cannot inject a fake
Layer 2: Astro Container API + MSW (Vitest, no browser)
↓ only if real DOM interaction or visual regression needed
Layer 2: @vitest/browser-playwright (Vitest, real browser, single component)
↓ only if full app context required (routing, hydration triggers, build artifacts)
Layer 3: Playwright E2E (headless Chromium, full application)

text

At every level, ask: can this be tested one level up? If yes, move it up.

## Anti-Patterns

| Don't                                                    | Do Instead                                                         |
| -------------------------------------------------------- | ------------------------------------------------------------------ |
| Test pagination math by rendering a full page            | Extract `paginate()` pure function, test at Layer 1                |
| Use Playwright to check if a component renders a title   | Container API at Layer 2                                           |
| Use MSW when the function accepts a dependency parameter | Typed Fake                                                         |
| Use Playwright to test API error handling                | MSW + Container API at Layer 2                                     |
| Hand-roll `fc.record()` when Zod schema exists           | `zod-fast-check` derives arbitraries from the schema               |
| Test domain logic through a component                    | Extract to `.domain.ts`, test at Layer 1                           |
| Run Playwright in TDD watch mode                         | Separate CI job only                                               |
| Skip `astro check` because `tsc` passes                  | Run both: `tsc` for `.ts`, `astro check` for `.astro`              |
| Test `client:visible` with isolated component rendering  | Playwright only (requires scroll context)                          |
| Mock `getCollection` in unit tests                       | Pass collection data as function params, test pure functions       |
| Use `@testing-library/*`                                 | Playwright locators via `@vitest/browser-playwright` or Playwright |

## Checklist

- [ ] Domain logic extracted from templates into `.domain.ts` / `.app.ts` files
- [ ] Layer 1 tests in colocated `.spec.ts` files cover all pure functions
- [ ] Container API tests verify component markup contracts (Layer 2)
- [ ] `// @vitest-environment node` set on Container API test files
- [ ] Virtual modules stubbed via Vitest `alias` in Layer 2
- [ ] MSW used only for components with hardcoded `fetch()` calls
- [ ] `onUnhandledRequest: 'error'` set on MSW server
- [ ] `zod-fast-check` used when Zod schemas exist (Content Collections)
- [ ] `@vitest/browser-playwright` used for DOM interaction and visual regression
- [ ] Playwright reserved for full-app concerns (hydration, routing, view transitions, build artifacts)
- [ ] Playwright tests use fixture projects
- [ ] Hydration error detection enabled in Playwright base fixture
- [ ] `astro check` runs in CI alongside `tsc --noEmit`
- [ ] `test:e2e` script separate from `test` script
- [ ] No Playwright in TDD watch mode
- [ ] Escalation hierarchy followed at every test decision
