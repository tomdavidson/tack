# Rust Testing

> Rust-specific patterns for [Testing](testing.md). Assumes `cargo-nextest`, `proptest`, `proptest-derive`, `cargo-fuzz`.

## Tools

| Purpose     | Crate                          | Notes                                                                                    |
| ----------- | ------------------------------ | ---------------------------------------------------------------------------------------- |
| Runner      | `cargo-nextest`                | Parallel, filtered, per-test overrides. Replaces `cargo test` for running.               |
| Property    | `proptest` + `proptest-derive` | Preferred over quickcheck. `proptest-derive` for `#[derive(Arbitrary)]` on domain types. |
| Snapshot    | `insta`                        | Only for large generated output                                                          |
| Mocking     | `mockall`                      | Only for four allowed cases in [Testing](testing.md)                                     |
| Async       | `tokio::test`                  | For async tests                                                                          |
| Fuzz        | `cargo-fuzz`                   | Parsers, validators, deserializers                                                       |
| Integration | `testcontainers`               | Real deps when absolutely needed                                                         |

## Fast vs Slow Split

Use a `tdd` feature flag to separate fast feedback tests from slower property/exhaustive tests. Default (`cargo nextest run`) runs everything. The `tdd` feature ignores slow tests for watch-mode speed.

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

Fast tests use only `#[test]` with no extra annotation. Fast tests never touch IO. If a test needs a database, filesystem, or network, it goes in `tests/`.

## Test Location and Layering

Tests live next to the code they exercise, organized by scope. See [Testing](testing.md) for the language-agnostic layering model.

### Layer 1: In-File Unit Tests

Tests that exercise functions defined in the same file. Always `#[cfg(test)] mod tests` at the bottom of the source file. If the file gets too long, the functions need splitting, not the tests.

Private/helper functions get direct, thorough testing with tight contracts. These are the atoms. Public orchestrating or composing functions are tested too, but designed to avoid redundancy with helper tests. Focus orchestration tests on composition correctness, not re-testing what helpers already cover.

Do not test imports. If an import changes, Layer 1 tests still pass.

Tests that verify data threading from downstream modules use `threads_through_from_<source>` in the name to signal passthrough fidelity intent.

```
src/application/line_classify.rs     // has #[cfg(test)] mod tests at bottom
src/application/text_collect.rs      // has #[cfg(test)] mod tests at bottom
src/domain/types.rs                  // has #[cfg(test)] mod tests at bottom
```

### Layer 2: Architecture-Layer Tests

Tests that exercise multiple files within the same architecture layer (e.g., multiple modules inside `application/`). If individual files are atoms, Layer 2 tests are molecules. These go in a `tests/` subdirectory or `tests.rs` file inside that layer's directory.

Only test public functions from the files. Avoid redundancy with Layer 1. Layer 2 tests verify cross-module composition that no single file's tests can cover.

```
src/application/tests/               // tests spanning multiple application modules
src/application/tests/proptest.rs    // property tests for the application layer
src/application/tests.rs             // alternative: single file instead of directory
```

Wire up layer tests in the layer's `mod.rs`:

```rust
// src/application/mod.rs
#[cfg(test)]
mod tests;
```

### Layer 3: Cross-Layer / Integration Tests

Tests that span multiple architecture layers or the full public API. These go in the top-level `tests/` directory (Cargo integration test convention). Layer 3 covers the whole crate, an API surface, or a full pipeline. This is where contract tests, integration tests, and cross-layer property tests live. Mostly not unit tests.

```
tests/
├── parse_integration.rs       // full pipeline tests
├── json_output.rs             // public API -> JSON serialization
└── proptest_integration.rs    // cross-layer property tests
```

### Directory Summary

```
src/
├── domain/
│   └── types.rs                 // Layer 1: #[cfg(test)] mod tests
├── application/
│   ├── line_classify.rs         // Layer 1: #[cfg(test)] mod tests
│   ├── text_collect.rs          // Layer 1: #[cfg(test)] mod tests
│   ├── document_parse.rs        // Layer 1: #[cfg(test)] mod tests
│   ├── mod.rs                   // wires up #[cfg(test)] mod tests
│   └── tests/                   // Layer 2: cross-module application tests
│       ├── mod.rs
│       └── proptest.rs          // #[cfg_attr(feature = "tdd", ignore)]
├── test_utils.rs                // builders, strategies, assert helpers (#[cfg(test)])
tests/                           // Layer 3: cross-layer integration tests
│   └── parse_integration.rs
fuzz/
└── fuzz_targets/
    └── parse_input.rs           // fuzz harnesses
```

## Result Assertions

`unwrap()` is OK in tests, but prefer explicit assertions for clarity and better error messages.

```rust
fn assert_ok<T, E: std::fmt::Debug>(result: Result<T, E>) -> T {
    match result {
        Ok(v) => v,
        Err(e) => panic!("expected Ok, got Err({:?})", e),
    }
}

fn assert_err<T: std::fmt::Debug, E>(result: Result<T, E>) -> E {
    match result {
        Err(e) => e,
        Ok(v) => panic!("expected Err, got Ok({:?})", v),
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
// Port (in app.rs)
#[async_trait::async_trait]
pub trait OrderRepo: Send + Sync {
    async fn save(&self, order: &Order) -> Result<(), RepoError>;
    async fn find_by_id(&self, id: &OrderId) -> Option<Order>;
}

// Fake (in test module or test_utils)
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
mod tests {
    use super::*;
    order_repo_contract!(|| async { FakeOrderRepo::new() });
}

// tests/integration/orders.rs: slow, real DB
order_repo_contract!(|| async { create_test_postgres_repo().await });
```

## Property Testing (proptest)

Property tests use `proptest` and `proptest-derive`. Mark them with `#[cfg_attr(feature = "tdd", ignore)]` so they are skipped in watch mode but run in full test suite.

### Proptest Scopes

Property tests follow the same layering as unit tests with one exception:

- Layer 1: test public/exported functions. Test private functions only if they contain tricky logic that gains significant value from independent property testing.
- Layer 2: test cross-module composition (e.g., classify then accumulate then finalize roundtrip).
- Layer 3: test full public API invariants.

### Inline with proptest! Macro

Strategy helpers and imports go outside `proptest!` but inside `mod tests`. The `#[test]` and `#[cfg_attr(...)]` annotations go inside the macro on each test function, not outside the macro block.

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    // Strategy helpers live here, outside proptest!
    fn valid_name() -> impl Strategy<Value = String> {
        "[a-z][a-z0-9]{0,15}"
    }

    // Unit tests
    #[test]
    fn basic_test() { /* ... */
    }

    // Property tests sit at same level as unit tests
    proptest! {
        #[test]
        #[cfg_attr(feature = "tdd", ignore)]
        fn serialize_parse_roundtrip(amount in 0i64..1_000_000) {
            let money = Money::from_cents(amount);
            let serialized = money.serialize();
            let parsed = Money::parse(&serialized).unwrap();
            prop_assert_eq!(money, parsed);
        }

        #[test]
        #[cfg_attr(feature = "tdd", ignore)]
        fn add_is_commutative(a in 0i64..1_000_000, b in 0i64..1_000_000) {
            let money_a = Money::from_cents(a);
            let money_b = Money::from_cents(b);
            prop_assert_eq!(money_a.add(&money_b), money_b.add(&money_a));
        }
    }
}
```

### proptest! Macro Gotchas

`prop_assert!` with `matches!` and `{ .. }` patterns fails because `{` and `}` are interpreted as format string placeholders. Extract to a let binding:

```rust
// BAD: compile error from format string interpretation
prop_assert!(matches!(result.warnings[0], ParseWarning::UnclosedFence { .. }));

// GOOD: extract to bool first
let is_unclosed = matches!(result.warnings[0], ParseWarning::UnclosedFence { .. });
prop_assert!(is_unclosed);
```

`prop_assert_eq!` moves values out of Vec indexes. Use references on both sides:

```rust
// BAD: move error when field doesn't implement Copy
prop_assert_eq!(result.commands[0].arguments.mode, ArgumentMode::Fence);

// GOOD: compare by reference
prop_assert_eq!(&result.commands[0].arguments.mode, &ArgumentMode::Fence);
```

### Proptest Regressions

When proptest finds a failing input, it automatically shrinks it to the minimal reproducing case and writes it to a `proptest-regressions/` file next to the test source. These are permanent regression tests that re-run the exact failing input on every future test run.

Rules:

- Commit `proptest-regressions/` files to version control.
- Never delete them, even after fixing the bug. They prevent the same class of failure from silently returning.
- Shrinking is automatic. The recorded case is already the simplest reproducer.
- If a regression case reveals a meaningful edge case, also add it as a named unit test with a descriptive name. The regression file ensures replay; the unit test documents intent.

```
src/application/
├── line_classify.rs
├── proptest-regressions/
│   └── line_classify.txt    # auto-generated, committed
```

### proptest.toml

Place a `proptest.toml` in the project root to control defaults. CI can override `cases` with a higher value for deeper coverage.

```toml
# proptest.toml
[default]
cases = 256
max_shrink_iters = 1000
```

### When to Use proptest-derive

Derive `Arbitrary` on domain types to auto-generate strategies without manual `prop_map` boilerplate.

```rust
use proptest::prelude::*;
use proptest_derive::Arbitrary;

#[derive(Debug, Clone, Arbitrary)]
pub struct Money {
    #[proptest(strategy = "0i64..1_000_000")]
    pub cents: i64,
}

proptest! {
    #[test]
    #[cfg_attr(feature = "tdd", ignore)]
    fn money_roundtrip(money: Money) {
        let serialized = money.serialize();
        let parsed = Money::parse(&serialized).unwrap();
        prop_assert_eq!(money, parsed);
    }
}
```

Use `proptest-derive` when the type maps cleanly to constrained primitives with independent fields. Use manual strategies when generation logic is more complex.

| Situation                                                          | Approach                                                    |
| ------------------------------------------------------------------ | ----------------------------------------------------------- |
| Fields are independent, constrained primitives                     | `#[derive(Arbitrary)]` with `#[proptest(strategy = "...")]` |
| Fields are interdependent (mode determines which fields are valid) | Manual strategy with `prop_map`                             |
| Natural input is a string, not a struct (parsers)                  | Regex strategy fed through the public function              |
| Need custom distributions or weighted generation                   | Manual strategy                                             |

## Custom Strategies

Place in `src/test_utils/arbitrary.rs` (behind `#[cfg(test)]`).

```rust
use proptest::prelude::*;

pub fn money_strategy() -> impl Strategy<Value = Money> {
    (0i64..1_000_000).prop_map(Money::from_cents)
}

pub fn order_item_strategy() -> impl Strategy<Value = OrderItem> {
    ("[a-zA-Z0-9]{1,20}", 1usize..100, money_strategy()).prop_map(|(sku, qty, price)| OrderItem {
        sku,
        quantity: qty,
        price,
    })
}

pub fn order_strategy() -> impl Strategy<Value = Order> {
    (
        "[a-f0-9]{8}",
        prop::collection::vec(order_item_strategy(), 1..10),
    )
        .prop_map(|(id, items)| Order {
            id: OrderId::new(&id),
            customer_id: CustomerId::new("test-cust"),
            items,
            status: OrderStatus::Draft,
        })
}
```

## Fuzz Testing

Target parsers, validators, and deserializers with `cargo-fuzz` (uses libFuzzer).

### Setup

```
cargo install cargo-fuzz
cargo fuzz init
cargo fuzz add parse_order
```

### Harness

```rust
// fuzz/fuzz_targets/parse_order.rs
#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if let Ok(s) = std::str::from_utf8(data) {
        // should never panic, regardless of input
        let _ = Order::parse(s);
    }
});
```

### Running

```
cargo fuzz run parse_order -- -max_total_time=300
```

### Corpus Management

```
fuzz/
├── corpus/parse_order/    # seed inputs + fuzzer discoveries
└── artifacts/parse_order/ # crash-triggering inputs
```

Crashes become permanent regression tests: minimize the input (`cargo fuzz tmin`), add it as a unit test, fix the bug.

### What to Fuzz

- JSON/YAML parsers and deserializers
- Newtype constructors that validate input (`Email::parse`, `OrderId::new`)
- Protocol decoders, query parsers
- Any function where arbitrary `&str` or `&[u8]` input should never panic

Don't fuzz: pure business logic (use property tests), database queries (use integration tests), external APIs (use contract tests).

## Injecting Dependencies

Use trait objects for time, randomness, and other non-deterministic deps.

```rust
pub trait Clock: Send + Sync {
    fn now(&self) -> DateTime<Utc>;
}

pub struct SystemClock;
impl Clock for SystemClock {
    fn now(&self) -> DateTime<Utc> {
        Utc::now()
    }
}

pub struct FixedClock(pub DateTime<Utc>);
impl Clock for FixedClock {
    fn now(&self) -> DateTime<Utc> {
        self.0
    }
}

pub fn is_expired(clock: &dyn Clock, order: &Order) -> bool {
    order.expires_at < clock.now()
}

#[test]
fn is_expired_past_date_returns_true() {
    let clock = FixedClock(Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap());
    let order = build_order_with(|o| {
        o.expires_at = Utc.with_ymd_and_hms(2024, 12, 31, 0, 0, 0).unwrap();
    });
    assert!(is_expired(&clock, &order));
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

#[test]
fn submit_draft_changes_status() {
    let order = build_order_with(|o| o.status = OrderStatus::Draft);
    let result = submit(order);
    assert_eq!(result.status, OrderStatus::Submitted);
}
```

## Test Module Organization

```
src/
├── orders/
│   ├── domain.rs          // #[cfg(test)] mod tests { unit tests }
│   ├── app.rs             // #[cfg(test)] mod tests { use case tests with fakes }
│   └── infra.rs           // #[cfg(test)] mod tests { contract tests against fake }
├── test_utils.rs           // builders, strategies, assert helpers (#[cfg(test)])
tests/
├── integration/
│   └── orders.rs           // contract tests against real Postgres (testcontainers)
fuzz/
└── fuzz_targets/
    └── parse_order.rs      // fuzz harnesses
```

- Layer 1 (in-file): `#[cfg(test)] mod tests` in same file (fast, function-scoped)
- Layer 2 (arch-layer): `src/<layer>/tests/` directory (fast, cross-module within layer)
- Layer 3 (cross-layer): `tests/` directory (integration, may need real deps)
- Shared test utils: `src/test_utils.rs` with `#[cfg(test)]`
- Fuzz targets: `fuzz/fuzz_targets/`

## Integration Tests with Testcontainers

Use testcontainers only when contract tests require a real implementation (database, message broker). Never in unit tests.

```rust
// tests/integration/orders.rs
use testcontainers::runners::AsyncRunner;
use testcontainers_modules::postgres::Postgres;

#[tokio::test]
async fn postgres_repo_contract() {
    let container = Postgres::default().start().await.unwrap();
    let port = container.get_host_port_ipv4(5432).await.unwrap();
    let pool = create_pool(&format!("postgres://postgres@localhost:{port}/postgres")).await;

    let repo = PostgresOrderRepo::new(pool);
    let order = build_order();
    repo.save(&order).await.unwrap();
    let found = repo.find_by_id(&order.id).await;
    assert_eq!(found, Some(order));
}
```

Prefer Podman over Docker when available. Testcontainers supports Podman via the `TESTCONTAINERS_RYUK_DISABLED=true` env var and Podman socket.

## Async Tests

```rust
#[tokio::test]
async fn fetch_user_returns_user() {
    let repo = FakeUserRepo::new();
    repo.save(&build_user()).await.unwrap();

    let result = fetch_user(&repo, &UserId::new("user-1")).await;
    assert!(result.is_ok());
}
```

Never poll or sleep-wait. If you need to wait for async work, await it directly. Sleep in tests indicates a design problem.

## Anti-Patterns

| Don't                                    | Do Instead                                 |
| ---------------------------------------- | ------------------------------------------ |
| `unwrap()` in library code               | `?` or typed error                         |
| `Box<dyn Trait>` when `impl Trait` works | `impl Trait` in return position            |
| `_ =>` catch-all hiding variants         | Enumerate all match arms                   |
| Clone to avoid borrow checker            | Fix ownership structure                    |
| Testcontainers in unit tests             | In-memory fakes                            |
| Sleep/poll waits in tests                | Await directly                             |
| Shared mutable test state                | Each test owns its data                    |
| Snapshot for domain objects              | `assert_eq!` with derived `PartialEq`      |
| `cargo test` for running                 | `cargo nextest run` for parallel execution |
| Property tests slowing watch mode        | `#[cfg_attr(feature = "tdd", ignore)]`     |
| Delete proptest regression files         | Keep them committed permanently            |

## Checklist

- [ ] `cargo-nextest` as test runner
- [ ] `tdd` feature flag in `Cargo.toml` for fast/slow split
- [ ] `proptest` + `proptest-derive` in `[dev-dependencies]`
- [ ] `proptest.toml` in project root with default case count
- [ ] `proptest-regressions/` files committed to version control
- [ ] Slow tests marked with `#[cfg_attr(feature = "tdd", ignore)]`
- [ ] Layer 1 tests in-file, Layer 2 in arch-layer `tests/`, Layer 3 in top-level `tests/`
- [ ] Layer 1: private helpers tested tightly, orchestration tests avoid redundancy
- [ ] Layer 1: tests do not test imports
- [ ] `assert_ok`/`assert_err` helpers for Result assertions
- [ ] Fakes implement port traits, compiler-checked
- [ ] Contract macro shared across fake (fast) and real (slow) impls
- [ ] `proptest` strategies for domain types
- [ ] Fuzz harnesses for parsers and validators
- [ ] Time/randomness via injected traits
- [ ] Builders with `build_X_with` closure pattern
- [ ] Unit tests in `#[cfg(test)] mod tests` (fast)
- [ ] Integration tests in `tests/` (slow)
- [ ] Testcontainers for real deps (integration only, Podman preferred)
- [ ] No `unwrap()` in non-test code
- [ ] No sleep/poll waits
- [ ] Each test owns its data
- [ ] `impl Trait` over `Box<dyn Trait>` in fakes
