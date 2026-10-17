# Universal Rust Engine → WASM/WASI → Polyglot SDK

Pattern for building a Rust library with WebAssembly distribution to multiple language runtimes.
Follows [Tom's Clean Code](toms-clean-code.md), [Rust Patterns](lang-rust.md),
[TypeScript](lang-typescript.md), [Python Patterns](lang-python.md),
[Tom's Clean Architecture](toms-clean-arch.md), [Testing](testing.md), and
[Rust Testing](testing-rust.md).

## When to Use

Apply this pattern when a Rust library needs to be consumed by multiple language runtimes (JS/TS,
Go, Python, PHP, C#, Zig) via WebAssembly. The engine logic is written once in Rust. Thin wrapper
crates produce WASM artifacts for each target ecosystem. Per-language SDKs provide idiomatic,
errors-as-values interfaces.

## Architecture

Three crate tiers in a Cargo workspace. The engine crate is the domain. Wrapper crates are
infrastructure adapters. SDKs are consumer-facing packages in each target language.

```text
SDK Packages (per-language idiomatic wrappers)
  js-sdk / py-sdk / go-sdk / cs-sdk
    ↓ consume .wasm artifacts
Wrapper Crates (infrastructure: thin adapters)
  {name}-wasm-js       {name}-component
  wasm-bindgen         wasm32-wasip2 / WIT
    ↓ depend on engine
Engine Crate (domain: pure logic)
  {name}-engine
  no_std + alloc, zero IO, zero serde
```

Dependencies point inward. Wrapper crates depend on engine. Engine knows nothing about WASM, JS
bindings, WIT, or serialization formats.

## Workspace Structure

```text
Cargo.toml              (workspace root; receives [workspace.lints] from configs/rust)
{name}-engine/
  Cargo.toml            ([lints] workspace = true)
  build.rs              (auto-generates #[test] functions from ../fuzz-core/regressions/)
  src/
    lib.rs              (public API facade)
    domain/             (types, invariants, pure logic)
    serialize.rs        (optional: DTO conversion, behind feature flag)
{name}-wasm-js/
  Cargo.toml            ([lints] workspace = true)
  src/lib.rs
{name}-component/
  Cargo.toml            ([lints] workspace = true)
  src/lib.rs
  wit/
    {namespace}/{name}.wit
fuzz-common/            (shared arbitrary::Arbitrary types)
fuzz-core/              (cargo-fuzz harnesses, corpus/, regressions/)
sdks/
  js/                   (npm package, tags: ["typescript"], consumes wasm-js pkg)
  python/               (pypi package, tags: ["python"], consumes component via wasmtime-py)
  go/                   (go module, consumes component via wasmtime-go)
  cs/                   (nuget package, consumes component via wasmtime-dotnet)
test-vectors/           (shared cross-SDK contract inputs/outputs, see Testing)
```

The `sdks/` directory is managed by Moonrepo alongside the Cargo workspace (`configs/rust`,
`configs/javascript`, and `configs/python` provide the tag-inherited `lint`, `typecheck`, `test`,
and `verify` tasks for each ecosystem).

## Engine Crate

The engine crate is a pure Rust library. All business logic, domain types, and core tests live
here. This is the single source of truth for behavior.

### Constraints

- `#![no_std]` with `extern crate alloc`. Maximum portability: embedded, WASM, kernel.
- Zero WASM-specific dependencies (no `wasm-bindgen`, no `wasi`, no runtime crates).
- Zero serialization dependencies in the default feature set (no `serde`, no `serde_json`).
- Deterministic, pure logic. No IO, no env access, no time, no threads, no randomness.
- `thiserror` for error types (library crate, not application; never `anyhow`).
- Domain types free of `serde` derives. Serialization is not the engine's concern.
- Follows domain purity rules from [Rust Patterns](lang-rust.md) and
  [Tom's Clean Architecture](toms-clean-arch.md).

### Feature Flags

```toml
# {name}-engine/Cargo.toml
[lints]
workspace = true

[features]
default = []
std = [] # Enables std-dependent code paths. Wrappers and native Rust consumers enable this.
serde = [
  "dep:serde",
  "dep:serde_json",
] # Enables Serialize on output DTOs for consumers that want JSON.

[dependencies]
thiserror = { version = "2", default-features = false }
serde = { version = "1", default-features = false, features = ["derive", "alloc"], optional = true }
serde_json = { version = "1", default-features = false, features = ["alloc"], optional = true }
```

Feature flags are additive only (Cargo convention). The `serde` feature enables serialization on
output DTO types, not on domain types. The engine compiles and is fully functional with zero
features enabled.

### Public API

The engine returns typed Rust data. No serialization at this layer. The public API is the `lib.rs`
facade that re-exports the types and functions consumers need.

```rust
// {name}-engine/src/lib.rs
#![no_std]
extern crate alloc;

mod domain;
mod parse; // or whatever the engine does

// Public API: typed Rust structs and functions
pub use domain::{Argument, ArgumentMode, Command};
pub use parse::{ParseError, parse};
```

```rust
// Engine returns typed Result, not strings
pub fn parse(input: &str) -> Result<Vec<Command>, ParseError> { /* ... */
}
```

Native Rust consumers get zero-cost typed access. WASM wrappers handle serialization at the
boundary.

### Error Types

```rust
#[derive(Debug, thiserror::Error)]
pub enum ParseError {
    #[error("invalid syntax at position {position}: {message}")]
    InvalidSyntax {
        position: usize,
        message: alloc::string::String,
    },

    #[error("unexpected end of input")]
    UnexpectedEof,
}
```

Error types are exhaustive, typed, and use business language. No transport concepts. Full variant
data is included so consumers have enough information to resolve the error.

### JSON Serialization (Behind Feature Flag)

When the `serde` feature is enabled, a `serialize` module provides DTO types with `Serialize` and
conversion functions. Domain types remain `serde`-free.

```rust
// {name}-engine/src/serialize.rs
#[cfg(feature = "serde")]
pub mod json {
    use alloc::vec::Vec;
    use serde::Serialize;

    use crate::domain;

    #[derive(Debug, Serialize)]
    pub struct CommandDto {
        pub name: alloc::string::String,
        pub args: Vec<ArgumentDto>,
    }

    impl From<&domain::Command> for CommandDto {
        fn from(cmd: &domain::Command) -> Self { /* field mapping */
        }
    }

    pub fn to_json(
        commands: &[domain::Command],
    ) -> Result<alloc::string::String, serde_json::Error> {
        let dtos: Vec<CommandDto> = commands.iter().map(Into::into).collect();
        serde_json::to_string(&dtos)
    }
}
```

## JS WASM Crate (`wasm-bindgen`)

Thin adapter for JavaScript runtimes (browser, Node, Bun, Deno).

### Cargo.toml

```toml
# {name}-wasm-js/Cargo.toml
[lints]
workspace = true

[lib]
crate-type = ["cdylib"]

[dependencies]
{name}-engine = { path = "../{name}-engine", features = ["std", "serde"] }
wasm-bindgen = "0.2"
```

### API

```rust
use wasm_bindgen::prelude::*;
use {name}_engine::{parse, serialize::json};

#[wasm_bindgen]
pub fn parse(text: &str) -> String {
    match {name}_engine::parse(text) {
        Ok(commands) => json::to_json(&commands).unwrap_or_else(|e| {
            error_json("serialization_error", &e.to_string())
        }),
        Err(err) => error_json(&err.variant_name(), &err.to_string()),
    }
}

fn error_json(error_type: &str, message: &str) -> String {
    format!(r#"{{"error":{{"type":"{error_type}","message":"{message}"}}}}"#)
}
```

Errors are encoded as JSON rather than thrown across the WASM boundary. The TypeScript SDK parses
the payload and returns a `neverthrow` `Result<Command[], ParseError>` (`Ok` / `Err`), keeping
control flow exception-free.

### Build

```bash
# Direct wasm-bindgen CLI (no wasm-pack, post-sunset)
cargo build -p {name}-wasm-js --target wasm32-unknown-unknown --release
wasm-bindgen target/wasm32-unknown-unknown/release/{name}_wasm_js.wasm \
  --out-dir sdks/js/pkg --target bundler
```

## Component Crate (WASI P2)

Thin adapter for non-JS runtimes via the WebAssembly Component Model.

### WIT Interface

```wit
// {name}-component/wit/{namespace}/{name}.wit
package {namespace}:{name}@0.1.0;

world engine {
    record command {
        name: string,
        args: list<argument>,
    }

    record argument {
        value: string,
        mode: argument-mode,
    }

    enum argument-mode {
        positional,
        flag,
        key-value,
    }

    variant parse-error {
        invalid-syntax(syntax-detail),
        unexpected-eof,
    }

    record syntax-detail {
        position: u32,
        message: string,
    }

    /// Parse input text and return structured commands.
    export parse: func(text: string) -> result<list<command>, parse-error>;
}
```

WIT native types are preferred over JSON strings. WIT `result<T, E>` carries full variant and field
data mapped 1:1 to the engine's `ParseError` enum.

### Implementation

```rust
use {name}_engine;

wit_bindgen::generate!({
    path: "wit",
    world: "engine",
});

struct Component;

impl exports::{namespace}::{name}::engine::Guest for Component {
    fn parse(text: String) -> Result<Vec<Command>, ParseError> {
        {name}_engine::parse(&text)
            .map(|cmds| cmds.into_iter().map(Into::into).collect())
            .map_err(Into::into)
    }
}

impl From<{name}_engine::Command> for Command { /* field mapping */ }
impl From<{name}_engine::ParseError> for ParseError { /* variant mapping */ }

export!(Component);
```

### Build

```bash
cargo component build -p {name}-component --release
# Output: target/wasm32-wasip2/release/{name}_component.wasm
```

### Downstream Consumers

| Language | Runtime                                           | Binding            |
| -------- | ------------------------------------------------- | ------------------ |
| Go       | wasmtime-go                                       | Generated from WIT |
| Python   | wasmtime-py                                       | Generated from WIT |
| C#       | wasmtime-dotnet                                   | Generated from WIT |
| Zig      | [OPEN: evaluate wasmtime-zig or direct embedding] | TBD                |

## SDK Packages

Per-language idiomatic wrappers that consumers actually install.

### Tier Classification

| Tier | Languages                                          | Meaning                                                             |
| ---- | -------------------------------------------------- | ------------------------------------------------------------------- |
| 1    | JS/TS (browser), JS/TS (Node/Bun/Deno), Python, Go | First-class. Tested in CI. Breaking changes require migration path. |
| 2    | C#, Zig                                            | Supported. Tested in CI. Community contributions welcomed.          |
| 3    | Everything else                                    | Community-maintained. PRs welcomed. Not tested in main CI.          |

### JS/TS SDK (`sdks/js/`)

Follows [TypeScript](lang-typescript.md) (`tags: ["typescript"]`, linted by `oxlint` +
`@tack/eslint-config`). Wraps the `wasm-bindgen` output in pure functions returning `neverthrow`
`Result<T, E>`:

```text
sdks/js/
  moon.yml            (tags: ["typescript"])
  package.json
  src/
    index.ts          (public API: parse(text): Result<readonly Command[], ParseError>)
    wasm-loader.ts    (init/load wasm module)
  pkg/                (generated by wasm-bindgen build, gitignored)
  tests/
    parse.test.ts     (vitest)
```

### Python SDK (`sdks/python/`)

Follows [Python Patterns](lang-python.md) (`tags: ["python"]`, linted by `ruff` + `basedpyright`).
Exposes frozen dataclasses and pure functions returning union results (`tuple[Command, ...] | ParseError`):

```text
sdks/python/
  moon.yml            (tags: ["python"])
  pyproject.toml
  src/{name}/
    __init__.py       (public API: parse(text: str) -> tuple[Command, ...] | ParseError)
    _wasm.py          (wasmtime component instantiation — adapter boundary)
  tests/
    test_parse.py     (pytest)
  {name}_component.wasm
```

## Error Handling (Errors as Values Across Every Boundary)

| Layer             | Error Type                          | Approach                                                       |
| ----------------- | ----------------------------------- | -------------------------------------------------------------- |
| Engine (domain)   | `ParseError` enum                   | `thiserror`, typed, exhaustive                                 |
| Component wrapper | WIT `result<T, parse-error>`        | Map engine error variants to WIT variants 1:1                  |
| JS wrapper        | JSON-encoded error string           | Convert `ParseError` to `{"error": {"type", "message", ...}}`  |
| JS/TS SDK         | `Result<readonly Command[], Error>` | `neverthrow` `Ok` / `Err` (no `throw`)                         |
| Python SDK        | `tuple[Command, ...] \| ParseError` | Frozen error dataclass union (no exceptions for domain errors) |
| Go SDK            | `([]Command, error)`                | Standard Go `(T, error)` value tuple                           |

### Rules

- Engine errors never reference transport concepts (no HTTP status, no exit codes).
- Wrapper crates never `unwrap()`, `expect()`, or `panic!()`. All engine errors are converted.
- First-party SDKs preserve **errors as values** (`Result<T, E>` in TS, union return in Python,
  `(T, error)` in Go) rather than throwing exceptions for expected domain failures.

## Testing

Follows [Testing](testing.md) and [Rust Testing](testing-rust.md).

### Engine Crate (Where Coverage Matters)

All logic tests live in `{name}-engine`:

- **Layer 1**: `#[cfg(test)] #[allow(clippy::panic, clippy::unwrap_used, clippy::expect_used)] mod tests` in each source file.
- **Layer 2**: `src/<feature>/tests/` directory for cross-module composition and `proptest` suites.
- **Layer 3**: Top-level `tests/` for full public API invariants.
- **Fuzz**: `fuzz-common` + `fuzz-core` + `{name}-engine/build.rs` auto-regression generation for
  `parse()` and any function accepting `&str` or `&[u8]`.

### Wrapper Crates & SDK Tests

- **JS crate**: Verify `parse()` returns valid JSON for valid input and JSON error for invalid input.
- **Component crate**: Rust integration test instantiating the component via Wasmtime.
- **SDK tests**: Each SDK tests only its own binding glue (`vitest` for JS/TS, `pytest` for Python)
  and runs the shared `test-vectors/` suite.

## Memory and Performance

- **UTF-8 everywhere**: Canonical encoding at every boundary.
- **WASM Linear Memory**: Defaults to 256 pages (16MB). Set explicit memory limits in Wasmtime
  instantiation and document max input size.

## Versioning and Compatibility

- `{name}-engine`, `{name}-wasm-js`, `{name}-component`, and the WIT package version together in
  root `[workspace.package]`.
- SDK packages (`sdks/js/`, `sdks/python/`, `sdks/go/`) version independently and expose
  `engine_version()`.
- Pin `wasm-bindgen`, `wasm-bindgen-cli`, `cargo-component`, `wit-bindgen`, and `wasmtime` to exact
  versions.

## Anti-Patterns

| Don't                                    | Do Instead                                               |
| ---------------------------------------- | -------------------------------------------------------- |
| Parsing/business logic in wrapper crates | All logic in `{name}-engine`                             |
| `serde` derives on domain types          | DTO conversion in `serialize` module behind feature flag |
| `unwrap()`/`panic!()` in wrapper crates  | Serialize errors to JSON or WIT error variants           |
| Throwing exceptions in TS/Python SDKs    | Return `Result<T, E>` (TS) or `T \| ParseError` (Python) |
| Shared mutable state in engine           | Pure functions, deterministic                            |
| Host-specific code in engine             | Engine is host-agnostic, `no_std`                        |
| Per-language engine forks                | Single Rust engine, WASM distribution                    |
| JSON strings over WIT interface          | WIT native types; JSON only for `wasm-bindgen` path      |
| `wasm-pack` for builds                   | `wasm-bindgen` CLI directly                              |
| Testing engine logic from SDK tests      | SDKs test their own glue; engine tests own logic         |

## Checklist

- [ ] Engine crate `#![no_std]` + `extern crate alloc`, zero WASM/runtime deps, zero default `serde`
- [ ] Engine crate `serde` and `std` additive feature flags
- [ ] All Cargo workspace members set `[lints] workspace = true` (`configs/rust` applied)
- [ ] Engine crate returns typed `Result<T, E>` with `thiserror`
- [ ] Engine crate owns unit, `proptest`, and `fuzz-common` + `fuzz-core` + `build.rs` tests
- [ ] JS wrapper built with `wasm-bindgen` CLI; JS SDK (`tags: ["typescript"]`) returns `neverthrow` `Result`
- [ ] Component wrapper targets `wasm32-wasip2` with WIT native types and `result<T, E>`
- [ ] Python SDK (`tags: ["python"]`) returns frozen dataclasses and union error types
- [ ] WIT package version tracks engine version; SDKs version independently
- [ ] Toolchain versions pinned (`wasm-bindgen`, `cargo-component`, `wit-bindgen`, `wasmtime`)
