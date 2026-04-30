# Rust CLI Pattern

Pattern for building user-facing and agent-facing Rust CLI tools. Follows Toms Clean Code,
Rust Patterns, Toms Clean Architecture, and Testing patterns.

## Reference Upstream: starbase

[starbase](https://github.com/moonrepo/starbase) is the reference upstream for this pattern. It is
not adopted as a framework dependency, but it is the primary source for guidance on problems this
pattern does not yet address. Before solving an unaddressed problem with a novel approach, check
how starbase has solved the same class of problem and evaluate whether that pattern should be
adopted here. Starbase components used directly: `miette`, `tracing`, `schematic`,
`starbase_styles`, `starbase_console` (when output complexity warrants it).

The `starbase` framework layer — `App`, lifecycle phases, and `starbase_events` — is not used for
focused single-purpose utilities. The event system and lifecycle phases are the only things starbase
adds over the components alone. If a project never needs `app.emit(SomeEvent)` or plugin hooks
across independently distributed crates, the plain `app.rs` bootstrap pattern is sufficient and
adds no indirection.

Revisit `starbase` as a framework dependency if a project needs an extensible plugin system where
third-party crates register handlers — the same problem moon itself solves.

## When to Use

Apply this pattern when building a Rust binary that:
- Accepts subcommands via `clap`
- Owns a pure domain/engine crate with zero CLI dependencies
- May need to expose its commands as MCP tools (clap → MCP direction)
- Or is an MCP server that benefits from a human-facing CLI companion (MCP → clap direction)

Do not apply this pattern for single-command binaries with no config, no domain logic, and no MCP
surface. A plain `clap` `main.rs` is sufficient there.

## Workspace Structure

Three crate tiers in a Cargo workspace. The engine crate is the domain. The CLI crate is the
imperative shell. Fuzz harnesses nest inside the crate they test.

```
engine/
  fuzz/            fuzz harnesses against engine (cargo-fuzz workspace)
cli/
  fuzz/            fuzz harnesses against CLI surface, only if CLI accepts raw input
fuzz-common/       shared arbitrary-derived types used by both harnesses and engine test suite
.moon/
Cargo.toml         workspace root
```

Crate names are `engine` and `cli`, without a project-name prefix. The workspace `name` field
carries project identity. `core` is excluded — it carries meaning in the crate ecosystem (no-std,
platform primitives).

`engine/fuzz/` is a cargo-fuzz workspace (separate `Cargo.toml` with `[profile.fuzz]`). It is not
a member of the root workspace; cargo-fuzz manages it. `fuzz-common` is a member of the root
workspace and can be imported by both `engine/fuzz/` harnesses and `engine`'s own test suite for
regression tests against known-bad corpus inputs. `cli/fuzz/` only exists if the CLI exposes a
parser or input surface that the engine does not cover.

```toml
# Cargo.toml — root workspace
[workspace]
resolver = "2"
members = [
  "engine",
  "cli",
  "fuzz-common",
  # engine/fuzz and cli/fuzz are NOT listed here — cargo-fuzz manages them
]
```

## Engine Crate

Pure Rust library. All business logic, domain types, and rules live here. Zero CLI, zero async
runtime (no tokio), zero IO.

- `thiserror` for typed error enums, never `anyhow`
- Returns typed `Result<T, E>`, not strings or exit codes
- No `clap`, no `miette`, no `tracing` in default features
- May use `tracing::instrument` behind a feature flag; the engine never initializes a subscriber
- Config model types live here with `serde` derives; loading logic lives in `engine/src/config/`
  so library consumers can load config without the CLI

## CLI Crate

The imperative shell. Three files: `main.rs`, `app.rs`, `commands/`.

### main.rs

Owns the top-level `Cli` struct and `Commands` enum. Wires bootstrap then dispatches. No business
logic.

```rust
mod app;
mod commands;

use clap::{Parser, Subcommand};

/// {name} — one-line description
#[derive(Parser, Debug)]
#[command(name = "{name}", version, about)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    Run(commands::run::RunArgs),
    Init(commands::init::InitArgs),
    #[command(hide = true)]
    Completions(commands::completions::CompletionsArgs),
}

// Sync CLI (no async domain work):
fn main() {
    app::install_error_reporter();
    let cli = Cli::parse();
    match cli.command {
        Commands::Run(args) => commands::run::execute(args),
        Commands::Init(args) => commands::init::execute(&args),
        Commands::Completions(args) => commands::completions::execute(args),
    }
}

// Async CLI (engine has async ports):
#[tokio::main]
async fn main() -> miette::Result<()> {
    miette::set_hook(Box::new(|_| Box::new(miette::MietteHandlerOpts::new().build())))
        .map_err(|e| miette::miette!("failed to set miette hook: {e}"))?;
    app::init_tracing();
    let cli = Cli::parse();
    match cli.command {
        Commands::Run(args) => commands::run::run(args).await,
        Commands::Init(args) => commands::init::run(&args),
        Commands::Completions(args) => { commands::completions::execute(args); Ok(()) }
    }
}
```

### app.rs

Bootstrap helpers only. No business logic.

```rust
// Sync project (miette only):
pub(crate) fn install_error_reporter() {
    // miette "fancy" feature installs the graphical reporter automatically.
    // Call set_hook here only for custom renderer overrides.
}

pub(crate) fn load_config(path: Option<&std::path::Path>) -> miette::Result<engine::config::Config> {
    engine::config::load(path).map_err(|e| miette::miette!("{e}"))
}

// Async project (tracing + miette):
pub(crate) fn init_tracing() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("MYAPP_LOG")
                .or_else(|_| tracing_subscriber::EnvFilter::try_from_env("RUST_LOG"))
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr) // REQUIRED: MCP stdio owns stdout; logs must go to stderr
        .init();
}
```

### commands/

One file per subcommand. Exports its `Args` struct and a top-level function (`execute` for sync,
`run` for async). `commands/mod.rs` is `pub mod` declarations only.

```rust
// commands/run.rs
use clap::Args;

#[derive(Args, Debug)]
pub struct RunArgs {
    #[arg(short, long)]
    pub path: std::path::PathBuf,
    #[arg(long)]
    pub config: Option<std::path::PathBuf>,
}

pub fn execute(args: RunArgs) {
    let config = crate::app::load_config(args.config.as_deref()).unwrap_or_else(|e| {
        #[allow(clippy::print_stderr)]
        { eprintln!("{e}"); }
        std::process::exit(2);
    });
    match engine::run(&args.path, &config) {
        Ok(result) => { /* write to stdout */ }
        Err(e) => { eprintln!("{e}"); std::process::exit(1); }
    }
}

// async variant
pub async fn run(args: RunArgs) -> miette::Result<()> {
    let config = crate::app::load_config(args.config.as_deref())?;
    engine::run_async(&args.path, &config)
        .await
        .map_err(|e| miette::miette!("{e}"))
}
```

## Output

Use [`starbase_console`](https://docs.rs/starbase_console) when the CLI has multiple output modes,
a quiet flag, or needs buffered async-safe writes. The `Console<R>` struct wraps `out`
(`ConsoleStream` → stdout) and `err` (`ConsoleStream` → stderr), and exposes a `Reporter` trait for
swappable output strategies. The `Reporter` implementor is where `--output json` vs human-readable
diverges.

```rust
use starbase_console::{Console, Reporter, ConsoleStream};

#[derive(Debug)]
pub struct AppReporter {
    out: ConsoleStream,
    json: bool,
}

impl Reporter for AppReporter {
    fn inherit_streams(&mut self, _err: ConsoleStream, out: ConsoleStream) {
        self.out = out;
    }
}

impl AppReporter {
    pub fn print_result(&self, result: &engine::RunResult) {
        if self.json {
            self.out.writeln(serde_json::to_string(result).unwrap());
        } else {
            self.out.writeln(format!("done: {}", result.summary()));
        }
    }
}
```

For simple CLIs without multiple output modes, `println!` guarded by
`#[allow(clippy::print_stdout)]` at the call site is sufficient. The decision point is: does the
CLI need buffered output, a quiet mode, or a swappable output backend?

### Shell Completions

Completions are shipped in the binary via `clap_complete`. A hidden `Completions` subcommand prints
the completion script for the requested shell. Users source it in their shell profile; no separate
install step.

```rust
// commands/completions.rs
use clap::Args;
use clap_complete::{Shell, generate};

#[derive(Args, Debug)]
pub struct CompletionsArgs {
    pub shell: Shell,
}

pub fn execute(args: CompletionsArgs) {
    generate(
        args.shell,
        &mut <crate::Cli as clap::CommandFactory>::command(),
        env!("CARGO_PKG_NAME"),
        &mut std::io::stdout(),
    );
}
```

## Config

Use `schematic` when the config schema needs JSON Schema export. Use `serde` + `serde_yaml` /
`serde_json` directly when the schema is simple and not user-editable. Config model types live in
the engine crate; loading lives in `engine/src/config/mod.rs` so library consumers can load config
independently of the CLI.

## Error Handling and Exit Codes

Engine returns typed domain errors with `thiserror`. CLI maps them to exit codes. Exit codes are
the CLI adapter's transport concern, identical in role to HTTP status codes in a web adapter.

Exit code conventions:
- `0` success
- `1` domain or validation failure (expected, user-fixable)
- `2` config or invocation error (bad args, missing file)
- `3+` reserved for tool-specific diagnostic categories

When using `miette::Result<()>` as `main`'s return type, the `?` operator propagates and miette's
graphical reporter formats automatically. Use this for async CLIs. For sync CLIs, handle errors
explicitly in commands via `unwrap_or_else` and `std::process::exit`.

## Async vs Sync Decision

| Signal | Choose |
|---|---|
| Engine has async ports (network, container runtime, DB) | `#[tokio::main]` + async commands |
| Engine is pure computation or local file IO only | Sync `fn main()` |
| Any subcommand needs async | Make all commands async — mixing is awkward |
| Targeting WASM or embedded | Sync |

Do not add tokio to a sync project speculatively.

## Tracing and Logging

Use `tracing` + `tracing-subscriber` for structured observability in async CLIs. Use `eprintln!`
guarded by `#[allow(clippy::print_stderr)]` in sync CLIs.

Rules:
- All log/trace output goes to `stderr`. Always.
- Control verbosity with `MYAPP_LOG` env var first, `RUST_LOG` as fallback, `info` as default.
- Do not initialize a tracing subscriber in the engine crate.

## Plugin / Extensibility Strategy

Three strategies appear across projects in this ecosystem. Choose based on who extends the tool
and how extensions are distributed.

### Compiled-in Rule Set (clippy-style)

Rules are Rust functions in the engine crate, called from a per-input-type orchestrator. Adding a
rule means adding a module and calling it from the orchestrator. New rules require a binary rebuild.

```
engine/src/rules/
  mod.rs           orchestrator: calls each rule module, collects diagnostics
  workflow/
    jobs.rs        check_jobs(ast, source) -> Vec<Diagnostic>
    steps.rs
    expressions.rs
```

When to use: the rule set is maintained by the same team as the binary. Users cannot add rules
without forking. Rules have full access to the parsed AST and the full Rust type system. Zero
runtime overhead beyond Rust function calls. Each rule module is testable in isolation.

### External Policy WASM (dprint-style)

Policy logic is compiled out-of-process (from OPA Rego or another policy language) into WASM
modules. The engine embeds the WASM bytes at compile time (`include_bytes!`) or loads them from a
user-specified path. A `wasmtime` / `opa_wasm` runtime evaluates the module per invocation.

```
engine/src/policy/
  engine.rs        PolicyEngine::new(wasm_bytes), evaluate(data, input, entrypoint) async
  eligibility.rs   EligibilityEvaluator wrapping PolicyEngine
  filter.rs        FilterEvaluator wrapping PolicyEngine
cli/src/app.rs     include_bytes!("../../policies/eligibility.wasm")
```

When to use: users write their own policy logic in a policy language without recompiling the binary.
The policy language and host input/output contract are the extension interface. WASM provides
sandboxing and portability. Testing requires building the WASM artifact in the test harness or using
pre-built test fixtures.

### Event-Driven Plugin System (starbase-style)

Extensions implement event handler traits and register with an `App`. The `starbase_events` emitter
dispatches typed events; handlers from independent crates all listen to the same event without
knowing about each other.

When to use: the tool is a platform where third-party crates need to hook into the same pipeline
without forking the host binary. This is the moon / proto model. Do not use this for focused
utilities — it adds `Arc<Mutex<>>` complexity and async overhead to every operation.

### Plugin Strategy Decision Guide

```
Is the extension author the same team as the binary maintainer?
├── Yes → Compiled-in rule set (clippy-style)
│         Simple, testable, zero overhead, full type safety.
└── No: Is the extension logic expressible in a policy language (Rego, CEL)?
    ├── Yes → External policy WASM (dprint-style)
    │         Users write policies; you define the input/output contract.
    └── No: Do third-party crates need to extend behavior at runtime?
        ├── Yes → starbase_events plugin system
        │         Only justified for platform-class tools.
        └── No → Compiled-in rule set with config-driven enable/disable flags
                  (Most tools that ask this question land here.)
```

## MCP Integration

### Direction: clap → MCP (clap-mcp)

When the CLI already exists and you want LLM agents to call its commands as MCP tools without
rewriting the CLI. The CLI gains a `--mcp` flag that starts a stdio MCP server derived from the
clap schema.

```toml
# cli/Cargo.toml
clap-mcp = "0.x"
```

```rust
use clap::{Parser, Subcommand};
use clap_mcp::ClapMcp;

#[derive(Parser, ClapMcp)]
#[clap_mcp(reinvocation_safe, parallel_safe = false)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand, ClapMcp)]
#[clap_mcp_output_from = "run"]
enum Commands {
    Lint(commands::lint::LintArgs),
    #[clap_mcp(skip)]   // agents should not call init or completions
    Init,
    #[clap_mcp(skip)]
    Completions(commands::completions::CompletionsArgs),
}

fn run(cmd: Commands) -> String { /* delegate to execute fns */ }

fn main() {
    app::install_error_reporter();
    let cli = clap_mcp::parse_or_serve_mcp_attr::<Cli>();
    match cli.command {
        None => Cli::print_help_and_exit(),
        Some(cmd) => println!("{}", run(cmd)),
    }
}
```

`reinvocation_safe = true` allows in-process execution. Only safe when the command has no side
effects that conflict on concurrent calls. Always write tracing to `stderr` — stdout is reserved
for JSON-RPC messages when `--mcp` is active.

Async tool support via `run_async_tool`: defer evaluation until there is a present need.

### Direction: MCP → clap (mcp-cli-builder)

When the primary surface is an MCP server and you want a CLI for dev/debug convenience.

```rust
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let server = mcp_cli_builder::ServerBuilder::new()
        .with_tool_box(MyToolBox::new())
        .build();
    mcp_cli_builder::run(server).await
}
```

### MCP Direction Decision

| Starting point | Want | Use |
|---|---|---|
| Existing clap CLI | Add MCP tool surface | `clap-mcp` derive |
| New project, CLI primary | Add MCP as opt-in mode | `clap-mcp` derive |
| New project, MCP primary | Add CLI for dev/debug | `mcp-cli-builder` |
| Need MCP resources, prompts, or streaming | Native MCP server | `rmcp` directly |

## Distribution

The distribution stack is: `cargo-dist` for release artifacts, `release-please` as the release
trigger, `cargo publish` as a free secondary, and a proto plugin entry in
[`tomdavidson/proto`](https://github.com/tomdavidson/proto) as the primary install path for
proto/moon ecosystem users.

### cargo-dist Setup

Add to the root `Cargo.toml`. cargo-dist generates the GitHub Actions release workflow and produces
per-platform archives that `release-please` triggers automatically on release PR merge.

```toml
# Cargo.toml
[workspace.metadata.dist]
cargo-dist-version = "0.x"
ci = "github"
installers = ["shell", "powershell"]
targets = [
  "x86_64-unknown-linux-gnu",
  "aarch64-unknown-linux-gnu",
  "aarch64-apple-darwin",
  "x86_64-apple-darwin",
  "x86_64-pc-windows-msvc",
]
```

cargo-dist produces archives named `{name}-v{version}-{target}.tar.gz` (`.zip` on Windows) and a
`{name}-v{version}-checksums.txt`. These land in the GitHub Release as assets.

### Proto Catalog Plugin

Add `plugins/{name}.toml` to [`tomdavidson/proto`](https://github.com/tomdavidson/proto). The
filename pattern matches what cargo-dist produces. See existing entries like `actionlint.toml` as
the format reference.

```toml
# plugins/{name}.toml
name = "{name}"
type = "cli"
description = "One-line description of the tool"

[resolve]
git-url = "https://github.com/tomdavidson/{name}"

[platform.linux]
download-file = "{name}-v{version}-{arch}.tar.gz"
checksum-file = "{name}-v{version}-checksums.txt"

[platform.macos]
download-file = "{name}-v{version}-{arch}.tar.gz"
checksum-file = "{name}-v{version}-checksums.txt"

[platform.windows]
download-file = "{name}-v{version}-{arch}.zip"
checksum-file = "{name}-v{version}-checksums.txt"

[install]
download-url = "https://github.com/tomdavidson/{name}/releases/download/v{version}/{download_file}"
checksum-url = "https://github.com/tomdavidson/{name}/releases/download/v{version}/{checksum_file}"

[install.arch]
aarch64 = "aarch64-apple-darwin"      # overridden per-platform below
x86_64  = "x86_64-unknown-linux-gnu"  # overridden per-platform below

[platform.linux.arch]
aarch64 = "aarch64-unknown-linux-gnu"
x86_64  = "x86_64-unknown-linux-gnu"

[platform.macos.arch]
aarch64 = "aarch64-apple-darwin"
x86_64  = "x86_64-apple-darwin"

[platform.windows.arch]
x86_64 = "x86_64-pc-windows-msvc"
```

Once the entry is merged, users install and version-pin with proto:

```toml
# .prototools in any project
{name} = "0.1.0"
```

```bash
proto install {name}
```

### crates.io

Publish the engine crate when it has independent library value. The CLI crate may also be
published so `cargo install {name}` works as a secondary install path for Rust developers. Add
`cargo publish` as a step in the release workflow after the cargo-dist artifacts are built.

## Testing

Testing follows the Testing and Rust Testing pattern docs. This section covers only CLI-specific
concerns not addressed in the general testing patterns.

### CLI Integration Tests

The CLI crate is thin; business logic lives in the engine and is tested there. CLI integration
tests verify the binary's external contract: exit codes, stdout/stderr content, and subcommand
dispatch.

```toml
# cli/Cargo.toml dev-dependencies
assert_cmd = "2"
predicates = "3"
```

Minimum CLI test coverage:
- Each subcommand exits `0` for valid input and `1`/`2` for expected failures
- `--help` and `--version` flags exit `0` and write to stdout
- Invalid args exit non-zero with a message to stderr
- `completions <shell>` exits `0` and writes non-empty output to stdout
- If `--mcp` is supported: smoke test that the flag starts without crashing

Do not test engine logic from CLI tests. If a test requires a complex engine scenario, it belongs
in `engine/tests/`.

### starbase_sandbox for CLI Tests

[`starbase_sandbox`](https://docs.rs/starbase_sandbox) provides isolated temp directory fixtures
and process execution helpers. Prefer it over rolling custom `tempdir` + `Command` wrappers when
tests need file system setup.

```rust
use starbase_sandbox::create_sandbox;

#[test]
fn run_on_valid_input() {
    let sandbox = create_sandbox("fixtures/valid");
    sandbox.run_bin("myapp", |cmd| {
        cmd.arg("run").arg("--path").arg(".");
    }).assert().success();
}
```

## Workspace Cargo.toml

```toml
[workspace]
resolver = "2"
members = [
  "engine",
  "cli",
  "fuzz-common",
]

[workspace.package]
version = "0.1.0"
edition = "2024"
license = "MIT"
repository = "https://github.com/tomdavidson/{name}"

[workspace.dependencies]
# CLI
clap             = { version = "4",  features = ["derive"] }
clap_complete    = "4"
miette           = { version = "7",  features = ["fancy"] }
# Engine
thiserror        = "2"
serde            = { version = "1",  features = ["derive"] }
serde_json       = "1"
# Optional per project
schematic        = { version = "0.19", features = ["yaml", "renderer_json_schema"] }
tokio            = { version = "1",  features = ["full"] }
tracing          = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
starbase_console = "0.x"
clap-mcp         = "0.x"

[workspace.metadata.dist]
cargo-dist-version = "0.x"
ci = "github"
installers = ["shell", "powershell"]
targets = [
  "x86_64-unknown-linux-gnu",
  "aarch64-unknown-linux-gnu",
  "aarch64-apple-darwin",
  "x86_64-apple-darwin",
  "x86_64-pc-windows-msvc",
]
```

## Tooling and Project Files

| File | Purpose |
|---|---|
| `.prototools` | Pin tool versions (rust, proto itself) |
| `.moon/` | Task definitions: check, build, test, lint, fmt, fuzz |
| `moon.yml` | Root moon config |
| `dprint.json` | Formatter config (rustfmt plugin, TOML, JSON, Markdown) |
| `.rustfmt.toml` | Rustfmt overrides |
| `.clippy.toml` | Clippy-specific config (msrv, disallowed methods) |
| `deny.toml` | cargo-deny: license and duplicate crate checks |
| `renovate.json` | Automated dependency updates |
| `release-please-config.json` | Release automation |
| `.release-please-manifest.json` | Release manifest |
| `docs/adrs/` | ADR index; decisions recorded at first significant architectural choice |

## Anti-Patterns

| Don't | Instead |
|---|---|
| Business logic in command handlers | Put it in the engine crate |
| `unwrap()`/`expect()` in non-test CLI code | Use `?` or `unwrap_or_else` with `process::exit` |
| Log to stdout | Always log to stderr |
| `println!` in commands that may run under `--mcp` | Guard with `#[allow(clippy::print_stdout)]`; confirm stdout is not the MCP transport |
| Tokio in a sync-only project | Don't add async speculatively |
| Engine imports `clap`, `miette`, or `tokio` | Engine has zero CLI/async runtime deps |
| Config loading in `main.rs` | Config loading belongs in `app.rs` or engine's config module |
| Shared `App` state struct passed to every command | Use free functions; inject deps at call site |
| `starbase_events` when no plugin system is needed | Plain `app.rs` bootstrap |
| Plugin logic that could be a Rust trait impl | Only reach for WASM plugins when users write the extension code |
| Crate names like `myapp-core` or `myapp-engine` | Use `engine` and `cli` — the workspace name carries identity |
| Fuzz harnesses as top-level workspace members | Nest `engine/fuzz/` inside the crate under test |

## Checklist

- Engine crate has zero `clap`, `miette`, `tokio` dependencies
- Engine crate returns typed `Result<T, E>` with `thiserror` errors
- CLI crate has `main.rs`, `app.rs`, `commands/` structure
- `app.rs` owns bootstrap: error reporter, tracing, config loading
- One file per subcommand in `commands/`
- Sync vs async decision made explicitly and consistently
- All log/trace output goes to `stderr`; tracing writer explicitly set before any MCP mode
- Exit code mapping exhaustive and co-located with command or in `exit_codes.rs`
- Shell completions available via hidden `completions` subcommand using `clap_complete`
- Plugin strategy matches the decision guide
- `clap-mcp`: `reinvocation_safe` and `parallel_safe` set; `#[clap_mcp(skip)]` on init, completions
- Fuzz harnesses live in `engine/fuzz/` (and optionally `cli/fuzz/`), not root workspace
- `fuzz-common` is a root workspace member; `engine/fuzz` and `cli/fuzz` are not
- CLI integration tests use `assert_cmd` or `starbase_sandbox`; engine logic tested in engine
- `cargo-dist` configured in `[workspace.metadata.dist]`
- Proto plugin entry added to `tomdavidson/proto` `plugins/` on first release
- `docs/adrs/` has at minimum an entry for crate organization and plugin strategy choice
- `.prototools`, `.moon/`, `dprint.json`, `deny.toml`, `renovate.json`, `release-please` present
