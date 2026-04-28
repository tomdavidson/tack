# Testing

Complements [Tom's Clean Code](toms-clean-code.md) and [Tom's Clean Architecture](toms-clean-arch.md). Scope: local development. Language-specific details live in [Rust Testing](testing-rust.md) and [TypeScript Testing](testing-typescript.md).

## When to Write Which Test

| Trigger                                         | Test Type        |
| ----------------------------------------------- | ---------------- |
| New feature/user story                          | Acceptance test  |
| Function has conditional logic or business rule | Unit test        |
| Function has invariant over large input space   | Property test    |
| Stateful logic (pagination, filters, queues)    | Model-based test |
| Port interface with fake + real impl            | Contract test    |
| IO adapter (DB, HTTP, filesystem)               | Integration test |
| Parser, validator, deserializer                 | Fuzz test        |

**Skip tests for:** trivial mappings, pass-through glue, code with no conditionals already covered by acceptance test.

## Test Naming Convention

All tests use `describe` + `it` + `should`:

```
describe('[UnitUnderTest]', () => {
  it('should [expected outcome] when [condition]', ...);
});
```

The `should` prefix forces outcome-oriented names. The `describe` block groups by the unit being tested (function, component, module). This convention applies across all languages that support grouping (Vitest `describe`/`it`, Rust `mod` + `#[test]` with `should_` prefix, etc.).

```
describe('add', () => {
  it('should sum two positive values correctly', ...);
  it('should return zero when both inputs are zero', ...);
});

describe('parse', () => {
  it('should return Err for non-numeric string', ...);
  it('should roundtrip with serialize for any integer', ...);
});
```

For languages without `describe` (e.g., Rust), use module nesting and `should_` prefix on function names:

```rust
mod add {
    #[test]
    fn should_sum_two_positive_values() { ... }

    #[test]
    fn should_return_zero_when_both_inputs_are_zero() { ... }
}
```

## Test Location and Layering

Tests follow DDD/feature layered scopes. Each layer has a clear boundary for what it tests and how it avoids redundancy with other layers.

Not every project needs formal layers. A small utility may only have Layer 1 tests. A small service might skip Layer 2 and go straight from Layer 1 to Layer 3. Use layers when they clarify boundaries, not to satisfy a checklist.

### Layer 1: Co-located Unit Tests

Tests that exercise functions defined in a single source file. Located adjacent to the source: a co-located test file (TypeScript: `money.spec.ts` next to `money.domain.ts`; Rust: `#[cfg(test)] mod tests` at the bottom of the source file).

Private and helper functions get direct, thorough testing with tight contracts. These are the atoms. Public orchestrating or composing functions are tested too, but designed to avoid redundancy. Orchestration tests verify composition correctness, not re-testing what helpers already cover.

Do not test imports. If an import changes, Layer 1 tests still pass because they never exercise cross-file behavior.

### Layer 2: Sibling Files / Component Tests

Tests that involve multiple files in the same directory or DDD layer. If individual files are atoms, Layer 2 tests are molecules. Located in a `tests/` subdirectory inside that layer, or a single test file if the feature is small.

Only test public functions from the files. Avoid redundancy with Layer 1. Layer 2 tests verify cross-module composition that no single file's tests can cover.

### Layer 3: Module / Crate / API Tests

Tests that cover the whole: an npm package, a Rust crate, an API, a deployable unit. Layer 3 scope spans multiple feature/DDD layers. This is where contract tests, integration tests, and cross-layer property tests live. Mostly not unit tests.

## Fast / Slow Split

Fast tests must run in watch mode. Potentially slower tests (property tests, model-based tests, integration) need separation so they don't block the feedback loop. Watch mode budget: <5 seconds total for fast tests.

Each language has its own mechanism for separation. See language-specific testing docs for details. The principle is the same: property tests and integration tests must be excludable from the watch-mode runner.

## Test File Naming

Tests co-locate with source. No separate test directories (e.g., no `__tests__/`).

Language-specific naming conventions belong in their respective docs. The universal rules:

- Fast tests (unit, acceptance with fakes, contract with fake) run in watch mode.
- Property and model-based tests are separated from watch mode.
- Slow tests (acceptance with real deps, contract with real, integration, fuzz) run pre-push and in CI.

## Test Structure

### Acceptance Test

```
describe('[Feature]', () => {
  it('should [user-visible outcome]', () => {
    setup: preconditions
    action: call entry point (use case, handler)
    assert: observable outcome
  });
});
```

One per feature. Uses fakes for fast runs, real deps for slow runs.

### Unit Test

```
describe('[function]', () => {
  it('should [expected] when [condition]', () => {
    input -> function -> assert result
  });
});
```

One assertion per test. No IO, no shared state.

### Property Test

```
describe('[function]', () => {
  it('should [invariant statement] for any [input description]', () => {
    forall generated inputs: assert invariant holds
  });
});
```

Invariants: roundtrip, idempotent, commutative, preserved-after-transform.

### Model-Based Test

```
describe('[StatefulSystem]', () => {
  it('should maintain consistent state under random operations', () => {
    define simplified model + commands
    generate random command sequences
    assert model and real implementation stay in sync
  });
});
```

Use for stateful logic: pagination, filters, sort, selection, queues. Each command defines `check` (is this valid?) and `run` (execute + assert). Mark as slow.

### Contract Test

```
describe('[PortName] contract', () => {
  shared tests run against [FakeImpl, RealImpl]
});
```

Guarantees fake matches real behavior.

### Integration Test

```
describe('[Adapter]', () => {
  it('should [operation] [scenario]', () => {
    setup real dep -> action -> assert state -> teardown
  });
});
```

## Property Test Scopes

Property tests follow the same layering as unit tests:

- Layer 1: test public/exported functions from the same file. Test private functions only if they contain tricky logic.
- Layer 2: test cross-module composition (e.g., classify then accumulate then finalize roundtrip).
- Layer 3: test full public API invariants.

### Classical Properties

1. **Characteristics independent of the inputs.** E.g., `Math.floor(d)` is always an integer. `Math.abs(n) >= 0`.
2. **Characteristics derived from the inputs.** E.g., average of a and b is between a and b. `sorted(data)` contains the same elements as `data`.
3. **Restricted set of inputs with useful characteristics.** E.g., for arrays with no duplicates, dedup returns the array itself.
4. **Characteristics on combination of functions.** E.g., zip then unzip returns original. `lcm(a,b) * gcd(a,b) === a * b`.
5. **Comparison with a simpler implementation.** E.g., binary search and linear search agree on membership.

### Arbitrary Constraint Discipline

Never constrain generated inputs (max length, min/max value) unless the algorithm under test requires that constraint. Overly narrow generators hide bugs at boundaries. If generation is too slow on large inputs, reduce size hints rather than imposing hard limits.

## Test Doubles

**Default: Fake** working in-memory implementation of port interface.

**Stub:** Simple dependency, no behavior verification needed.

**Mock:** Almost never. Only when:

1. Injected time/randomness/UUID
2. Fire-and-forget side effect with no queryable state
3. Vendor SDK with prohibitive fake cost
4. Legacy code (temporary)

## Why Fakes Over Mocks

Mocks verify implementation, not behavior:

- Couple tests to internal structure
- Pass when code is broken, fail when code is correct
- Require maintenance on refactor
- Give false confidence

Fakes verify behavior through execution. Contract tests ensure fakes match real.

**Never mock:** database, domain logic, HTTP clients, anything with a fake available.

## HTTP Dependencies

| Dependency                        | Approach                        |
| --------------------------------- | ------------------------------- |
| Internal service (own both sides) | Contract test (e.g., Pact)      |
| Internal service (others own)     | Fake from their contract/schema |
| External API                      | Adapter + typed fake            |

Wrap HTTP in adapter interface. Fake the adapter, not the HTTP client.

## Database Tests

- Each test owns its data, no shared seeds
- Truncate or transaction rollback per test
- Builders create test data, not fixtures
- Containers for CI (testcontainers, docker-compose)

```
// BAD: shared state
setup: seedUsers()

// GOOD: test owns data
it('should find saved user', () => {
  save(buildUser()) -> find -> assert
});
```

## Async Tests

Never poll or sleep-wait. If you need to wait:

- **Event-based:** Return a future/promise that resolves on completion
- **State-based:** Expose observable/callback
- **Retry needed:** Indicates design flaw, fix the coupling

```
// BAD
sleep(100ms) -> assert state

// GOOD
await operationCompleted() -> assert
```

## AAA Comments

Use `// Arrange`, `// Act`, `// Assert` comments in tests where the boundaries between phases are non-obvious (complex setup, multiple awaits, helper calls that blur the lines). Omit them in simple tests where the three phases are visually clear.

## Snapshots

Use only for:

- Large generated output where manual assertion impractical
- Regression detection on stable structures

Never for:

- Domain objects (use equality)
- API responses (assert specific fields)
- "I don't know what to assert"

## E2E Tests

Minimal or none. E2E tests:

- Slow, flaky, expensive to maintain
- Test too much, failures hard to diagnose
- Duplicate coverage from unit + contract + integration
- False confidence, pass in CI, fail in production

If org requires: limit to 1-2 critical smoke tests post-deploy. Never in watch mode. Web apps may need targeted E2E for behavior that cannot be tested without a full running application (see [Web App Testing](testing-webapp.md)).

## Flaky Tests

Flaky test = broken test. Response:

1. Quarantine immediately (skip or separate suite)
2. Fix root cause (shared state, timing, external dep)
3. Never retry-until-pass as solution

## Test Data Builders

Create minimal valid objects. Override only what matters for test.

```
buildOrder(status="draft")    // other fields have safe defaults
```

Place builders in shared test utilities. Reuse across tests.

## Anti-Patterns

| Don't                                       | Do Instead                                      |
| ------------------------------------------- | ----------------------------------------------- |
| Mock the database                           | Container or in-memory                          |
| Mock domain logic                           | Fakes with contract tests                       |
| Mock HTTP client directly                   | Adapter + fake                                  |
| Assert call counts                          | Assert return value or state                    |
| Shared test seeds                           | Each test owns its data                         |
| Sleep/poll waits                            | Event-based completion                          |
| Snapshot domain objects                     | Equality assertions                             |
| Giant integration test                      | Acceptance + targeted units                     |
| Retry flaky tests                           | Fix root cause                                  |
| Slow tests in watch mode                    | Separate to slow runner                         |
| Constrain generators without algorithm need | Use defaults; reduce size hints if slow         |
| Separate files by test type                 | Organize by layer, skip slow tests inline       |
| Formal layers in a trivial project          | Keep it flat until complexity demands structure |

## Checklist

- [ ] Acceptance test defines "done"
- [ ] Unit tests cover non-trivial domain logic
- [ ] Property tests for invariants
- [ ] Property tests separated from watch mode
- [ ] Arbitrary constraints only when algorithm requires them
- [ ] Model-based tests for stateful logic
- [ ] Ports have contract suites (fake + real)
- [ ] Fakes pass same contract as real impls
- [ ] No mocks except four allowed cases
- [ ] HTTP deps wrapped in adapter, faked in tests
- [ ] Database tests own their data
- [ ] No sleep/poll waits
- [ ] No snapshots for domain objects
- [ ] All fast tests < 5 seconds in watch mode
- [ ] Flaky tests quarantined and fixed
- [ ] `describe`/`it`/`should` naming convention
- [ ] AAA comments on non-obvious tests only
- [ ] Layer 1 tests do not test imports
- [ ] Layer 2 avoids redundancy with Layer 1
- [ ] Layer 3 covers cross-layer and contract scope
- [ ] Layers added only when complexity warrants them
