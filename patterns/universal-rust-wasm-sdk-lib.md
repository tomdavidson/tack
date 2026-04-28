# Universal Rust Engine → WASM/WASI → Polyglot SDK

Pattern for building a Rust library with WebAssembly distribution to multiple language runtimes. Follows Tom's Clean Code, Rust Patterns, Tom's Clean Architecture, and Testing.

## When to Use

Apply this pattern when a Rust library needs to be consumed by multiple language runtimes (JS/TS, Go, Python, C#, Zig) via WebAssembly. The engine logic is written once in Rust. Thin wrapper crates produce WASM artifacts for each target ecosystem. Per-language SDKs provide idiomatic interfaces.

## Architecture

Three crate tiers in a Cargo workspace. The engine crate is the domain. Wrapper crates are infrastructure adapters. SDKs are consumer-facing packages in each target language.

```
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

Dependencies point inward. Wrapper crates depend on engine. Engine knows nothing about WASM, JS bindings, WIT, or serialization formats.

## Workspace Structure

```
Cargo.toml              (workspace root)
{name}-engine/
  Cargo.toml
  src/
    lib.rs              (public API facade)
    domain/             (types, invariants, pure logic)
    serialize.rs        (optional: DTO conversion, behind feature flag)
{name}-wasm-js/
  Cargo.toml
  src/lib.rs
{name}-component/
  Cargo.toml
  src/lib.rs
  wit/
    {namespace}/{name}.wit
sdks/
  js/                   (npm package, consumes wasm-js pkg)
  python/               (pypi package, consumes component via wasmtime-py)
  go/                   (go module, consumes component via wasmtime-go)
  cs/                   (nuget package, consumes component via wasmtime-dotnet)
test-vectors/           (shared cross-SDK contract inputs/outputs, see Testing)
```

The `sdks/` directory is managed by Moonrepo alongside the Cargo workspace. SDK-specific tooling (npm, pip, go mod) lives in each subdirectory. See project-specific Moonrepo configuration for task orchestration details.

## Engine Crate

The engine crate is a pure Rust library. All business logic, domain types, and core tests live here. This is the single source of truth for behavior.

### Constraints

- `#![no_std]` with `extern crate alloc`. Maximum portability: embedded, WASM, kernel.
- Zero WASM-specific dependencies (no wasm-bindgen, no wasi, no runtime crates).
- Zero serialization dependencies in the default feature set (no serde, no serde_json).
- Deterministic, pure logic. No IO, no env access, no time, no threads, no randomness.
- `thiserror` for error types (library crate, not application; never `anyhow`).
- Domain types free of `serde` derives. Serialization is not the engine's concern.
- Follows domain purity rules from Rust Patterns and Tom's Clean Architecture.

### Feature Flags

```toml
# {name}-engine/Cargo.toml
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

Feature flags are additive only (Cargo convention). The `serde` feature enables serialization on output DTO types, not on domain types. The engine compiles and is fully functional with zero features enabled.

### Public API

The engine returns typed Rust data. No serialization at this layer. The public API is the `lib.rs` facade that re-exports the types and functions consumers need.

```rust
// {name}-engine/src/lib.rs
#![no_std]
extern crate alloc;

mod domain;
mod parse; // or whatever the engine does

// Public API: typed Rust structs and functions
pub use domain::{Argument, ArgumentMode /* ... */, Command};
pub use parse::{ParseError, parse};
```

```rust
// Engine returns typed Result, not strings
pub fn parse(input: &str) -> Result<Vec<Command>, ParseError> { /* ... */
}
```

Native Rust consumers get zero-cost typed access. WASM wrappers handle serialization at the boundary. This is the correct layer for typed returns per Tom's Clean Architecture: the domain returns domain types, infrastructure handles format conversion.

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

Error types are exhaustive, typed, and use business language. No transport concepts. Full variant data included so consumers have enough information to resolve the error. Follows the error layering from Tom's Clean Architecture.

### JSON Serialization (Behind Feature Flag)

When the `serde` feature is enabled, a `serialize` module provides DTO types with `Serialize` and conversion functions. Domain types remain serde-free.

```rust
// {name}-engine/src/serialize.rs
// Only compiled when `serde` feature is active
#[cfg(feature = "serde")]
pub mod json {
    use crate::domain;
    use alloc::vec::Vec;
    use serde::Serialize;

    #[derive(Serialize)]
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

This keeps domain types free of serde while allowing JSON output for wrappers that need it (wasm-bindgen). The component model wrapper may skip JSON entirely and use WIT native types.

## JS WASM Crate (wasm-bindgen)

Thin adapter for JavaScript runtimes (browser, Node, Bun, Deno).

### Cargo.toml

```toml
# {name}-wasm-js/Cargo.toml
[lib]
crate-type = ["cdylib"]

[dependencies]
{name}-engine = { path = "../{name}-engine", features = ["std", "serde"] }
wasm-bindgen = "0.2"
```

The JS wrapper enables the `serde` feature on the engine because the JS boundary uses JSON strings. This is the only place that decision is made.

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
    // Returns: {"error": {"type": "...", "message": "..."}}
    // Matches the ErrorResponse shape from Tom's Clean Architecture
    format!(r#"{{"error":{{"type":"{}","message":"{}"}}}}"#, error_type, message)
}
```

Errors are encoded as JSON rather than thrown. The JS consumer parses the JSON and checks for an `error` shape. This avoids exception-based control flow, consistent with errors-as-values philosophy.

### Build

```bash
# Direct wasm-bindgen CLI (no wasm-pack, post-sunset)
cargo build -p {name}-wasm-js --target wasm32-unknown-unknown --release
wasm-bindgen target/wasm32-unknown-unknown/release/{name}_wasm_js.wasm \
  --out-dir sdks/js/pkg --target bundler
```

Target: `wasm32-unknown-unknown`. Output: `.wasm` binary, JS glue code, `.d.ts` types. The JS SDK in `sdks/js/` wraps the raw `pkg/` output with an idiomatic API.

### Deprecation Path

When the WebAssembly Component Model gains stable browser support and `wasm-bindgen` can be replaced with a component-based JS binding, this crate can be deprecated. The `{name}-component` crate becomes the universal distribution format. Until then, `wasm-bindgen` is the pragmatic choice for JS targets.

## Component Crate (WASI P2)

Thin adapter for non-JS runtimes via the WebAssembly Component Model.

### WIT Interface

```wit
// {name}-component/wit/{namespace}/{name}.wit
package {namespace}:{name}@0.1.0;

world engine {
    // Prefer WIT native types over JSON strings.
    // Each function maps to an engine public API function.

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

WIT native types are preferred over JSON strings. This lets each host language runtime (Go, Python, C#) bind to native types directly without JSON parsing overhead. The WIT types mirror the engine's domain types but are defined independently in WIT's type system.

WIT `result<T, E>` carries full variant and field data. Error variants map 1:1 to the engine's `ParseError` enum so consumers have enough information to resolve the error.

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

// From impls: engine domain types → WIT generated types
impl From<{name}_engine::Command> for Command { /* field mapping */ }
impl From<{name}_engine::ParseError> for ParseError { /* variant mapping */ }

export!(Component);
```

### Build

```bash
cargo component build -p {name}-component --release
# Output: target/wasm32-wasip2/release/{name}_component.wasm
```

Target: `wasm32-wasip2` (Rust tier-2 target). Output: a WebAssembly Component implementing the WIT world. `cargo-component` is the default build tool for component targets.

### Downstream Consumers

Each non-JS language embeds a component-aware WASM runtime (Wasmtime, Wasmer) and binds to the WIT interface. The WIT types map to native language types:

| Language | Runtime                                           | Binding            |
| -------- | ------------------------------------------------- | ------------------ |
| Go       | wasmtime-go                                       | Generated from WIT |
| Python   | wasmtime-py                                       | Generated from WIT |
| C#       | wasmtime-dotnet                                   | Generated from WIT |
| Zig      | [OPEN: evaluate wasmtime-zig or direct embedding] | TBD                |

All host libraries receive native typed data from the WIT interface. No JSON parsing required.

## SDK Packages

Per-language idiomatic wrappers that consumers actually install.

### Tier Classification

| Tier | Languages                                          | Meaning                                                             |
| ---- | -------------------------------------------------- | ------------------------------------------------------------------- |
| 1    | JS/TS (browser), JS/TS (Node/Bun/Deno), Python, Go | First-class. Tested in CI. Breaking changes require migration path. |
| 2    | C#, Zig                                            | Supported. Tested in CI. Community contributions welcomed.          |
| 3    | Everything else                                    | Community-maintained. PRs welcomed. Not tested in main CI.          |

### JS SDK

The JS SDK wraps the `wasm-bindgen` output with an idiomatic TypeScript API:

```
sdks/js/
  package.json
  src/
    index.ts          (public API, re-exports typed interface)
    wasm-loader.ts    (init/load wasm module)
  pkg/                (generated by wasm-bindgen build, gitignored)
  tests/
    parse.test.ts     (vitest)
```

The SDK handles WASM initialization, JSON parsing of the raw string return, and exposes typed TypeScript interfaces. Two build variants:

- **Browser**: bundler-compatible ESM with lazy WASM init
- **Node/Bun/Deno**: direct WASM instantiation, synchronous where supported

### Component SDKs (Go, Python, C#)

Component SDKs wrap the Wasmtime bindings with language-idiomatic APIs:

```
sdks/python/
  pyproject.toml
  src/{name}/
    __init__.py       (public API)
    _wasm.py          (wasmtime component instantiation)
  tests/
    test_parse.py
  {name}_component.wasm   (copied from build output or fetched from release)
```

Prefer generated bindings from WIT. Hand-write idiomatic wrappers when the generated code is not ergonomic enough for the target language. Each SDK:

- Bundles or fetches the `.wasm` component artifact
- Instantiates the Wasmtime runtime and component
- Exposes native-typed functions matching the WIT interface
- Maps WIT error variants to language-idiomatic error types (e.g., Python exceptions, Go error returns)

### SDK Versioning

SDKs version independently from the engine. An SDK version bump may reflect:

- New convenience methods or language-idiomatic improvements
- Runtime dependency updates (wasmtime version)
- No change in underlying engine behavior

The SDK documents which engine version it embeds. Consumers can check `{sdk}.engine_version()` or equivalent.

## Error Handling

### Layer Mapping

| Layer              | Error Type                   | Approach                                                      |
| ------------------ | ---------------------------- | ------------------------------------------------------------- |
| Engine (domain)    | `ParseError` enum            | `thiserror`, typed, exhaustive                                |
| Component wrapper  | WIT `result<T, parse-error>` | Map engine error variants to WIT variants 1:1                 |
| JS wrapper         | JSON-encoded error string    | Convert `ParseError` to `{"error": {"type", "message", ...}}` |
| SDK (per-language) | Language-native error type   | Parse WIT error or JSON error into idiomatic form             |

Follows the error layering from Tom's Clean Architecture and Tom's Clean Code.

### Error Detail Granularity

Full variant + fields cross every boundary. Errors must carry enough data for the consumer to resolve the problem (position, expected token, context). The WIT interface defines error variants that mirror the engine's error enum. JSON error responses include `type` (variant name) and all variant fields.

### Rules

- Engine errors never reference transport concepts (no HTTP status, no exit codes).
- Wrapper crates never `unwrap()` or `panic!()`. All engine errors are caught and converted.
- SDK error types are language-idiomatic (Python raises exceptions, Go returns errors, C# throws).
- The error response JSON shape matches Tom's Clean Architecture `ErrorResponse { type, message, detail? }`.

## Testing

Follows Testing and Rust Testing.

### Engine Crate (Where Coverage Matters)

All logic tests live in `{name}-engine`. This is where investment pays off.

- **Layer 1**: `#[cfg(test)] mod tests` in each source file. Unit tests for domain logic. Fast.
- **Layer 2**: `src/tests/` directory for cross-module composition. Property tests with proptest.
- **Layer 3**: Top-level `tests/` for full public API invariants. Cross-layer property tests.
- **Fuzz**: `cargo-fuzz` harnesses for `parse()` and any function that accepts `&str` or `&[u8]`.
- No integration tests needed since the engine has no IO.

### Wrapper Crates (Thin Glue Verification)

Wrapper crates are thin enough that engine tests provide confidence. Wrapper-level tests verify only the binding glue:

- **JS crate**: Verify `parse()` returns valid JSON for valid input and JSON error for invalid input.
- **Component crate**: Rust integration test that instantiates the component via Wasmtime and calls through the WIT interface. [OPEN: evaluate `cargo-component test` support as it matures alongside the toolchain.]

### SDK Tests

Each SDK tests its own code and avoids testing code outside its boundary. SDK tests verify:

- WASM module loads and initializes correctly in the target runtime.
- Public API functions accept expected input types and return expected output types.
- Error cases produce language-idiomatic errors with correct variant/type information.
- [OPEN: cross-SDK API consistency testing. The APIs across SDKs should have consistency while also being idiomatic for each language. Format and mechanism for verifying this is undetermined.]

**JS SDK testing**: vitest. Runs against the built WASM package in Node. Browser variant tested via vitest browser mode.

### Contract: Shared Test Vectors

[OPEN: format for shared test vectors (`test-vectors/` directory) that all SDKs run to ensure cross-language contract fidelity. Candidates: JSONL, TOML, directory of `{input}.txt` + `{expected}.json` pairs. Decision deferred until multiple SDKs exist and the pattern becomes clearer through implementation.]

The JSON output schema (for JS wrapper) and WIT interface (for component wrapper) act as the contract between engine and all consumers. Schema conformance tests in the engine crate ensure all outputs match the versioned schema.

## Memory and Performance

### String Passing

UTF-8 is the canonical encoding at every boundary. Rust, JS, Go, and Python handle UTF-8 natively. For UTF-16 languages (C#, Java), the Wasmtime runtime handles transcoding at the component boundary. Per-language SDK documentation should note any encoding overhead for the target runtime.

### WASM Linear Memory

WASM linear memory defaults to 256 pages (16MB). For text-processing engines (parsers, validators, formatters), input size is typically bounded and well within limits. For engines that process larger data:

- Set explicit memory limits in the component's WASM instantiation.
- Document maximum input size in the engine's public API.
- Consider streaming interfaces in WIT for unbounded input (WIT streams are evolving, may not be stable).

If the engine's use case involves large binary data (images, archives), evaluate whether WASM is the right distribution mechanism or whether a native library with FFI is more appropriate.

### Allocation Strategy

Allocation differs by wrapper type:

- **wasm-bindgen (JS)**: Rust allocates the return value in WASM linear memory. The JS glue code copies the data out. The Rust allocator frees the original. Two copies exist briefly.
- **Component Model (WIT)**: The canonical ABI handles allocation and copying between host and guest. The host runtime (Wasmtime) manages the transfer. No manual allocation code needed in the wrapper.

The component model's canonical ABI is the cleaner abstraction. When component model support reaches stable browser integration, the wasm-bindgen path can be deprecated, eliminating the manual allocation concern for JS targets.

## Versioning and Compatibility

### Crate Versioning

The engine crate, wasm-js crate, and component crate share a version number and are released together. A change to any of the three bumps all three. This keeps the Cargo workspace consistent and avoids version matrix confusion.

```toml
# Workspace Cargo.toml
[workspace.package]
version = "0.1.0"
```

### SDK Versioning

SDK packages version independently. An SDK's version reflects its own API surface, runtime dependencies, and ergonomic improvements. Each SDK documents which engine version it embeds:

```
engine: 0.3.0 → js-sdk: 1.2.0, py-sdk: 0.8.0, go-sdk: 0.5.0
engine: 0.4.0 → js-sdk: 1.3.0, py-sdk: 0.9.0, go-sdk: 0.6.0
```

### WIT Package Versioning

The WIT package version tracks the engine crate version:

```wit
package {namespace}:{name}@0.1.0;  // matches engine 0.1.0
```

When the engine's public API changes in a way that affects the WIT interface, both versions bump together.

### Compatibility Rules

- Engine patch release (0.1.0 → 0.1.1): bug fix. All wrappers and SDKs compatible without rebuild, but rebuild recommended.
- Engine minor release (0.1.0 → 0.2.0): new features, no breaking changes. Wrappers rebuild. SDKs may expose new functions.
- Engine major release (0.x → 1.0 or 1.0 → 2.0): breaking changes. WIT interface may change. SDKs must update.

### Toolchain Pinning

Pin specific versions of moving-target tools. Update deliberately, not accidentally.

| Tool                       | Pin Strategy                            |
| -------------------------- | --------------------------------------- |
| `wasm-bindgen`             | Exact version in Cargo.toml             |
| `wasm-bindgen-cli`         | Match Cargo.toml version exactly        |
| `cargo-component`          | Exact version in CI and local toolchain |
| `wit-bindgen`              | Exact version in Cargo.toml             |
| `wasmtime` (host runtimes) | Exact version per SDK                   |

### WASI Toolchain Changes

The project standardizes on `wasm32-wasip2`. If the WASI/component toolchain evolves, only `{name}-component` and its WIT definitions need adjustment. Engine and JS crates remain stable.

## CI and Publishing

### Build Matrix

The workspace produces three artifact types from two WASM targets plus native:

| Artifact       | Target                   | Tool                           | Purpose                         |
| -------------- | ------------------------ | ------------------------------ | ------------------------------- |
| Engine tests   | native                   | `cargo nextest run`            | All tests, property tests, fuzz |
| JS WASM        | `wasm32-unknown-unknown` | `cargo build` + `wasm-bindgen` | JS runtime distribution         |
| Component WASM | `wasm32-wasip2`          | `cargo component build`        | Non-JS runtime distribution     |

CI orchestration is handled by Moonrepo tasks. GitHub Actions is a thin executor that runs Moon commands. See project-specific Moonrepo configuration for task definitions.

### Publishing Pipeline

| Artifact               | Registry                         | Trigger                            |
| ---------------------- | -------------------------------- | ---------------------------------- |
| `{name}-engine`        | crates.io                        | Git tag on engine version bump     |
| JS WASM `.wasm` + glue | npm (via `sdks/js/`)             | Git tag on JS SDK version bump     |
| Component `.wasm`      | GitHub Release asset             | Git tag on engine version bump     |
| Python SDK             | PyPI (via `sdks/python/`)        | Git tag on Python SDK version bump |
| Go SDK                 | Go module proxy (via `sdks/go/`) | Git tag on Go SDK version bump     |

The component `.wasm` artifact on GitHub Releases is the canonical distribution for non-JS SDKs. SDKs either bundle the artifact at build time or fetch it at install time.

## Non-Goals

- No per-language native re-implementations of engine logic.
- No `wasm32-wasi` legacy target for new work (use `wasm32-wasip2`).
- No host-specific behavior in the engine crate.
- No `wasm-pack` (post-sunset; use `wasm-bindgen` CLI directly).
- No serde derives on engine domain types.
- No runtime-specific code in the engine (no Tokio, no async).

## Anti-Patterns

| Don't                                    | Do Instead                                               |
| ---------------------------------------- | -------------------------------------------------------- |
| Parsing/business logic in wrapper crates | All logic in `{name}-engine`                             |
| `serde` derives on domain types          | DTO conversion in `serialize` module behind feature flag |
| `unwrap()`/`panic!()` in wrapper crates  | Serialize errors to JSON or WIT error variants           |
| Shared mutable state in engine           | Pure functions, deterministic                            |
| Host-specific code in engine             | Engine is host-agnostic, `no_std`                        |
| Per-language engine forks                | Single Rust engine, WASM distribution                    |
| JSON strings over WIT interface          | WIT native types; JSON only for wasm-bindgen path        |
| `wasm-pack` for builds                   | `wasm-bindgen` CLI directly                              |
| Testing engine logic from SDK tests      | SDKs test their own glue; engine tests own logic         |
| Monolithic WASM with runtime deps        | Thin wrappers, engine has zero runtime deps              |

## Open Questions

Items marked for resolution during implementation:

1. **Zig SDK runtime**: Evaluate wasmtime-zig maturity or direct WASM embedding for Zig consumers.
2. **`cargo-component test`**: Evaluate as it matures. Currently, Rust integration tests that instantiate the component via Wasmtime are the fallback.
3. **Cross-SDK API consistency testing**: The APIs across SDKs should be consistent while idiomatic per language. No mechanism identified yet for automated verification. May emerge naturally once 2+ SDKs exist.
4. **Shared test vector format**: Deferred until multiple SDKs exist. Candidates: JSONL, TOML, paired input/expected files.
5. **WIT streams for large input**: Evaluate when WIT streaming stabilizes for engines that process unbounded data.
6. **Component model browser support**: When stable, evaluate deprecating the wasm-bindgen JS path in favor of a unified component distribution.

## Checklist

- Engine crate `#![no_std]` + `extern crate alloc`
- Engine crate zero WASM/runtime dependencies
- Engine crate zero serde in default features
- Engine crate `serde` feature flag for optional JSON DTO support
- Engine crate `std` feature flag for optional std support
- Engine crate returns typed `Result<T, E>`, not strings
- Engine crate deterministic, pure, no IO
- Engine crate domain types free of serde derives
- Engine crate `thiserror` for error types
- Engine crate all logic tests (unit, property, fuzz)
- JS wrapper thin, delegates to engine, errors as JSON
- JS wrapper built with `wasm-bindgen` CLI (not wasm-pack)
- Component wrapper thin, delegates to engine, WIT interface
- Component wrapper uses WIT native types (not JSON strings)
- Component wrapper uses WIT `result<T, E>` for errors with full variant data
- WIT package version tracks engine version
- Engine + wasm-js + component version together
- SDK versions independent from engine
- SDKs test their own glue, not engine logic
- Toolchain versions pinned (wasm-bindgen, cargo-component, wit-bindgen, wasmtime)
- Target `wasm32-wasip2` for component crate (not legacy `wasm32-wasi`)
- No `unwrap()`/`panic!()` in library or wrapper code
- No parsing/business logic outside engine crate
