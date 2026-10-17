# Rust Testing

> Rust-specific patterns for [Testing](testing.md) and [Rust Patterns](lang-rust.md). Assumes
> `cargo-nextest`, `proptest`, `proptest-derive`, `cargo-fuzz`.

## Tools

| Purpose     | Crate                          | Notes                                                                                    |
| ----------- | ------------------------------ | ---------------------------------------------------------------------------------------- |
| Runner      | `cargo-nextest`                | Parallel, filtered, per-test overrides. Replaces `cargo test` for running.               |
| Property    | `proptest` + `proptest-derive` | Preferred over quickcheck. `proptest-derive` for `#[derive(Arbitrary)]` on domain types. |
| Snapshot    | `insta`                        | Only for large generated output                                                          |
| Mocking     | `mockall`                      | Only for four allowed cases in [Testing](testing.md)                                     |
| Async       | `tokio::test`                  | For async tests                                                                          |
| Fuzz        | `cargo-fuzz` + `arbitrary`     | Parsers, validators, deserializers (`libFuzzer` + `LibAFL`)                              |
| Integration | `testcontainers`               | Real deps when absolutely needed                                                         |

## Fast vs Slow Split

Use a `tdd` feature flag to separate fast feedback tests from slower property/exhaustive tests.
Default (`cargo nextest run`) runs everything. The `tdd` feature ignores slow tests for watch-mode
speed.

```toml
# Cargo.toml
[features]
tdd = []

[dev-dependencies]
proptest = "1"
proptest-derive = "0.5"
```

| Mode        | Command                            | What runs                                     |
| ----------- | ---------------------------------- | --------------------------------------------- |
| Full        | `cargo nextest run`                | All tests including property tests            |
| TDD / Watch | `cargo nextest run --features tdd` | Only fast unit tests (property tests ignored) |
| Pre-push    | `cargo nextest run`                | Full suite                                    |
| CI          | `cargo nextest run`                | Full suite                                    |

Mark slow tests (property tests, heavy strategies) with the conditional ignore attribute:

```rust
#[test]
#[cfg_attr(feature = "tdd", ignore)]
fn roundtrip_never_loses_data(input in ".*") {
    // proptest body: skipped in TDD mode, runs in full mode
}
```

Fast tests use only `#[test]` with no extra annotation. Fast tests never touch IO. If a test needs a
database, filesystem, or network, it goes in `tests/`.

## Test-Module Clippy Allowance

Because `configs/rust/clippy-cargo.concat.toml` denies `unwrap_used`, `expect_used`, and `panic`
workspace-wide, annotate every `#[cfg(test)]` module so `assert!`, `assert_eq!`, and `prop_assert!`
compile cleanly:

```rust
#[cfg(test)]
#[allow(clippy::panic, clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    // ...
}
```

## Test Location and Layering

Tests live next to the code they exercise, organized by feature and scope. See [Testing](testing.md)
for the language-agnostic layering model.

### Layer 1: In-File Unit Tests

Tests that exercise functions defined in the same file. Always `#[cfg(test)] mod tests` at the
bottom of the source file. If the file gets too long, the functions need splitting, not the tests.

Private/helper functions get direct, thorough testing with tight contracts. These are the atoms.
Public orchestrating or composing functions are tested too, but designed to avoid redundancy with
helper tests. Focus orchestration tests on composition correctness, not re-testing what helpers
already cover.

Do not test imports. If an import changes, Layer 1 tests still pass.

Tests that verify data threading from downstream modules use `threads_through_from_<source>` in the
name to signal passthrough fidelity intent.

```text
src/orders/
├── domain.rs                    // #[cfg(test)] mod tests at bottom
├── app.rs                       // #[cfg(test)] mod tests at bottom
└── infra.rs                     // #[cfg(test)] mod tests at bottom
```

### Layer 2: Feature-Scoped Tests

Tests that exercise multiple files within the same feature directory. If individual files are atoms,
Layer 2 tests are molecules. These go in a `tests/` subdirectory inside the feature directory.

Only test public functions from the files. Avoid redundancy with Layer 1. Layer 2 tests verify
cross-module composition that no single file's tests can cover.

```text
src/orders/
├── tests/                       // Layer 2: cross-module within feature
│   ├── mod.rs
│   └── proptest.rs              // property tests spanning multiple modules
```

Wire up layer tests in the feature's `mod.rs`:

```rust
// src/orders/mod.rs
#[cfg(test)]
mod tests;
```

### Layer 3: Cross-Feature / Integration Tests

Tests that span multiple features or the full public API. These go in the top-level `tests/`
directory (Cargo integration test convention). Layer 3 covers the whole crate, an API surface, or a
full pipeline. This is where contract tests, integration tests, and cross-layer property tests live.

```text
tests/
├── parse_integration.rs         // full pipeline tests
├── json_output.rs               // public API -> JSON serialization
└── proptest_integration.rs      // cross-layer property tests
```

### Directory Summary

```text
src/
├── orders/
│   ├── mod.rs
│   ├── domain.rs                // Layer 1: #[cfg(test)] mod tests
│   ├── app.rs                   // Layer 1: #[cfg(test)] mod tests (with fakes)
│   ├── infra.rs                 // Layer 1: contract tests against fake
│   └── tests/                   // Layer 2: cross-module within feature
│       ├── mod.rs
│       └── proptest.rs          // #[cfg_attr(feature = "tdd", ignore)]
├── inventory/
│   ├── mod.rs
│   ├── domain.rs                // Layer 1: #[cfg(test)] mod tests
│   ├── app.rs                   // Layer 1: #[cfg(test)] mod tests
│   └── infra.rs                 // Layer 1: contract tests against fake
├── test_utils.rs                // builders, strategies, assert helpers (#[cfg(test)])
tests/                           // Layer 3: cross-feature integration tests
├── parse_integration.rs
└── proptest_integration.rs
fuzz-common/                     // shared Arbitrary types for structured fuzzing
fuzz-core/                       // cargo-fuzz harnesses, corpus, and regressions/
```

## Result Assertions

`unwrap()` is allowed in tests, but explicit helpers give clearer failure diagnostics:

```rust
fn assert_ok<T, E: std::fmt::Debug>(result: Result<T, E>) -> T {
    match result {
        Ok(v) => v,
        Err(e) => panic!("expected Ok, got Err({e:?})"),
    }
}

fn assert_err<T: std::fmt::Debug, E>(result: Result<T, E>) -> E {
    match result {
        Err(e) => e,
        Ok(v) => panic!("expected Err, got Ok({v:?})"),
    }
}

#[test]
fn parse_user_valid_returns_ok() {
    let user = assert_ok(parse_user(VALID_JSON));
    assert_eq!(user.id.as_str(), "123");
}

#[test]
fn parse_user_invalid_returns_parse_error() {
    let err = assert_err(parse_user(INVALID_JSON));
    assert!(matches!(err, ParseError::InvalidFormat(_)));
}
```

## Typed Fakes via Traits

Define port as trait. Implement fake for tests. Compiler enforces the contract.

```rust
// app.rs
#[async_trait::async_trait]
pub trait OrderRepo: Send + Sync {
    async fn save(&self, order: &Order) -> Result<(), RepoError>;
    async fn find_by_id(&self, id: &OrderId) -> Option<Order>;
}

// test_utils.rs or #[cfg(test)] module
pub struct FakeOrderRepo {
    store: std::sync::Mutex<HashMap<OrderId, Order>>,
}

impl FakeOrderRepo {
    pub fn new() -> Self {
        Self {
            store: Mutex::new(HashMap::new()),
        }
    }
}

#[async_trait::async_trait]
impl OrderRepo for FakeOrderRepo {
    async fn save(&self, order: &Order) -> Result<(), RepoError> {
        self.store
            .lock()
            .unwrap()
            .insert(order.id.clone(), order.clone());
        Ok(())
    }

    async fn find_by_id(&self, id: &OrderId) -> Option<Order> {
        self.store.lock().unwrap().get(id).cloned()
    }
}
```

## Contract Tests

Macro generates shared suite. Run against fake (fast) and real impl (slow).

```rust
macro_rules! order_repo_contract {
    ($setup:expr) => {
        #[tokio::test]
        async fn save_then_find_returns_saved() {
            let repo = $setup().await;
            let order = build_order();
            repo.save(&order).await.unwrap();
            let found = repo.find_by_id(&order.id).await;
            assert_eq!(found, Some(order));
        }

        #[tokio::test]
        async fn find_missing_returns_none() {
            let repo = $setup().await;
            let found = repo.find_by_id(&OrderId::new("nonexistent")).await;
            assert!(found.is_none());
        }
    };
}

// src/orders/infra.rs: fast, in-module
#[cfg(test)]
#[allow(clippy::panic, clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    order_repo_contract!(|| async { FakeOrderRepo::new() });
}

// tests/integration/orders.rs: slow, real DB
order_repo_contract!(|| async { create_test_postgres_repo().await });
```

## Property Testing (proptest)

Property tests use `proptest` and `proptest-derive`. Mark them with
`#[cfg_attr(feature = "tdd", ignore)]` so they are skipped in watch mode but run in full test suite.

### Proptest Scopes

- Layer 1: test public/exported functions. Test private functions only if they contain tricky logic
  that gains significant value from independent property testing.
- Layer 2: test cross-module composition within a feature.
- Layer 3: test full public API invariants.

### Inline with `proptest!` Macro

Strategy helpers and imports go outside `proptest!` but inside `mod tests`. The `#[test]` and
`#[cfg_attr(...)]` annotations go inside the macro on each test function, not outside the macro
block.

```rust
#[cfg(test)]
#[allow(clippy::panic, clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use proptest::prelude::*;

    use super::*;

    fn valid_name() -> impl Strategy<Value = String> {
        "[a-z][a-z0-9]{0,15}"
    }

    #[test]
    fn basic_test() { /* ... */
    }

    proptest! {
        #[test]
        #[cfg_attr(feature = "tdd", ignore)]
        fn serialize_parse_roundtrip(amount in 0i64..1_000_000) {
            let money = Money::from_cents(amount);
            let serialized = money.serialize();
            let parsed = Money::parse(&serialized).unwrap();
            prop_assert_eq!(money, parsed);
        }
    }
}
```

### `proptest!` Macro Gotchas

`prop_assert!` with `matches!` and `{ .. }` patterns fails because `{` and `}` are interpreted as
format string placeholders. Extract to a `let` binding first:

```rust
// BAD: compile error from format string interpretation
prop_assert!(matches!(result.warnings, ParseWarning::UnclosedFence { .. }));

// GOOD: extract to bool first
let is_unclosed = matches!(result.warnings, ParseWarning::UnclosedFence { .. });
prop_assert!(is_unclosed);
```

`prop_assert_eq!` moves values when comparing indexed fields that do not implement `Copy`. Borrow
both sides:

```rust
prop_assert_eq!(&result.commands.arguments.mode, &ArgumentMode::Fence);
```

### Proptest Regressions & `proptest.toml`

- Always commit `proptest-regressions/` files to version control and never delete them.
- If a regression reveals a meaningful domain edge case, also add a named unit test.
- Place `proptest.toml` in the workspace root (`cases = 256`, `max_shrink_iters = 1000`).

### When to Use `proptest-derive`

| Situation                                                          | Approach                                                    |
| ------------------------------------------------------------------ | ----------------------------------------------------------- |
| Fields are independent, constrained primitives                     | `#[derive(Arbitrary)]` with `#[proptest(strategy = "...")]` |
| Fields are interdependent (mode determines which fields are valid) | Manual strategy with `prop_map`                             |
| Natural input is a string, not a struct (parsers)                  | Regex strategy fed through the public function              |
| Need custom distributions or weighted generation                   | Manual strategy in `src/test_utils/arbitrary.rs`            |

## Fuzz Testing (`fuzz-common` + `fuzz-core` + Auto-Regressions)

Target parsers, validators, and deserializers with `cargo-fuzz` using a two-crate workspace split
(`fuzz-common` and `fuzz-core`) and automated `build.rs` regression generation:

1. `fuzz-common` (ordinary library crate): holds shared `arbitrary::Arbitrary` input types used by
   both fuzz harnesses and the core crate's regression tests without leaking `libfuzzer-sys`.
2. `fuzz-core` (fuzz binary crate): runs a 2x2 matrix of unstructured (`&[u8]`) and structured
   (`Arbitrary`) targets across both `libFuzzer` and `LibAFL`.
3. Automated regression replay (`*-core/build.rs`): scans `../fuzz-core/regressions/<target>/` at
   compile time and emits a `#[test]` function per minimized crash file using `include_bytes!(...)`.
   Every triaged fuzzer crash becomes a permanent unit test that runs on every `moon run :test`.

### State Management

- `fuzz-core/corpus/<target>/`: gitignored; persisted via CI cache (`fuzz-cache` action)
- `fuzz-core/artifacts/<target>/`: gitignored; temporary raw crashes and fuzzer logs
- `fuzz-core/regressions/<target>/`: committed; minimized crash reproducers (`cargo fuzz tmin`)

## Injecting Non-Deterministic Dependencies

Use small traits for time, randomness, and IDs:

```rust
pub trait Clock: Send + Sync {
    fn now(&self) -> DateTime<Utc>;
}

pub struct FixedClock(pub DateTime<Utc>);
impl Clock for FixedClock {
    fn now(&self) -> DateTime<Utc> {
        self.0
    }
}
```

## Builders

```rust
pub fn build_order() -> Order {
    Order {
        id: OrderId::new("order-1"),
        customer_id: CustomerId::new("cust-1"),
        items: vec![build_order_item()],
        status: OrderStatus::Draft,
    }
}

pub fn build_order_with(f: impl FnOnce(&mut Order)) -> Order {
    let mut order = build_order();
    f(&mut order);
    order
}
```

## Integration Tests with Testcontainers

Use `testcontainers` only when contract tests require a real implementation (database, broker).
Never in unit tests. Prefer Podman (`TESTCONTAINERS_RYUK_DISABLED=true`) over Docker when available.
Never sleep-wait in async tests; `.await` directly.

## Anti-Patterns

| Don't                                     | Do Instead                                                |
| ----------------------------------------- | --------------------------------------------------------- |
| `unwrap()` in library code                | `?` or typed error                                        |
| Missing `#[allow(clippy::panic)]` in test | Add `#[allow(clippy::panic, clippy::unwrap_used, ...)]`   |
| Testcontainers in unit tests              | In-memory trait fakes                                     |
| Sleep/poll waits in tests                 | `.await` directly                                         |
| Shared mutable test state                 | Each test constructs its own data via `build_*_with`      |
| Snapshot for domain objects               | `assert_eq!` with derived `PartialEq`                     |
| `cargo test` for running                  | `cargo nextest run`                                       |
| Property tests slowing watch mode         | `#[cfg_attr(feature = "tdd", ignore)]`                    |
| Delete proptest or fuzz regression files  | Keep `proptest-regressions/` and `regressions/` committed |

## Checklist

- [ ] `cargo-nextest` as test runner (`moon run :test`)
- [ ] `tdd` feature flag in `Cargo.toml` for fast/slow split
- [ ] `#[allow(clippy::panic, clippy::unwrap_used, clippy::expect_used)]` on `#[cfg(test)]` modules
- [ ] `proptest` + `proptest-derive` in `[dev-dependencies]` and `proptest.toml` in root
- [ ] `proptest-regressions/` and `fuzz-core/regressions/` committed to version control
- [ ] Slow tests marked with `#[cfg_attr(feature = "tdd", ignore)]`
- [ ] Layer 1 tests in-file, Layer 2 in `src/<feature>/tests/`, Layer 3 in top-level `tests/`
- [ ] `assert_ok` / `assert_err` helpers for `Result` assertions
- [ ] Fakes implement port traits; contract macro shared across fake (fast) and real (slow) impls
- [ ] `fuzz-common` + `fuzz-core` + `build.rs` auto-regression loop for parsers and validators
- [ ] Time/randomness injected via traits; builders use `build_X_with` closure pattern
