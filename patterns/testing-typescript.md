# TypeScript Testing

> TypeScript-specific patterns for [Testing](testing.md). See [Rust Testing](testing-rust.md) for the Rust equivalent.

## Tools

| Purpose       | Tool                                             | Notes                                     |
| ------------- | ------------------------------------------------ | ----------------------------------------- |
| Runner        | bun test / deno test / node --test               | Builtin. No config. Start here.           |
| Runner        | Vitest                                           | Watch filtering, coverage, `test.skipIf`. |
| Property      | `@fast-check/vitest` (preferred) or `fast-check` | Property-based and model-based testing.   |
| HTTP Contract | Pact                                             | Only when owning both sides.              |

## Progression: Builtin to Vitest

The pattern does not require Vitest. Small projects use the builtin runner (bun test, deno test, node --test) with co-located `.spec.ts` files and builtin assertions. Vitest enters when the project benefits from:

- Watch mode with smart rerun and file filtering
- Property test skip via `test.skipIf` for fast feedback loops
- Coverage reporting
- TypeScript transform (when not using bun or deno)

There is no strict threshold. If you find yourself wanting any of the above, add Vitest. If builtin assertions and separate spec files work, stay simple.

## Fast vs Slow Split

Use a `TDD` environment variable to skip slow tests in watch mode. Default (`vitest run`) runs everything. Only e2e and fuzz testing get a separate workflow.

The `TDD` env var is the cleanest mechanism. Bury it in `package.json` scripts so the ergonomics stay simple:

```jsonc
// package.json
{
  "scripts": {
    "test": "vitest run",
    "test:tdd": "TDD=1 vitest"
  }
}
```

| Mode        | Command            | What runs                            |
| ----------- | ------------------ | ------------------------------------ |
| Full        | `npm test`         | All: unit, property, integration     |
| TDD / Watch | `npm run test:tdd` | Fast tests only (slow tests skipped) |
| CI          | `npm test`         | Full suite                           |
| E2E         | separate workflow  | Playwright, etc.                     |
| Fuzz        | separate workflow  | Reserved                             |

Mark slow tests with `it.skipIf`:

```ts
const tdd = !!process.env.TDD

it.skipIf(tdd)('should roundtrip without losing data', () => {
  fc.assert(fc.property(moneyArb, m => parseMoney(serializeMoney(m))._unsafeUnwrap().equals(m)))
})
```

Fast tests use plain `it()` with no extra annotation. Fast tests never touch IO.

## Test Location and Layering

Tests co-locate with source. No `__tests__/` directories. See [Testing](testing.md) for the language-agnostic model.

Not every project needs formal layers. A small utility package may only have Layer 1 tests. A small service might skip Layer 2 and go straight from Layer 1 to Layer 3. Use layers when they clarify boundaries, not to satisfy a checklist.

### Layer 1: Co-located Unit Tests

Tests that exercise pure functions defined in a single source file. Use a co-located `.spec.ts` file next to the source.

A function that depends on an import from another file does not get Layer 1 tests. Layer 1 tests are self-contained: they pass regardless of what happens in other files. If an import changes, Layer 1 tests still pass because they never exercise cross-file behavior.

Private helper functions get direct, thorough testing. These are the atoms. Public functions that compose only same-file helpers are tested too, focusing on composition correctness without re-testing what helper tests already cover.

Property tests for pure functions live in the same `.spec.ts` file as the unit tests. Slow property tests get `it.skipIf(tdd)`. There are no separate property test files. Tests are organized by layer, not by test type.

Layer 1 applies to `.domain.ts` and `.app.ts` files that contain pure, self-contained logic.

### Layer 2: Directory / Feature Tests

Tests that span multiple files within the same directory or feature. If files are atoms, Layer 2 tests are molecules. Located in a `tests/` subdirectory within the feature, or a single `.spec.ts` file if the feature is small.

Only test exported functions. Avoid redundancy with Layer 1. Layer 2 tests verify cross-file composition that no single file's tests can cover. Each Layer 2 suite runs independently of other layer suites.

This is where `.app.ts` orchestration that imports from `.domain.ts` files gets tested. Layer 2 verifies that the wiring between files works. Property tests that span multiple modules in the same feature also live here.

### Layer 3: Cross-Feature / Integration Tests

Tests that span multiple features or the full application. Top-level `test/` directory. Contract tests against real implementations, integration tests with real deps, cross-feature property tests.

## File Naming

All tests use `.spec.ts`. Tests are organized by layer, not by test type. The `.spec.ts` suffix replaces the layer suffix, never stacks on it. The file stem makes the relationship clear:

| Source file         | Test file          |
| ------------------- | ------------------ |
| `money.domain.ts`   | `money.spec.ts`    |
| `pricing.app.ts`    | `pricing.spec.ts`  |
| `postgres.infra.ts` | `postgres.spec.ts` |

| Location                      | Contents                                           | Runs in TDD watch?         |
| ----------------------------- | -------------------------------------------------- | -------------------------- |
| `module.spec.ts` (co-located) | Layer 1 unit + property tests                      | Yes (slow via `it.skipIf`) |
| `feature/tests/*.spec.ts`     | Layer 2 cross-module + property tests              | Yes (slow via `it.skipIf`) |
| `test/*.spec.ts`              | Layer 3 integration + cross-feature property tests | Yes (slow via `it.skipIf`) |

No `.prop.spec.ts`, `.integration.spec.ts`, or other suffixes. A spec file contains all test types relevant to its layer scope. Slow tests within any file are individually skipped in TDD mode via `it.skipIf(tdd)`.

## Vitest Configuration

```ts
// vitest.config.ts
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    // no includeSource needed — all tests are in .spec.ts files
  },
})
```

## Layer 1 Example

```ts
// src/orders/money.domain.ts
export type Money = { cents: number }

export const fromCents = (n: number): Money => ({ cents: n })

export const add = (a: Money, b: Money): Money => fromCents(a.cents + b.cents)

export const serialize = (m: Money): string => String(m.cents)

export const parse = (s: string): Result<Money, ParseError> => {
  const n = Number(s)
  return Number.isInteger(n) ? ok(fromCents(n)) : err('invalid_format')
}
```

```ts
// src/orders/money.spec.ts
import { fc, it } from '@fast-check/vitest'
import { describe, expect } from 'vitest'
import { add, fromCents, parse, serialize } from './money.domain.ts'

const tdd = !!process.env.TDD

describe('fromCents', () => {
  it('should create Money from positive cents', () => {
    expect(fromCents(100)).toEqual({ cents: 100 })
  })
})

describe('add', () => {
  it('should sum two positive values correctly', () => {
    expect(add(fromCents(100), fromCents(200))).toEqual({ cents: 300 })
  })

  it.skipIf(tdd)('should be commutative', () => {
    fc.assert(
      fc.property(fc.integer(), fc.integer(), (a, b) =>
        add(fromCents(a), fromCents(b)).cents === add(fromCents(b), fromCents(a)).cents),
    )
  })
})

describe('parse', () => {
  it('should return Money for a valid integer string', () => {
    const result = parse('42')
    expect(result.isOk()).toBe(true)
    expect(result._unsafeUnwrap()).toEqual({ cents: 42 })
  })

  it('should return Err for non-numeric string', () => {
    expect(parse('abc').isErr()).toBe(true)
  })

  it.skipIf(tdd)('should roundtrip with serialize for any integer', () => {
    fc.assert(fc.property(fc.integer(), n => {
      const result = parse(serialize(fromCents(n)))
      return result.isOk() && result._unsafeUnwrap().cents === n
    }))
  })
})
```

## Builtin Runner Pattern

Without Vitest, co-locate a `.spec.ts` file next to the source. Use builtin assertions.

```ts
// src/orders/money.spec.ts
import { strict as assert } from 'node:assert'
import { describe, test } from 'node:test'
import { add, fromCents, parse } from './money.domain.ts'

describe('fromCents', () => {
  test('should create Money from positive cents', () => {
    assert.deepStrictEqual(fromCents(100), { cents: 100 })
  })
})

describe('add', () => {
  test('should sum two positive values correctly', () => {
    assert.deepStrictEqual(add(fromCents(100), fromCents(200)), { cents: 300 })
  })
})
```

## Result Assertions

Assert the rail before unwrapping. Works for `Result` and `ResultAsync` (just `await` first).

```ts
// test/helpers.ts
export const expectOk = <T, E>(result: Result<T, E>): T => {
  expect(result.isOk()).toBe(true)
  return result._unsafeUnwrap()
}

export const expectErr = <T, E>(result: Result<T, E>): E => {
  expect(result.isErr()).toBe(true)
  return result._unsafeUnwrapErr()
}
```

When using a builtin runner without `expect`:

```ts
import { strict as assert } from 'node:assert'

const assertOk = <T, E>(result: Result<T, E>): T => {
  assert.ok(result.isOk(), 'expected Ok, got Err')
  return result._unsafeUnwrap()
}
```

## Typed Fakes

Fakes satisfy the port interface. The compiler enforces the contract.

```ts
type OrderRepo = {
  save: (order: Order) => Promise<Result<void, RepoError>>
  findById: (id: OrderId) => Promise<Option<Order>>
}

const createFakeOrderRepo = (): OrderRepo => {
  const store = new Map<OrderId, Order>()
  return {
    save: async order => {
      store.set(order.id, order)
      return ok(undefined)
    },
    findById: async id => store.has(id) ? some(store.get(id)!) : none,
  }
}
```

## Contract Suite

```ts
export const orderRepoContract = (
  name: string,
  setup: () => Promise<{ repo: OrderRepo; teardown: () => Promise<void> }>,
) => {
  describe(`OrderRepo: ${name}`, () => {
    let repo: OrderRepo, teardown: () => Promise<void>
    beforeEach(async () => ({ repo, teardown } = await setup()))
    afterEach(async () => await teardown())

    it('should return saved entity on findById', async () => {
      const order = buildOrder()
      expectOk(await repo.save(order))
      expect((await repo.findById(order.id))._unsafeUnwrap()).toEqual(order)
    })

    it('should return none for missing id', async () => {
      expect((await repo.findById('nonexistent' as OrderId)).isNone()).toBe(true)
    })
  })
}

// Layer 2: fast, in-memory
orderRepoContract('Fake', async () => ({ repo: createFakeOrderRepo(), teardown: async () => {} }))

// Layer 3: slow, real DB
orderRepoContract(
  'Postgres',
  async () => ({
    repo: createPostgresOrderRepo(testDb),
    teardown: () => testDb.truncate('orders'),
  }),
)
```

## Property Testing (fast-check)

Property tests live alongside unit tests in the same `.spec.ts` file, organized by layer. Slow property tests get `it.skipIf(tdd)`. There are no separate property test files or workflows.

### @fast-check/vitest Integration

Prefer `@fast-check/vitest` over raw `fc.assert(fc.property(...))`. It provides two ergonomic improvements:

**`g()` helper** for filling unused fields with random data without a full property test:

```ts
import { fc, it } from '@fast-check/vitest'
import { describe, expect } from 'vitest'

describe('computeAge', () => {
  it('should always compute a non-negative age', ({ g }) => {
    vi.setSystemTime(g(fc.date, { min: new Date('2010-02-04'), noInvalidDate: true }))
    const user = { name: g(fc.string), birthday: '2010-02-03' }
    expect(computeAge(user)).toBeGreaterThanOrEqual(0)
  })
})
```

**`it.prop` syntax** for property tests that integrates into `describe`/`it`:

```ts
it.prop([fc.string(), fc.string(), fc.string()])(
  'should detect substring in concatenation',
  (a, b, c) => {
    expect(isSubstring(a + b + c, b)).toBe(true)
  },
)
```

When `@fast-check/vitest` is not installed, use raw `fc.assert(fc.property(...))`. When the predicate is async, use `fc.asyncProperty` and `await fc.assert(...)`.

### Arbitraries

TypeScript types are erased at runtime, so arbitraries cannot be auto-derived from interfaces.

**Manual with `fc.record()`** (default):

```ts
// test/arbitraries.ts
import fc from 'fast-check'

export const moneyArb = fc.integer().map(fromCents)

export const orderItemArb = fc.record({
  sku: fc.string({ minLength: 1 }),
  quantity: fc.integer({ min: 1 }),
  price: moneyArb,
})

export const orderArb = fc.record({
  id: fc.hexaString({ minLength: 8, maxLength: 8 }).map(s => s as OrderId),
  customerId: fc.constant('cust-1' as CustomerId),
  items: fc.array(orderItemArb, { minLength: 1 }),
  status: fc.constant({ type: 'draft' } as const),
})
```

**Derived from runtime schemas** (when the project already uses Zod, Valibot, TypeBox, or TypeSpec):

```ts
import { ZodFastCheck } from 'zod-fast-check'
import { MoneySchema, OrderItemSchema } from '../src/schemas.ts'

export const moneyArb = ZodFastCheck().inputOf(MoneySchema)
export const orderItemArb = ZodFastCheck().inputOf(OrderItemSchema)
```

Do not add a schema library solely for test arbitraries. If the project already validates with Zod/Valibot/TypeBox, use its schemas. Otherwise, `fc.record()` is the right tool.

### Arbitrary Constraint Discipline

Never specify `maxLength`, `min`, `max`, or other constraints on an arbitrary unless the algorithm under test requires that constraint. Overly narrow arbitraries hide bugs at boundaries.

```ts
// BAD — hides bugs for strings longer than 5
fc.string({ maxLength: 5 })

// GOOD — tests the full input space
fc.string()

// OK — algorithm genuinely requires non-empty input
fc.string({ minLength: 1 })
```

If generation is too slow on large inputs, use `size: '-1'` to reduce size without imposing hard limits.

### Property Test Scopes

Follow the same layering as unit tests:

- Layer 1: test exported pure functions from the same file. Test private logic only when it contains tricky invariants.
- Layer 2: test cross-module composition within a feature (e.g., validate then transform then serialize roundtrip).
- Layer 3: test full public API invariants.

### Classical Properties

1. **Characteristics independent of the inputs.** E.g., for any float d, `Math.floor(d)` is an integer. For any integer n, `Math.abs(n) >= 0`.
2. **Characteristics derived from the inputs.** E.g., for any a, b integers, the average of a and b is between a and b. For any array, `sorted(data)` contains the same elements as `data`.
3. **Restricted set of inputs with useful characteristics.** E.g., for any array with no duplicates, removing duplicates returns the array itself. For any a, b, c strings, `a + b + c` always contains `b`.
4. **Characteristics on combination of functions.** E.g., zipping then unzipping should return the original. `lcm(a,b) * gcd(a,b) === a * b`.
5. **Comparison with a simpler implementation.** E.g., binary search and linear search agree on membership.

### Model-Based Testing (fc.commands)

Use `fc.commands()` to test stateful logic (pagination, filters, sort, selection) by comparing a simplified model (a plain object) against the real implementation. fast-check generates random command sequences and asserts both stay in sync.

Each command implements `check(model)` (is this action valid in the current state?) and `run(model, real)` (execute against both and assert they match).

```ts
class NextPage implements fc.Command<PaginationModel, Paginator> {
  check(m: Readonly<PaginationModel>) {
    return m.currentPage < totalPages(m)
  }
  run(m: PaginationModel, real: Paginator) {
    m.currentPage++
    real.nextPage()
    expect(real.currentItems()).toEqual(currentItems(m))
    expect(real.currentPage).toBe(m.currentPage)
  }
  toString() {
    return 'NextPage'
  }
}

describe('Paginator', () => {
  it.skipIf(tdd)('should maintain consistent state under random operations', () => {
    fc.assert(
      fc.property(
        fc.array(fc.string(), { minLength: 1 }),
        fc.commands([fc.constant(new NextPage()), fc.constant(new PrevPage())]),
        (items, cmds) => {
          const model: PaginationModel = { items, pageSize: 10, currentPage: 1 }
          const real = createPaginator(items, 10)
          fc.modelRun(() => ({ model, real }), cmds)
        },
      ),
    )
  })
})
```

Model-based tests are slow. Mark with `it.skipIf(tdd)`.

### Race Condition Testing (fc.scheduler)

Use `fc.scheduler()` to test async code that depends on resolution ordering. The scheduler permutes the order in which promises resolve, finding races that sequential tests miss.

```ts
describe('queue', () => {
  it.skipIf(tdd)('should resolve in call order regardless of completion order', async () => {
    await fc.assert(fc.asyncProperty(fc.scheduler(), async s => {
      // Arrange
      const seenAnswers: number[] = []
      const call = vi.fn().mockImplementation(v => Promise.resolve(v))

      // Act
      const queued = queue(s.scheduleFunction(call))
      await s.waitFor(
        Promise.all([
          queued(1).then(v => seenAnswers.push(v)),
          queued(2).then(v => seenAnswers.push(v)),
        ]),
      )

      // Assert
      expect(seenAnswers).toEqual([1, 2])
    }))
  })
})
```

Use `fc.scheduler()` for debounce logic, parallel API calls, queued operations, and any code that accepts async functions as input.

### Replay and Regression

When fast-check finds a failing input, it reports a `seed` and `path`. Use these to replay:

```ts
fc.assert(fc.property(moneyArb, m => {/* ... */}), { seed: 1234567890, path: '0:1:2' })
```

Record failing seeds as named regression tests alongside the property test that found them:

```ts
// Regression: fast-check seed 1234567890, path "0:1:2"
it('should handle max value edge case from shrunk failure', () => {
  const m = fromCents(999999)
  expect(parse(serialize(m))._unsafeUnwrap()).toEqual(m)
})
```

### Configuration

Set default `numRuns` for the project. CI can increase it.

```ts
// test/setup.ts
fc.configureGlobal({ numRuns: 100 })
```

## Injecting Dependencies

```ts
type Clock = { now: () => Date }
const fixedClock = (d: Date): Clock => ({ now: () => d })

describe('isExpired', () => {
  it('should return true for a past date', () => {
    const clock = fixedClock(new Date('2025-01-01'))
    const order = buildOrder({ expiresAt: new Date('2024-12-31') })
    expect(isExpired(clock)(order)).toBe(true)
  })
})
```

## Builders

```ts
// test/builders.ts
export const buildOrder = (overrides: Partial<Order> = {}): Order => ({
  id: 'order-1' as OrderId,
  customerId: 'cust-1' as CustomerId,
  items: [buildOrderItem()],
  status: { type: 'draft' },
  ...overrides,
})

export const buildOrderItem = (overrides: Partial<OrderItem> = {}): OrderItem => ({
  sku: 'SKU-001',
  quantity: 1,
  price: fromCents(1000),
  ...overrides,
})
```

## Directory Examples

Vitest project with layered features:

```
src/
├── orders/
│   ├── money.domain.ts
│   ├── money.spec.ts              // Layer 1: unit + property
│   ├── invariants.domain.ts
│   ├── invariants.spec.ts         // Layer 1: unit + property
│   ├── pricing.app.ts             // depends on domain imports
│   ├── pricing.spec.ts            // Layer 2: tests pricing.app.ts wiring
│   ├── postgres.infra.ts          // adapter
│   ├── postgres.spec.ts           // contract suite (fake: fast, real: slow)
│   └── tests/                     // Layer 2 (when feature grows)
│       └── orders.spec.ts         // cross-module tests + property tests
test/
├── orders.spec.ts                 // Layer 3: integration, real deps
├── arbitraries.ts
├── builders.ts
├── helpers.ts
└── setup.ts                       // fc.configureGlobal
vitest.config.ts
package.json                       // test + test:tdd scripts
```

Simple project (flat structure, no formal layers):

```
src/
├── money.domain.ts
├── money.spec.ts                  // co-located spec
├── parser.domain.ts
├── parser.spec.ts                 // co-located spec
├── app.ts
├── app.spec.ts                    // co-located spec for app.ts
test/
├── builders.ts
└── helpers.ts
vitest.config.ts
```

Builtin runner project (no Vitest):

```
src/
├── money.domain.ts
├── money.spec.ts
├── parser.domain.ts
├── parser.spec.ts
└── app.ts
test/
└── integration.spec.ts
```

## Anti-Patterns

| Don't                                           | Do Instead                                            |
| ----------------------------------------------- | ----------------------------------------------------- |
| `result._unsafeUnwrap()` without rail check     | `expectOk(result)` / `expectErr(result)`              |
| `as any` type escape                            | Properly typed test data                              |
| Untyped fake `{ find: async () => user }`       | Fake satisfying full port type                        |
| Async without await in test                     | Always `await` async calls                            |
| Layer 1 tests for functions with imports        | Move to Layer 2                                       |
| `__tests__/` directories                        | Co-locate tests next to source                        |
| Separate files by test type (`.prop.spec.ts`)   | Organize by layer, skip slow tests inline             |
| Adding Zod/Valibot just for arbitraries         | `fc.record()` manually                                |
| Testing re-exports or pass-through              | Layer 1 tests only test the file's own pure functions |
| Formal layers in a 3-file project               | Keep it flat until complexity demands structure       |
| Shared mutable test state                       | Each test owns its data                               |
| Source file >~150 LOC                           | Split into focused files                              |
| Stacking suffixes (`main.infra.spec.ts`)        | `.spec.ts` replaces layer suffix: `main.spec.ts`      |
| `maxLength` on arbitrary without algorithm need | Use defaults; `size: '-1'` if generation too slow     |
| Hardcoded unused field values in test data      | `g(fc.string)` via `@fast-check/vitest`               |

## Checklist

- [ ] `expectOk`/`expectErr` helpers for Result
- [ ] Fakes type-checked against port
- [ ] Contract suite shared: fake (fast), real (slow)
- [ ] Typed arbitraries in `test/arbitraries.ts`
- [ ] Arbitraries derived from runtime schemas when already present (Zod, Valibot, TypeBox)
- [ ] Arbitrary constraints only specified when algorithm requires them
- [ ] Builders in `test/builders.ts`
- [ ] Slow tests marked with `it.skipIf(tdd)` (property tests, integration with real deps)
- [ ] `package.json` scripts: `test` (full suite) and `test:tdd` (watch, slow skipped)
- [ ] Default `npm test` runs all: unit, property, integration
- [ ] E2E and fuzz in separate workflows only
- [ ] All tests use `.spec.ts` extension, organized by layer
- [ ] `.spec.ts` replaces layer suffix, never stacks on it
- [ ] No separate files by test type
- [ ] Watch mode < 5 seconds
- [ ] No `any` or type escapes
- [ ] No unwrap without rail assertion
- [ ] Async tests always `await`
- [ ] Layer 1 tests only exercise pure functions from the source file
- [ ] Functions depending on imports tested at Layer 2+
- [ ] Layer 2 avoids redundancy with Layer 1
- [ ] Failing fast-check seeds recorded as regression tests
- [ ] `fc.configureGlobal` sets default `numRuns`
- [ ] `@fast-check/vitest` used as preferred fast-check integration
- [ ] Model-based tests (`fc.commands()`) for stateful logic
- [ ] `fc.scheduler()` for async resolution order testing
- [ ] Co-located `.spec.ts` files for all tests
- [ ] Layers added only when complexity warrants them
