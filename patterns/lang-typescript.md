# TypeScript

> TypeScript-specific implementation choices for [Tom's Clean Code](toms-clean-code.md).
> Principles describe intent and come first. Rules encode what the toolchain enforces.
> When they conflict, follow the principle and justify any inline lint override.
> Align preemptively to reduce reasoning and churn.
>
> This document captures the rules that most affect code generation quality. It is not
> an exhaustive mirror of every linter rule. The full rule sets live in `oxlintrc.json`
> (oxlint), `eslint.config.mjs` (ESLint + functional/boundaries), and `dprint.json`
> (formatter). Low-frequency correctness rules (e.g., `no-proto`, `no-extend-native`,
> `no-iterator`) are omitted here because LLMs rarely produce those patterns. The
> linters still enforce them.

## Module Structure

Organize by feature. File suffixes declare the architectural layer so oxlint can match rules
by glob. The stem describes the business concern, the suffix describes the constraint level.

src/orders/
types.domain.ts
invariants.domain.ts
pricing.app.ts
validate-line-items.app.ts
postgres.infra.ts
pricing.spec.ts

text

When a feature accumulates 5+ files of the same suffix, promote to a subdirectory. Both
patterns coexist in the same oxlint config so features grow independently:

src/orders/
domain/
types.ts
invariants.ts
events.ts
value-objects.ts
factories.ts
pricing.app.ts
postgres.infra.ts

text

### Layers

| Layer  | Suffix / Glob                             | Purpose                                                 | Rule Posture                                                 |
| ------ | ----------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------ |
| Domain | `*.domain.ts`, `**/domain/**`             | Types, discriminated unions, invariants, pure logic     | Strictest: all FP errors, `readonly` required, no IO imports |
| App    | `*.app.ts`, `**/app/**`                   | Use cases, orchestration, port interfaces               | Strict: all FP errors, `readonly` warn                       |
| Infra  | `*.infra.ts`, `**/infra/**`, `src/cli/**` | Repos, adapters, IO, CLI, composition (`main.infra.ts`) | Relaxed: FP warns/off, classes with suffixes allowed         |

Tests (`*.spec.ts`, `*.test.ts`) are a file type, not an architectural layer. oxlint relaxes
all FP, complexity, and type-safety rules for test globs.

### Import Direction

Domain may import domain. App may import domain and app. Infra may import all three. Nothing
imports from tests.

Domain files must never import Node.js built-ins (`fs`, `path`, `http`, `net`, `crypto`,
`child_process`), HTTP frameworks, database drivers, or cloud SDKs. Express external
dependencies as port interfaces in app-layer files.

### oxlint Override Globs

```json
"overrides": [
  {
    "files": ["**/*.domain.ts", "**/domain/**/*.ts"],
    "rules": { "/* readonly: error, IO import ban */" }
  },
  {
    "files": ["**/*.infra.ts", "**/infra/**/*.ts", "src/cli/**/*.ts"],
    "rules": { "/* relaxed FP */" }
  },
  {
    "files": ["**/*.spec.ts", "**/*.test.ts"],
    "rules": { "/* everything off */" }
  }
]
```

App-layer files (`*.app.ts`, `**/app/**`) use the global default rules with no override needed.

oxlint does not support per-code-structure exceptions. When a file pattern needs different
rules outside the three layers (e.g., framework entry points), use a distinct glob such as
`*.page.ts` and add an oxlint override for that pattern.

## Formatting

- 2-space indentation, no tabs (Rust: 4-space; Makefile: tabs)
- LF line endings, final newline at EOF, trim trailing whitespace (except Markdown)
- Line width: 110 characters (100 for JSON and Markdown)
- Single quotes for strings and JSX attributes
- No semicolons (rely on ASI)
- Trailing commas only in multiline constructs; omit in single-line
- Omit parentheses on a single arrow-function parameter: `x => x + 1`
- Prefer single-line for parameters, arguments, and short expressions
- Keep binary and member expressions same-line; break ternaries one line per branch
- Type literal members use semicolons as separators
- Enum members each on their own line
- Sort named imports/exports and import declarations case-insensitively
- Concise arrow body when possible: `x => x + 1`, not `x => { return x + 1 }`

## Language Choices

Beyond linting. Semantic and style preferences.

- `?.` over `&&` chains; `??` for null/undefined defaults; `||` only when falsy-inclusive
  default intended (the `prefer-nullish-coalescing` warning can be overridden in that case)
- Arrow functions over `function` declarations
- Implicit return for single expressions
- Destructure when accessing 2+ properties from the same object
- Spread over `Object.assign`
- `as const` for static config and lookup tables
- Prefer single-line ternary over simple if/else when it fits on one line
- No `.forEach()`. Use `.map()`, `.filter()`, `.reduce()`, or other array methods.

## Function Style

### Principle

Uncurried by default: `(a, b) => result`. Curry when reused partially or when it improves
readability/testability: `(deps) => (data) => result`.

### Rules

- Max 3 parameters. Use an options object for more.
- Max function length: 25 logical lines (blank lines and comments excluded).
- Max cyclomatic complexity: 5 branches per function.
- Max nesting depth: 2. Use guard clauses and early returns. Never `else` after `return`.
- No boolean parameters. Split into separate functions.
- No nested ternaries. Single-line ternaries for simple cases; early-return for complex ones.
- No variable shadowing. Use distinct names in inner scopes.

## Error Handling

### Principle

neverthrow for `Result<T, E>`. Railway composition with `map`, `mapErr`, `andThen`. No
`throw` in domain. Convert throws to Result at the IO boundary:

```ts
const safeFetch = (url: string) =>
  ResultAsync.fromPromise(fetch(url).then(r => r.json()), toNetworkError)
```

Skip `Result` for completely infallible operations where wrapping adds noise. Infallible
functions return their computed value directly (not `Result<T, never>`). If a function has
no natural return value, it performs a side effect and belongs in an infrastructure file.

### Rules

- `no-throw-statements: error` and `no-try-statements: error` in domain and application
- `no-return-void: error` in domain and application; off in infrastructure
- `._unsafeUnwrap()` and `._unsafeUnwrapErr()` are banned via AST selector
- Only throw `Error` subclasses with messages: `throw new Error('...')`, never `throw 'string'`
- Always use `new` with Error: `throw new Error(...)`, not `throw Error(...)`
- Prefer `TypeError` when the issue is a type/shape violation
- Reject promises with Error objects: `Promise.reject(new Error(...))`, not `Promise.reject('msg')`

## Async

### Principle

Async is for IO at boundaries. Logic stays sync and pure. If you're awaiting inside
conditionals or mutating between awaits, restructure.

- ResultAsync chains over bare await. Compose with `andThen`, `map`, `mapErr`. Bare `await`
  only at boundaries or when chaining genuinely hurts readability.
- Fetch then process: async for IO, then sync pure logic.
- No mutation between awaits (race condition source).
- No branching inside async chains (control flow unclear across ticks).

```ts
// BAD — sequential awaits treating async as sync
const user = await fetchUser(id)
if (user.isErr()) return user
const posts = await fetchPosts(user.value.id)
if (posts.isErr()) return posts
return formatResponse(posts.value)

// GOOD — railway composition
const result = await fetchUser(id).andThen(user => fetchPosts(user.id)).map(formatResponse)

// GOOD — parallel fetch, pure logic
const [user, posts] = await Promise.all([fetchUser(id), fetchPosts(id)])
return processUserWithPosts(user, posts)
```

### Rules

- Never leave a Promise floating. Always `await`, `return`, or `void` it.
- Do not pass async functions where a sync callback is expected.
- Always `return await` inside async functions (not bare `return promise`).
- Avoid `await` inside loops. Prefer `Promise.all()`, `ResultAsync.combine()`.
- Do not wrap a single Promise in `Promise.all()` or `Promise.race()`.
- Do not `await` inside `Promise.all()`/`Promise.race()` arguments (defeats parallelism):
  `Promise.all([fetchA(), fetchB()])`, not `Promise.all([await fetchA(), await fetchB()])`.
- Do not `await` non-Promise values unnecessarily.
- Do not define objects with a `.then()` method (confuses async consumers).
- Do not call `new Promise.resolve()` or `new Promise.reject()` (they are static methods).
- Promise method calls must have valid parameters (correct argument count).
- Avoid resolving or rejecting a promise more than once.

## Immutability

### Principle

Immutability applies at function boundaries, not inside function bodies. Locally scoped
mutation (e.g., building a `Map` with `.set()` before returning) is acceptable. Only mutation
that escapes the function scope needs to be avoided.

### Rules

- `const` exclusively. `no-let` is an error. If local mutation is genuinely appropriate in
  the application layer, use an intentional inline override with justification. This should
  be rare.
- `immutable-data: warn` flags mutations. Immediate mutation of a just-created object is
  ignored (`ignoreImmediateMutation: true`).
- `no-param-reassign: error`. Never mutate function arguments.
- Spread for updates: `{ ...user, address: { ...user.address, city: 'NYC' } }`
- `readonly` on type properties, `Readonly<T>`, `ReadonlyArray<T>`. Required in domain files.
- Array updates via spread/methods, not index assignment.
- Use object/array literals, not `new Object()` or `new Array()`.

### Accumulating Spread

`oxc/no-accumulating-spread` warns when spread is used inside `.reduce()` because it is O(n²).
If the dataset is small and the pattern is clearer than the alternative, justify the inline
lint ignore on performance grounds. For large collections, build with a mutable local structure
and return the frozen result.

## Iteration

### Principle

Array methods over loops: `map`, `filter`, `reduce`, `flatMap`, `find`, `some`, `every`.
Chain to end, no intermediate variables. `flatMap` for nested transforms. `for await...of`
only when order/back-pressure is required (this belongs in infrastructure files where
`no-loop-statements` is warn-level).

```ts
const findNode = (tree: TreeNode, id: string): TreeNode | undefined =>
  tree.id === id ? tree : tree.children.map(c => findNode(c, id)).find(Boolean)
```

### Rules

- `no-loop-statements: error` in domain and application; `warn` in infrastructure
- No `.forEach()`. Use declarative array methods instead.
- Prefer `.flatMap()` over `.map().flat()`, `.find()` over `.filter()[0]`,
  `.some()` over `.filter().length`, `.indexOf()` over `.findIndex()` for simple lookups.
- Prefer `Set.has()` over `Array.includes()` for repeated lookups.
- `.reduce()` is allowed (`unicorn/no-array-reduce: allow`).

## Control Flow

Guard clauses over nesting. Lookup tables for tag-based dispatch:

```ts
const handlers: Record<Status, (v: Value) => Value> = { ... } as const
```

### Exhaustive Dispatch

- `ts-pattern` with `.exhaustive()` for unions that may grow
- Lookup tables (`Record<Tag, Handler>`) for stable, closed unions
- Plain `switch` only with `assertNever` default for simple cases
- Never `switch` on a discriminated union without `.exhaustive()` or `assertNever`

```ts
// Growing union
const message = match(error).with({ type: 'FileNotFound' }, e => `Missing: ${e.path}`).with({
  type: 'CycleDetected',
}, e => `Cycle: ${e.chain}`).with({ type: 'ContextParseError' }, e => `Bad context: ${e.message}`)
  .exhaustive()

// Stable union
const escaper: Record<SupportedExtension, (s: string) => string> = {
  md: identity,
  txt: identity,
  json: escapeJson,
}
```

## Type System

### Principle

`type` + discriminated unions over classes. Type guards for runtime validation. Prefer small
composable type guards over `as` assertions. Build domain guards from a shared base:

```ts
const isObjectRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null
```

Use `as` only at true boundaries where a guard is impractical and the invariant is externally
guaranteed.

When an optional dynamic import may fail, represent absence with `undefined` returned
implicitly from `.catch()`:

```ts
const mod: unknown = await import('some:optional-peer').catch(() => {})
```

`null` checks (`value !== null`) are fine inside type guards for safe narrowing.

### Rules

- `type` for all type definitions (not `interface`).
- Type imports: `import type { Foo } from './foo'`.
- Avoid `any`. Prefer `unknown` with a type guard.
- Do not let `any` leak through return types, arguments, assignments, calls, or member access.
  The `no-unsafe-*` family (`no-unsafe-return: error`, `no-unsafe-argument: error`,
  `no-unsafe-assignment: warn`, `no-unsafe-call: warn`, `no-unsafe-member-access: warn`)
  catches all paths where `any` propagates.
- No non-null assertions (`!`). Use `??` and `?.`.
- Exhaustive `switch` on unions (linter-checked).
- Strict boolean expressions: `if (value !== undefined)` not `if (value)`.
- Do not add unnecessary type assertions (`as Type` when TS already knows the type).
- Do not add unnecessary explicit type arguments when TS can infer them.
- `@ts-ignore` and `@ts-expect-error` require a description (min 5 chars). `@ts-nocheck` banned.

## Null Handling

- Prefer `undefined` over `null`. Avoid `null` where possible.
- Remove useless `undefined` returns and assignments.
- `??` over `||` for defaults (unless falsy-inclusive default is intentional).
- `?.` over manual null checks.
- `null` in type guards is acceptable; the `unicorn/no-null` warning can be left in place.
- Positive predicates: `if (ready)` not `if (!notReady)`.
- `===` exclusively. No implicit type coercion.

## Modules and Imports

- Named exports exclusively. No default exports. When a framework requires one, place it in a
  file matching a dedicated glob (e.g., `*.page.ts`) with an oxlint override.
- No circular imports. No self-imports.
- `node:` protocol for Node.js built-ins: `import { readFile } from 'node:fs/promises'`
- No `process.env` outside infrastructure. Pass config via arguments or a config object.
- No string concatenation for file paths (`node/no-path-concat`). Use `path.join()` or
  `path.resolve()`.

## Composition

Inline pipe for simple cases, no FP library:

```ts
const pipe = <T>(value: T, ...fns: Array<(a: T) => T>): T => fns.reduce((acc, fn) => fn(acc), value)
```

## Classes

When a framework forces it: thin wrapper delegating to pure functions. In infrastructure,
classes are allowed only with suffix: Controller, Adapter, Module, Client, Provider, Gateway.

- No static-only classes. Use module-scoped functions.
- No extraneous classes (classes that could be a plain object or module).
- Class methods that don't reference `this` should be extracted to standalone functions.
- No empty source files.

## General Hygiene

- No `console.log`. Use `console.error` or `console.warn` only.
- No `debugger`, `eval`, `with`, labels, comma operator, or bitwise operators.
- No magic numbers. Extract constants. 0, 1, -1 permitted inline.
- Error subclasses with messages: `new TypeError('Expected string')`.
- `void` as a statement is allowed (discard Promises); banned as an expression elsewhere.

## Libraries

| Status      | Library                               | Use Case                    |
| ----------- | ------------------------------------- | --------------------------- |
| ✅ Required | `neverthrow`                          | Result/Option               |
| ✅ Approved | `ts-pattern`                          | Matching and complex unions |
| ✅ Approved | `date-fns`                            | Date math and format        |
| ✅ Approved | `Remeda`                              | Multiple helpers simplify   |
| ✅ Approved | `Kysely`                              | Complex SQL                 |
| ❌ Banned   | ORMs, `fp-ts`, `Ramda`, DI containers |                             |

Inline first. Add a dependency only when it materially improves readability or safety.

## Layer Relaxations

Infrastructure files (`repo.ts`, `io.ts`, `adapter.ts`, `src/cli/**`):

- `let` and loops: warn. Still prefer `const` and declarative iteration.
- `try`/`catch`, `throw`: permitted (for wrapping externals into Result).
- Expression statements, `void` returns, mutable data: permitted.

Test files (`*.spec.ts`, `*.test.ts`, `src/test/**`):

- All FP, complexity, and type-safety strictness is lifted.

## Inline Override Guidance

When a principle calls for something a rule prohibits, use an inline disable with justification:

```ts
// eslint-disable-next-line functional/no-let -- local accumulator, does not escape scope
let total = 0

// eslint-disable-next-line oxc/no-accumulating-spread -- 6 items, O(n²) is negligible
const merged = items.reduce((acc, i) => ({ ...acc, ...i.props }), {})
```

If overrides cluster in the same file, the code likely belongs in a different layer or file
pattern where the rule is already relaxed.

## Checklist

- [ ] Module structure: `domain.ts`, `logic.ts`, `io.ts`
- [ ] Named exports
- [ ] Arrow functions, implicit return
- [ ] `?.` and `??` for optionals
- [ ] `neverthrow` for fallible operations
- [ ] No `throw` or `try/catch` in domain
- [ ] No mutation between awaits
- [ ] No branching inside async chains
- [ ] Fetch then process (async then pure)
- [ ] Spread for updates
- [ ] Array methods over loops (no `.forEach()`)
- [ ] No `any` leakage (check return types, args, assignments)
- [ ] No variable shadowing
- [ ] Inline helpers before deps
- [ ] `ResultAsync` chains over bare `await` stacking
