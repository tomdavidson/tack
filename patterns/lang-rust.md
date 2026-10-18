# Rust Patterns

> Rust-specific implementation choices for [Tom's Clean Code](toms-clean-code.md). Specifies
> preferred approach when Rust allows multiple. When Rust offers both an OOP-like option and a
> functional option, always choose the functional option.

## Strategic FP Philosophy

Rust sits at the intersection of Go-style data simplicity and Haskell/Erlang-style algebraic types
and explicit error handling:

- **Data and behavior are separate**: `struct` and `enum` model pure data and state transitions;
  free functions implement domain behavior.
- **Make illegal states unrepresentable**: sum types (`enum`) with compiler-enforced exhaustive
  `match` replace boolean flags, nullable fields, and OOP class hierarchies.
- **Errors are values**: `Result<T, E>` with typed `thiserror` domain/application enums and `?`
  railway propagation. Panics are never an error-handling strategy.
- **Zero nested branches in control loops**: guard clauses (`let ... else { return ... }`) and
  iterator pipelines (`filter_map`, `find_map`) keep control flow flat.

Rules below are split into **Toolchain-Enforced** (backed by `.rustfmt.toml`, `.clippy.toml`, and
`clippy-cargo.merge.toml`) and **Advisory** (enforced via code review and architecture boundaries
until AST/lint tooling covers them).

---

## Part 1: Toolchain-Enforced Rules

### 1. Function Size, Complexity, and Flat Control Flow

Configured in `configs/rust/.clippy.toml` and `configs/rust/clippy-cargo.merge.toml`:

| Rule / Threshold                 | Setting | Purpose                                                      |
| -------------------------------- | ------- | ------------------------------------------------------------ |
| `too-many-lines-threshold`       | `30`    | Keep functions small (5–30 lines)                            |
| `too-many-arguments-threshold`   | `4`     | 2–3 params typical; 4+ requires an input/context struct      |
| `cognitive-complexity-threshold` | `8`     | Cap branching and loop complexity (`cognitive_complexity`)   |
| `excessive-nesting-threshold`    | `2`     | Forbid nested branches inside loops (`excessive_nesting`)    |
| `max-fn-params-bools`            | `1`     | Replace boolean flag parameters with a 2-variant `enum`      |
| `max-struct-bools`               | `2`     | Replace boolean-bag structs with explicit state `enum`s      |
| `manual_let_else`                | `warn`  | Use `let Some(x) = ... else { return ... }` guard clauses    |
| `redundant_else`                 | `deny`  | No `else` after `return`, `break`, or `continue`             |
| `collapsible_if`                 | `allow` | Keep guard clauses separate when each checks a distinct rule |

```rust
// GOOD — flat guard clauses with let-else, zero nesting
pub fn validate_order(repo: &dyn OrderRepo, id: &OrderId) -> Result<Order, OrderError> {
    let Some(order) = repo.find_by_id(id) else {
        return Err(OrderError::NotFound(id.clone()));
    };
    if order.status != OrderStatus::Draft {
        return Err(OrderError::NotEditable(order.status));
    }
    if order.items.is_empty() {
        return Err(OrderError::EmptyOrder);
    }
    Ok(order)
}
```

Never put nested `if`/`match` branches inside a `for` loop. Extract the per-element decision into a
named pure function and compose with an iterator pipeline.

### 2. Explicit Errors as Data

Enforced in `[workspace.lints.clippy]` (`clippy-cargo.merge.toml`):

| Lint                 | Level  | Rule                                                                |
| -------------------- | ------ | ------------------------------------------------------------------- |
| `unwrap_used`        | `deny` | Never `.unwrap()` in non-test code; propagate with `?`              |
| `expect_used`        | `deny` | Never `.expect()` in non-test code                                  |
| `panic`              | `deny` | Panics are not an error strategy in library or application code     |
| `panic_in_result_fn` | `deny` | Functions returning `Result` must never panic                       |
| `unimplemented`      | `deny` | Do not ship `unimplemented!()`                                      |
| `fallible_impl_from` | `deny` | Fallible conversions must implement `TryFrom`/`TryInto`, not `From` |
| `match_wild_err_arm` | `deny` | No `Err(_)` wildcards; match error variants exhaustively            |
| `try_err`            | `deny` | Return `Err(...)` directly instead of `Err(...)?`                   |

- `thiserror` for typed errors in libraries, domain, and application layers
- `anyhow` or `miette` in binary entry points (`main.rs`) and top-level CLI reporting only
- `?` for railway propagation; combinators (`map`, `and_then`, `ok_or`, `ok_or_else`) when they
  read cleaner than `match`
- Skip `Result` for infallible operations where wrapping adds noise without safety

```rust
// GOOD — ? for propagation
fn place_order(repo: &dyn OrderRepo, cmd: PlaceOrderCmd) -> Result<OrderId, PlaceOrderError> {
    let order = Order::create(cmd)?;
    repo.save(&order)?;
    Ok(order.id)
}

// GOOD — combinators when they simplify
fn find_active_user(repo: &dyn UserRepo, id: &UserId) -> Result<User, UserError> {
    repo.find(id)
        .ok_or_else(|| UserError::NotFound(id.clone()))?
        .ensure_active()
}
```

#### Test-Module Clippy Allowance

Because `unwrap_used`, `expect_used`, and `panic` are denied workspace-wide (and `assert!`/`prop_assert!`
expand to `panic!`), annotate test modules explicitly:

```rust
#[cfg(test)]
#[allow(clippy::panic, clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    // unit and property tests
}
```

### 3. Pattern Matching & Exhaustiveness

Rust's `match` is exhaustive by default—strictly stronger than TypeScript's `switch` + `assertNever`
because the compiler enforces it natively.

| Lint                                 | Level  | Rule                                                  |
| ------------------------------------ | ------ | ----------------------------------------------------- |
| `wildcard_enum_match_arm`            | `warn` | Enumerate every enum variant; avoid `_ =>` catch-alls |
| `match_wildcard_for_single_variants` | `warn` | Never use `_ =>` to match a single remaining variant  |
| `enum_glob_use`                      | `deny` | Always qualify enum variants (`OrderStatus::Draft`)   |

```rust
// GOOD — exhaustive match breaks at compile time when a variant is added
match order.status {
    OrderStatus::Draft => allow_edit(order),
    OrderStatus::Submitted | OrderStatus::Cancelled => {
        Err(OrderError::NotEditable(order.status))
    }
}

// BAD — silent catch-all hides new variants
match order.status {
    OrderStatus::Draft => allow_edit(order),
    _ => Err(OrderError::NotEditable(order.status)),
}
```

### 4. Iteration & Pipeline Composition

| Lint                                 | Level  | Rule                                                          |
| ------------------------------------ | ------ | ------------------------------------------------------------- |
| `manual_filter_map`                  | `warn` | Prefer `.filter_map(...)` over `.filter(...).map(...)`        |
| `manual_find_map`                    | `warn` | Prefer `.find_map(...)` over `.find(...).map(...)`            |
| `needless_collect`                   | `warn` | Chain to the end and `.collect()` once; no intermediate Vec   |
| `redundant_closure_for_method_calls` | `warn` | Use point-free method references (`Result::ok`) when clear    |
| `inherent_to_string`                 | `deny` | Implement `std::fmt::Display` instead of inherent `to_string` |

- Iterator chains over `for` loops as the default (declarative, composable)
- Accept `impl IntoIterator<Item = T>` when flexible collection inputs help callers
- Use a simple `for` loop with `?` early return when lifetimes or fallible body steps make an
  iterator chain harder to read

```rust
// GOOD — declarative iterator pipeline
let active_emails: Vec<&str> = users
    .iter()
    .filter(|u| u.is_active)
    .map(|u| u.email.as_str())
    .collect();

// GOOD — filter_map with point-free conversion
let valid_orders: Vec<Order> = inputs
    .into_iter()
    .filter_map(|raw| Order::try_from(raw).ok())
    .collect();
```

### 5. String, Borrowing, and Copy Hygiene

| Lint                       | Level  | Rule                                                      |
| -------------------------- | ------ | --------------------------------------------------------- |
| `ptr_arg`                  | `warn` | Take `&str` over `&String` and `&[T]` over `&Vec<T>`      |
| `cloned_instead_of_copied` | `warn` | Use `.copied()` and derive `Copy` on small newtypes/enums |
| `write_with_newline`       | `deny` | Use `writeln!()` instead of `write!(...\n)`               |

- `&str` and `&[T]` for function parameters that only read
- `String` and `Vec<T>` for owned data in structs and return values
- `impl Into<String>` for constructors where the caller may pass `&str` or `String`

```rust
// GOOD — accepts &str, caller decides allocation
pub fn parse_email(raw: &str) -> Result<Email, ParseError> { ... }

// GOOD — constructor takes ownership flexibly
impl UserId {
    pub fn new(raw: impl Into<String>) -> Self { Self(raw.into()) }
    pub fn as_str(&self) -> &str { &self.0 }
}
```

### 6. Imperative Shell, Safety, and Agent-Safety Lints

| Lint                            | Level    | Rule                                                          |
| ------------------------------- | -------- | ------------------------------------------------------------- |
| `unsafe_code` (`lints.rust`)    | `forbid` | No `unsafe` blocks unless explicitly justified at crate level |
| `missing_debug_implementations` | `warn`   | Derive `Debug` on all public types                            |
| `unreachable_pub`               | `warn`   | Keep module visibility intentional (`pub(crate)` vs `pub`)    |
| `dbg_macro`                     | `deny`   | Never commit `dbg!()`                                         |
| `print_stdout` / `print_stderr` | `warn`   | Use structured `tracing`; explicitly `#[allow]` in CLI output |
| `todo`                          | `warn`   | Surface unfinished `todo!()` macros                           |
| `large_enum_variant`            | `warn`   | Box oversized error or AST variants                           |

**Agent-Safety Suppressions**: Three `pedantic` lints are explicitly set to `allow` in
`clippy-cargo.merge.toml` because their auto-fix suggestions push code toward OOP anti-patterns:

- `new_without_default = "allow"`: prevents Clippy from demanding `Default` on validated newtypes
  whose zero value would violate domain invariants.
- `wrong_self_convention = "allow"`: prevents Clippy from pressuring free functions (`is_*`, `to_*`,
  `from_*`) into becoming `&self` methods.
- `should_implement_trait = "allow"`: prevents Clippy from demanding `std::str::FromStr` or operator
  traits when a domain `parse` function has a more specific signature.

### 7. Formatting (`.rustfmt.toml` + `dprint.json`)

Always format with `moon run :fmt` (`dprint fmt`, which delegates Rust files to `rustfmt`):

- Edition `2024`, `max_width = 110`, `tab_spaces = 4`, `use_field_init_shorthand = true`
- Compact single-line expressions (`fn_single_line = true`, `use_small_heuristics = "Max"`)
- Sorted modules and crate-grouped imports (`imports_granularity = "Crate"`,
  `group_imports = "StdExternalCrate"`)

---

## Part 2: Advisory Patterns (Architecture & Code Review)

> These patterns cannot yet be enforced automatically by Clippy alone. Treat them as mandatory
> review standards until dedicated AST or `cargo-deny` rules enforce them.

### 1. Module & Crate Structure

Organize by feature. Inside each feature, separate by architectural layer:

```text
src/
├── orders/
│   ├── mod.rs           // re-exports public API
│   ├── domain.rs        // types, enums, invariants, pure logic
│   ├── app.rs           // use cases, orchestration, port traits
│   └── infra.rs         // adapters: HTTP handlers, DB repos, clients
├── inventory/
│   ├── mod.rs
│   ├── domain.rs
│   ├── app.rs
│   └── infra.rs
├── shared/
│   └── types.rs         // cross-cutting newtypes, shared value objects
└── main.rs              // composition root: wire deps, start runtime
```

- Domain imports nothing outside `std` and `shared`. Application imports domain. Infrastructure
  imports both.
- Re-export the public surface from each feature's `mod.rs` so callers use
  `crate::orders::place_order` rather than reaching into internal layer modules.
- When a feature reaches 5+ files per layer, promote `domain.rs` to `domain/mod.rs` with focused
  submodules (`domain/types.rs`, `domain/invariants.rs`).
- For multi-crate workspaces (see [Rust CLI Pattern](rust-cli-pattern.md) and
  [Universal Rust / WASM / TS Library](universal-rust-wasm-sdk-lib.md)), keep all pure domain and
  pipeline logic in a single `*-core` or `*-engine` library crate and keep `*-cli` as a thin
  imperative shell.

### 2. Domain Purity (Zero Serialization/IO in Domain)

Domain modules compile with zero external dependencies—no `serde`, no `tokio`, no HTTP/DB crates.
DTOs in the infrastructure layer handle wire formats via `From` and `TryFrom` conversions:

```rust
// domain.rs — pure, no serde
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Order {
    pub id: OrderId,
    pub customer_id: CustomerId,
    pub items: Vec<OrderItem>,
    pub status: OrderStatus,
}

// infra.rs — serde lives at the boundary
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct OrderDto {
    pub id: String,
    pub customer_id: String,
    pub items: Vec<OrderItemDto>,
    pub status: String,
}

impl TryFrom<OrderDto> for Order {
    type Error = DomainParseError;
    fn try_from(dto: OrderDto) -> Result<Self, Self::Error> {
        Ok(Self {
            id: OrderId::parse(&dto.id)?,
            customer_id: CustomerId::parse(&dto.customer_id)?,
            items: dto
                .items
                .into_iter()
                .map(OrderItem::try_from)
                .collect::<Result<_, _>>()?,
            status: OrderStatus::parse(&dto.status)?,
        })
    }
}
```

Violation test: _"Would removing `serde` from `Cargo.toml` break this domain file?"_ If yes, move
the serialization type to infrastructure.

### 3. Free Functions Over Methods

- Write domain and application logic as **free pure functions** (`pub fn add_item(order: &Order, item: OrderItem) -> Result<Order, OrderError>`), not OOP methods on data structs.
- Reserve `impl` blocks for construction (`new`, `parse`), trait implementations (`From`, `TryFrom`,
  `Display`, `AsRef`), and trivial value-object accessors (`as_str`).

### 4. Boundary Immutability & Intentional Cloning

- Immutability is enforced at function signatures: take shared borrows (`&T`) and return new values
  using struct update syntax (`Order { status: OrderStatus::Submitted, ..order.clone() }`).
- Local `let mut` inside a function body (e.g., building a `Vec` before returning it) is idiomatic
  when it never escapes the function.
- Never `.clone()` to silence the borrow checker in domain code; restructure ownership or borrow
  slices/references instead. Cloning is appropriate at IO/concurrency boundaries (`tokio::spawn`,
  channel sends, DTO construction).

### 5. Async Only at IO Boundaries

- Domain logic is always synchronous and pure.
- Use `tokio::try_join!` / `tokio::join!` for independent concurrent IO, then pass the fetched
  values into synchronous pure functions.
- Never mutate shared local variables across `.await` suspension points.
- Avoid `async` altogether in sequential CLI tools and pure libraries.

### 6. Explicit Dependency Injection (No Containers)

Wire dependencies by hand in `main.rs`. Pass ports as generic type parameters (`impl OrderRepo`) on
hot paths or when using native `async fn` in traits, or as `&dyn OrderRepo` when object safety
simplifies application signatures.

### 7. Error Layering

Three layers, three error types, explicit mapping at each boundary (matches
[Tom's Clean Architecture](toms-clean-arch.md)):

```rust
#[derive(Debug, thiserror::Error)]
pub enum OrderError {
    #[error("order not editable in status {0}")]
    NotEditable(OrderStatus),
    #[error("item limit exceeded: max {0}")]
    ItemLimitExceeded(usize),
}

#[derive(Debug, thiserror::Error)]
pub enum PlaceOrderError {
    #[error(transparent)]
    Order(#[from] OrderError),
    #[error("repository failure: {0}")]
    RepoFailure(String),
}
```

---

## Approved Libraries

| Status      | Crate                                 | Use Case                                  |
| ----------- | ------------------------------------- | ----------------------------------------- |
| ✅ Required | `thiserror`                           | Typed error enums in domain/app/libs      |
| ✅ Approved | `anyhow` / `miette`                   | Top-level binary error reporting only     |
| ✅ Approved | `clap` + `schematic`                  | CLI argument parsing & layered config     |
| ✅ Approved | `serde` + `serde_json`                | Serialization (infrastructure layer only) |
| ✅ Approved | `tokio` + `async-trait`               | Async runtime & object-safe async ports   |
| ✅ Approved | `tracing` + `tracing-subscriber`      | Structured diagnostics                    |
| ✅ Approved | `proptest` + `proptest-derive`        | Property-based testing                    |
| ✅ Approved | `insta`                               | Snapshot testing (large output only)      |
| ❌ Banned   | ORMs (`diesel`, `sea-orm`), DI crates | Hide SQL/control flow and encourage OOP   |

## Anti-Patterns

| Smell                                | Problem                              | Instead                               |
| ------------------------------------ | ------------------------------------ | ------------------------------------- |
| `unwrap()` / `expect()` in lib code  | Panics on unexpected input           | `?` or typed `Result` combinators     |
| Nested `if`/`match` inside loops     | High cognitive load (`max-depth`)    | Guard clauses (`let else`) + helpers  |
| `_ =>` catch-all on domain enum      | Silently ignores new variants        | Exhaustive `match` arms               |
| OOP methods on domain structs        | Couples data shape to use-case logic | Free pure functions                   |
| Boolean flag parameters              | Call sites (`process(x, true)`)      | Two-variant `enum`                    |
| `clone()` to silence borrow checker  | Masks ownership design issue         | Borrow `&str` / `&[T]` or restructure |
| `serde` derives on core domain types | Couples domain to wire format        | Infrastructure DTOs + `TryFrom`       |
| `async` on pure computation          | Infectious colored functions         | Synchronous pure functions            |

## Checklist

- [ ] Toolchain-enforced: `configs/rust` applied (`.rustfmt.toml`, `.clippy.toml`, `clippy-cargo.merge.toml`)
- [ ] Functions ≤ 30 lines, ≤ 4 parameters, cognitive complexity ≤ 8, nesting depth ≤ 2
- [ ] Guard clauses (`let ... else`) with zero `else` after `return`
- [ ] `thiserror` in library/domain/app crates; `anyhow`/`miette` in binary crate only
- [ ] Zero `unwrap()`, `expect()`, or `panic!()` outside test modules
- [ ] Test modules annotated with `#[allow(clippy::panic, clippy::unwrap_used, clippy::expect_used)]`
- [ ] Exhaustive `match` without `_ =>` wildcards on domain and error enums
- [ ] `&str` and `&[T]` for read parameters; `Copy` derived on small newtypes and enums
- [ ] Advisory: feature-based module layout (`domain.rs`, `app.rs`, `infra.rs`)
- [ ] Advisory: domain modules free of `serde` and IO crates
- [ ] Advisory: free pure functions for domain logic; `impl` only for construction and traits
- [ ] Advisory: async restricted to IO boundaries; zero mutable state across `.await` points
