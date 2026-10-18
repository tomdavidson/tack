# Rust CLI Pattern

Pattern for building user-facing and agent-facing Rust CLI tools. Follows
[Tom's Clean Code](toms-clean-code.md), [Rust Patterns](lang-rust.md),
[Tom's Clean Architecture](toms-clean-arch.md), [Testing](testing.md), and
[Rust Testing](testing-rust.md).

## Reference Upstream: starbase

[starbase](https://github.com/moonrepo/starbase) is the reference upstream. It is not adopted as a
framework dependency, but it is the primary source for guidance on problems this pattern does not
yet address. Before solving an unaddressed problem with a novel approach, check how starbase has
solved the same class of problem and evaluate whether that pattern should be adopted here.
Components used directly: `miette`, `tracing`, `schematic`, `starbase_styles`, `starbase_console`
(when output complexity warrants it), `starbase_sandbox` (in tests).

The `starbase` framework layer — `App`, lifecycle phases, `starbase_events` — is not used for
focused utilities. If a project never needs `app.emit(SomeEvent)` or plugin hooks across
independently distributed crates, the plain `app.rs` bootstrap is sufficient. Revisit starbase as
a framework when a project needs third-party crates to register handlers into the same pipeline.

## When to Use

Apply this pattern when building a Rust binary that:

- Accepts subcommands via `clap`
- Owns a pure domain/engine crate with zero CLI dependencies
- May expose its commands as MCP tools (clap → MCP)
- Or is an MCP server that benefits from a human CLI companion (MCP → clap)

Do not apply for single-command binaries with no config, no domain, and no MCP surface. A plain
`clap` `main.rs` is sufficient there.

## Workspace Structure

All crates live at the repository root as members of a single Cargo workspace (`actlint` /
`jettision` ADR-0001 layout):

```text
{project}-engine/    (or {project}-core/)
  Cargo.toml         [package] name = "{project}-engine"  + [lints] workspace = true
  build.rs           scans ../fuzz-core/regressions/ and generates #[test] functions
  src/lib.rs
{project}-cli/
  Cargo.toml         [package] name = "{project}" (or "{project}-cli" with [[bin]] name = "{project}")
  src/main.rs
  src/app.rs
  src/commands/
fuzz-common/         ordinary library crate; shared arbitrary::Arbitrary input types
fuzz-core/           cargo-fuzz binary crate (libFuzzer + LibAFL); corpus/ + regressions/
.moon/
Cargo.toml           workspace root (receives [workspace.lints] from configs/rust)
```

### Crate Naming

Three valid `[package] name` strategies on crates.io—pick one per project:

| Strategy         | Engine `[package] name` | CLI `[package] name`         | When                                                 |
| ---------------- | ----------------------- | ---------------------------- | ---------------------------------------------------- |
| CLI-only install | not published           | `{project}`                  | Engine is project-private; users install the CLI     |
| Library + CLI    | `{project}-engine`      | `{project}`                  | Engine has independent value as a library            |
| Both scoped      | `{project}-engine`      | `{project}-cli` + bin rename | Both published; binary still installs as `{project}` |

The CLI crate's binary name (what users type in the shell) is controlled by
`[[bin]] name = "{project}"` in `{project}-cli/Cargo.toml`, independent of the package name.

## Engine Crate (`{project}-engine` or `{project}-core`)

Pure Rust library (or library + domain ports). Zero CLI dependencies:

- `thiserror` for typed error enums, never `anyhow`
- Returns typed `Result<T, E>`
- No `clap` or `miette` in default features
- `tracing::instrument` allowed when needed; engine never initializes a subscriber
- Config model types live here; loading lives in `src/config/`
- Inherits workspace lints via `[lints] workspace = true`

## CLI Crate (`{project}-cli`)

Three files: `main.rs`, `app.rs`, `commands/`.

### main.rs

```rust
mod app;
mod commands;

use clap::{Parser, Subcommand};

/// {project} — one-line description
#[derive(Parser, Debug)]
#[command(name = "{project}", version, about)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    Run(commands::run::RunArgs),
    Init(commands::init::InitArgs),
    /// Generate shell completions: `source <({project} completions bash)`
    Completions(commands::completions::CompletionsArgs),
}

// Sync CLI:
fn main() -> miette::Result<()> {
    app::install_error_reporter();
    let cli = Cli::parse();
    match cli.command {
        Commands::Run(args) => commands::run::execute(args),
        Commands::Init(args) => commands::init::execute(&args),
        Commands::Completions(args) => {
            commands::completions::execute(args);
            Ok(())
        }
    }
}

// Async CLI:
#[tokio::main]
async fn main() -> miette::Result<()> {
    app::install_error_reporter();
    app::init_tracing();
    let cancel = app::install_signal_handler();
    let cli = Cli::parse();
    match cli.command {
        Commands::Run(args) => commands::run::run(args, cancel).await,
        Commands::Init(args) => commands::init::run(&args),
        Commands::Completions(args) => {
            commands::completions::execute(args);
            Ok(())
        }
    }
}
```

Return `miette::Result<()>` from `main` so stack unwinding runs. **Do not** call
`std::process::exit()` from command bodies: if `starbase_console` is in use, buffered stdout/stderr
is destroyed without flush because `Drop` is skipped. Use `?` to propagate, or explicitly call
`console.close()` before any `exit()`.

### app.rs

```rust
pub(crate) fn install_error_reporter() {
    let _ = miette::set_hook(Box::new(|_| {
        Box::new(miette::MietteHandlerOpts::new().build())
    }));
}

pub(crate) fn load_config(
    path: Option<&std::path::Path>,
) -> miette::Result<engine::config::Config> {
    engine::config::load(path).map_err(|e| miette::miette!("{e}"))
}

// Async only — tracing + signal handling
pub(crate) fn init_tracing() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("MYAPP_LOG")
                .or_else(|_| tracing_subscriber::EnvFilter::try_from_env("RUST_LOG"))
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr) // REQUIRED: MCP stdio owns stdout
        .init();
}

pub(crate) fn install_signal_handler() -> tokio_util::sync::CancellationToken {
    let token = tokio_util::sync::CancellationToken::new();
    let child = token.clone();
    tokio::spawn(async move {
        let _ = tokio::signal::ctrl_c().await;
        child.cancel();
    });
    token
}
```

### commands/

One file per subcommand. Each exports `Args` and a top-level function (`execute` sync, `run`
async).

**Every `Args` field has a `///` doc comment.** `clap-mcp` lifts these into MCP tool descriptions.
Sparse comments become bad agent UX when `--mcp` mode is active.

```rust
// commands/run.rs
use clap::Args;
use tokio_util::sync::CancellationToken;

#[derive(Args, Debug)]
pub struct RunArgs {
    /// Path to the target directory or file to process.
    #[arg(short, long)]
    pub path: std::path::PathBuf,

    /// Override the default config file location.
    #[arg(long)]
    pub config: Option<std::path::PathBuf>,

    /// Preview the result without making changes.
    #[arg(long)]
    pub dry_run: bool,
}

pub async fn run(args: RunArgs, cancel: CancellationToken) -> miette::Result<()> {
    let config = crate::app::load_config(args.config.as_deref())?;
    tokio::select! {
        () = cancel.cancelled() => Err(miette::miette!("interrupted")),
        r = engine::run_async(&args.path, &config, args.dry_run) => {
            r.map_err(|e| miette::miette!("{e}"))
        }
    }
}
```

Commands that mutate state accept `--dry-run` and pass it to the engine. The engine's orchestrator
is responsible for respecting the flag.

## Output

### Simple CLIs

`println!` and `eprintln!` with `#[allow(clippy::print_stdout)]` / `#[allow(clippy::print_stderr)]`
at the call site. Use when the CLI has one output format and no quiet mode.

### Complex Output

[`starbase_console`](https://docs.rs/starbase_console) when the CLI needs multiple output modes, a
quiet flag, or buffered async-safe writes. `Console<R>` wraps `out` and `err` streams and exposes a
`Reporter` trait for swappable output strategies.

**When adopting `starbase_console`, handle miette interaction explicitly.** miette's default
graphical reporter writes directly to raw stderr and ignores `Console::quiet()`. Either:

- Handle top-level errors manually (don't return `miette::Result` from `main`) and route through
  the console, or
- Accept that fatal error output bypasses the console's buffer; this is fine for most tools

### MCP Output Discipline

When `--mcp` is active, stdout is the JSON-RPC transport. Any stray `println!` in command bodies
corrupts the stream.

Rules when MCP is a target:

- Command functions return structured data (or `String`) to a dispatcher; the dispatcher decides
  whether to print (CLI path) or return to `clap-mcp` (MCP path)
- Tracing writer is `stderr` (enforced in `app::init_tracing`)
- `#[clap_mcp(skip)]` on any command that interacts with stdout directly (e.g. `Completions`)
- Default `reinvocation_safe = false` so each tool call re-spawns the binary as a subprocess,
  which sidesteps the issue at the cost of spawn overhead. Only set `true` after verifying every
  code path respects stdout discipline

### Color

Support `--color always|auto|never` and the `NO_COLOR` env var. Use `anstream` / `anstyle` or
`starbase_styles`. Detect TTY with `std::io::IsTerminal`:

```rust
use std::io::IsTerminal;
let use_color = match args.color {
    ColorChoice::Always => true,
    ColorChoice::Never => false,
    ColorChoice::Auto => std::env::var_os("NO_COLOR").is_none() && std::io::stdout().is_terminal(),
};
```

### Shell Completions

Completions ship in the binary via `clap_complete`. The `completions` subcommand is **visible** in
`--help` so users discover it.

```rust
// commands/completions.rs
use clap::{Args, CommandFactory, ValueEnum};
use clap_complete::{Shell, generate};

#[derive(ValueEnum, Clone, Copy, Debug)]
pub enum ShellArg {
    Bash,
    Zsh,
    Fish,
    PowerShell,
    Elvish,
}

#[derive(Args, Debug)]
pub struct CompletionsArgs {
    /// Shell to generate completions for.
    pub shell: ShellArg,
}

pub fn execute(args: CompletionsArgs) {
    let shell = match args.shell {
        ShellArg::Bash => Shell::Bash,
        ShellArg::Zsh => Shell::Zsh,
        ShellArg::Fish => Shell::Fish,
        ShellArg::PowerShell => Shell::PowerShell,
        ShellArg::Elvish => Shell::Elvish,
    };
    let mut cmd = crate::Cli::command();
    generate(
        shell,
        &mut cmd,
        env!("CARGO_PKG_NAME"),
        &mut std::io::stdout(),
    );
}
```

## Config

Use `schematic` when the config schema needs JSON Schema export (`schemars` also works). Use
`serde` + `yaml-rust2` / `serde_json` when the schema is simple. Config types and loading live in
the engine crate (`src/config/`) so library consumers can load config without the CLI.

## Error Handling and Exit Codes

Engine returns typed domain errors with `thiserror`. CLI maps to exit codes:

- `0` success
- `1` domain or validation failure
- `2` config or invocation error (bad args, missing file)
- `130` interrupted (SIGINT); convention — do not reuse
- `3+` tool-specific diagnostic categories

Returning `miette::Result<()>` from `main` gives exit `1` on `Err` by default. For tool-specific
non-zero codes, convert the outer error to `std::process::ExitCode` in `main`.

## Async vs Sync Decision

| Signal                                                  | Choose                                                              |
| ------------------------------------------------------- | ------------------------------------------------------------------- |
| Engine has async ports (network, container runtime, DB) | `#[tokio::main]` + async commands                                   |
| Engine is pure computation or local file IO only        | Sync `fn main()`                                                    |
| Any subcommand needs async                              | Entry + dispatch async; sync command bodies fine (just don't await) |
| Targeting WASM or embedded                              | Sync                                                                |

## Tracing and Logging

Use `tracing` + `tracing-subscriber` in async CLIs. Use `eprintln!` guarded by
`#[allow(clippy::print_stderr)]` in sync CLIs.

- All log/trace output goes to `stderr`. Always.
- Verbosity: `MYAPP_LOG` env, then `RUST_LOG` fallback, default `info`.
- Never initialize a subscriber in the engine crate.

## Plugin / Extensibility Strategy

Three strategies. Choose based on who extends the tool and how extensions are distributed.

### Compiled-in Rule Set (clippy / actlint style)

Rules are pure Rust functions in the engine, registered via a declarative macro (`declare_rule!` +
`register_rules![]`) and called from an orchestrator. New rules require a binary rebuild.

```text
{project}-core/src/rules/
  mod.rs                     Rule types, declare_rule!, register_rules! registry
  workflow_no_jobs.rs        check(file: &LintFile<'_>) -> Vec<LintDiagnostic>
```

Use when: the team maintains all rules. Full Rust type system; zero runtime overhead; per-rule
testability.

### External Policy WASM (dprint / jettison style)

Policy logic compiled to WASM out-of-process (e.g. OPA Rego → WASM). Engine embeds bytes at compile
time or loads at runtime; `wasmtime` / `opa-wasm` evaluates per invocation.

Use when: users write extension logic in a policy language (Rego, CEL). WASM provides sandboxing
and portability.

### Event-Driven Plugin System (starbase-style)

Extensions implement event handler traits registered with an `App`. Handlers from independent
crates listen to the same event without knowing about each other.

Use when: the tool is a platform where third-party crates hook into the pipeline without forking
the host binary (moon / proto model). Do not use for focused utilities.

### Plugin Strategy Decision Guide

```text
Is the extension author the same team as the binary maintainer?
├── Yes → Compiled-in rule set (clippy / actlint style)
└── No: Is the extension logic expressible in a policy language (Rego, CEL)?
    ├── Yes → External policy WASM (dprint / jettison style)
    └── No: Do third-party crates need to extend behavior at runtime?
        ├── Yes → starbase_events plugin system
        └── No → Compiled-in rule set with config-driven enable/disable flags
```

### Diagnostic Severity

Compiled-in rule tools emit diagnostics with severity: `error`, `warning`, `info`, `hint`. Severity
drives exit code: any `error` → exit `1`, warnings alone → exit `0` unless `--warnings-as-errors`.
Use `miette::Severity` or a domain enum convertible to it.

## MCP Integration

### Direction: clap → MCP (clap-mcp)

`clap-mcp` is new (first published 2026-03). Evaluate before committing: if a needed feature is
missing or the crate moves slowly, the fallback is to drop to `rmcp` directly and maintain the MCP
server alongside the CLI.

```rust
use clap::{Parser, Subcommand};
use clap_mcp::ClapMcp;

#[derive(Parser, ClapMcp)]
#[clap_mcp(reinvocation_safe = false)] // default: re-spawn per tool call; safest
struct Cli {/* ... */}

#[derive(Subcommand, ClapMcp)]
#[clap_mcp_output_from = "run"]
enum Commands {
    /// Lint the target for common problems.
    #[clap_mcp(parallel_safe)] // read-only, safe to run concurrently
    Lint(commands::lint::LintArgs),

    /// Scaffold a new config file.
    #[clap_mcp(skip)] // agents should not call init
    Init,

    #[clap_mcp(skip)]
    Completions(commands::completions::CompletionsArgs),
}
```

Set `parallel_safe` per-command based on whether it is read-only. Defaulting all commands to
serial (the clap-mcp default) creates a concurrency bottleneck for agents that parallelize tool
calls.

### Direction: MCP → clap (mcp-cli-builder)

Use when the primary surface is an MCP server and the CLI is a dev/debug companion. Auto-generates
`--host`, `--port`, and timeout flags from the `ServerBuilder`.

### MCP Direction Decision

| Starting point                         | Want                 | Use               |
| -------------------------------------- | -------------------- | ----------------- |
| Existing clap CLI                      | Add MCP tool surface | `clap-mcp` derive |
| New project, CLI primary               | MCP as opt-in        | `clap-mcp` derive |
| New project, MCP primary               | CLI for dev/debug    | `mcp-cli-builder` |
| Need MCP resources, prompts, streaming | Native MCP server    | `rmcp` directly   |

## Fuzz Architecture (`fuzz-common` + `fuzz-core` + `build.rs`)

Both `fuzz-common` and `fuzz-core` are root workspace members (`actlint` and `jettision` layout):

1. **`fuzz-common` (library crate)**: Holds shared `arbitrary::Arbitrary` input types used by both
   `fuzz-core` harnesses and the engine crate's regression tests without leaking `libfuzzer-sys`
   into the engine.
2. **`fuzz-core` (fuzz binary crate)**: Runs a 2x2 matrix of unstructured (`&[u8]`) and structured
   (`Arbitrary`) targets across both `libFuzzer` and `LibAFL`. Managed via Moon tasks
   (`fuzz`, `fuzz-saturate`, `fuzz-triage`).
3. **Automated regression replay (`{project}-engine/build.rs`)**: Scans
   `../fuzz-core/regressions/<target>/` at compile time, copies minimized crash files into Cargo's
   `$OUT_DIR`, and generates a `#[test]` function per file using `include_bytes!(...)`. Every
   minimized fuzzer crash (`cargo fuzz tmin`) committed to `fuzz-core/regressions/` automatically
   runs as a unit test on stable Rust during `moon run :test`.

Because `fuzz-common` and `fuzz-core` are in root `[workspace] members`, `moon run :lint`,
`moon run :typecheck`, and `rust-analyzer` index them automatically without custom
`rust-analyzer.linkedProjects` settings.

## Distribution

Stack: `cargo-dist` for artifacts, `release-please` as the release trigger, a proto plugin in
[`tomdavidson/proto`](https://github.com/tomdavidson/proto), `cargo publish` as a secondary.

### Release Sequence

1. Commits land on `main` with conventional-commit messages
2. `release-please` opens/updates a release PR bumping `Cargo.toml` version and `CHANGELOG.md`
3. Merging the release PR creates a git tag `v{version}`
4. `cargo-dist` workflow triggers on the tag, builds per-target archives, uploads to GitHub
   Releases
5. `cargo publish` step (after cargo-dist succeeds) publishes the engine and/or cli crates

`release-please-config.json` must set `release-type: "rust"` and include workspace `Cargo.toml`
under `extra-files` so version bumps propagate.

### cargo-dist Setup

Start minimal. Expand targets based on user demand, not speculation.

```toml
[workspace.metadata.dist]
cargo-dist-version = "0.x"
ci = "github"
installers = ["shell", "powershell"]
targets = [
  "x86_64-unknown-linux-gnu",
  "aarch64-apple-darwin",
  "x86_64-pc-windows-msvc",
]
```

### Proto Catalog Plugin

Add `plugins/{project}.toml` to [`tomdavidson/proto`](https://github.com/tomdavidson/proto):

```toml
name = "{project}"
type = "cli"
description = "One-line description"

[resolve]
git-url = "https://github.com/tomdavidson/{project}"

[platform.linux]
download-file = "{project}-v{version}-x86_64-unknown-linux-gnu.tar.gz"
checksum-file = "{project}-v{version}-checksums.txt"

[platform.macos]
download-file = "{project}-v{version}-aarch64-apple-darwin.tar.gz"
checksum-file = "{project}-v{version}-checksums.txt"

[platform.windows]
download-file = "{project}-v{version}-x86_64-pc-windows-msvc.zip"
checksum-file = "{project}-v{version}-checksums.txt"

[install]
download-url = "https://github.com/tomdavidson/{project}/releases/download/v{version}/{download_file}"
checksum-url = "https://github.com/tomdavidson/{project}/releases/download/v{version}/{checksum_file}"
```

Once merged: `proto install {project}` and version-pin via `.prototools`.

## Testing

Testing follows [Testing](testing.md) and [Rust Testing](testing-rust.md). This section covers only
CLI-specific concerns.

### CLI Integration Tests

```toml
# {project}-cli/Cargo.toml dev-dependencies
assert_cmd = "2"
predicates = "3"
starbase_sandbox = "=0.x" # pin exact — test-only tool; avoid Renovate range updates
```

Minimum CLI coverage:

- Each subcommand exits `0` on valid input, `1`/`2` on expected failures
- `--help` and `--version` exit `0` and write to stdout
- Invalid args exit non-zero with message to stderr
- `completions <shell>` exits `0` with non-empty stdout
- If `--mcp` supported: smoke test that `--mcp` starts without crashing and responds to an
  `initialize` request
- If signal handling supported: test SIGINT produces exit `130` and any cleanup

Do not test engine logic from CLI tests.

```rust
use starbase_sandbox::create_sandbox;

#[test]
fn run_on_valid_input() {
    let sandbox = create_sandbox("fixtures/valid");
    sandbox
        .run_bin("myapp", |cmd| {
            cmd.arg("run").arg("--path").arg(".");
        })
        .assert()
        .success();
}
```

## Workspace Cargo.toml

Seeded by `configs/rust/Cargo.copy.toml` with `[workspace.lints]` appended by
`configs/rust/clippy-cargo.concat.toml`. Every member crate inherits lints with
`[lints] workspace = true`.

```toml
[workspace]
resolver = "2"
members = [
  "fuzz-common",
  "fuzz-core",
  "{project}-cli",
  "{project}-engine",
]

[workspace.package]
version = "0.1.0"
edition = "2024"
license = "MIT"
repository = "https://github.com/tomdavidson/{project}"

[workspace.dependencies]
clap = { version = "4", features = ["derive"] }
clap_complete = "4"
miette = { version = "7", features = ["fancy"] }
schematic = { version = "0.19", features = ["yaml", "renderer_json_schema"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
thiserror = "2"
# Async stack (async projects only)
tokio = { version = "1", features = ["full"] }
tokio-util = "0.7"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }

# [workspace.lints.rust] and [workspace.lints.clippy] are appended by
# .tack/configs/rust/clippy-cargo.concat.toml
```

## Tooling and Project Files (`tack` Delivery)

| File                               | Delivered By     | Purpose                                                                                |
| ---------------------------------- | ---------------- | -------------------------------------------------------------------------------------- |
| `.prototools`                      | `configs/common` | Pin tool versions (`moon`, `dprint`, `yq`, `tera`)                                     |
| `dprint.json` / `.editorconfig`    | `configs/common` | Formatter config (`rustfmt` exec plugin, TOML, JSON, Markdown)                         |
| `moon.yml`                         | `.moon`          | Root moon config (`fmt`, `fmt-check`, `lint-sh`)                                       |
| `.moon/tasks/rust.yml`             | `configs/rust`   | Tag-inherited (`tags: ["rust"]`) tasks: `lint`, `typecheck`, `test`, `audit`, `verify` |
| `.rustfmt.toml`                    | `configs/rust`   | Rustfmt rules (Edition 2024, 110 width, crate-grouped imports)                         |
| `.clippy.toml`                     | `configs/rust`   | Clippy thresholds (30 lines, 4 args, complexity 8, nesting 2)                          |
| `Cargo.toml` (`[workspace.lints]`) | `configs/rust`   | Seeded root `Cargo.toml` + concatenated Clippy & Rust lints                            |
| `deny.toml`                        | `configs/rust`   | `cargo-deny` license and advisory checks                                               |
| `renovate.json`                    | `configs/github` | Dependency updates                                                                     |
| `release-please-config.json`       | `configs/github` | `release-type: "rust"`, workspace `Cargo.toml` under `extra-files`                     |
| `docs/adrs/`                       | repo-owned       | ADRs for crate organization (`0001`) and plugin/policy strategy                        |

## Anti-Patterns

| Don't                                                  | Instead                                                       |
| ------------------------------------------------------ | ------------------------------------------------------------- |
| Business logic in command handlers                     | Put in `{project}-engine`                                     |
| `unwrap()`/`expect()` in non-test CLI code             | Use `?`                                                       |
| `std::process::exit` when `starbase_console` is active | Return `Result` from `main`; let `Drop` flush                 |
| Log to stdout                                          | Always stderr                                                 |
| `println!` in commands when `--mcp` may be active      | Return structured data; dispatcher decides                    |
| Sparse or missing doc comments on `Args` fields        | Every field has a `///` — it becomes the MCP tool description |
| Default `parallel_safe = false` on all MCP commands    | Mark read-only commands `parallel_safe`                       |
| Tokio in sync-only project                             | Don't add speculatively                                       |
| Engine imports `clap` or `miette`                      | Engine has zero CLI deps                                      |
| Config loading in `main.rs`                            | In `app.rs` or engine config module                           |
| Shared `App` state struct                              | Free functions; inject at call site                           |
| `starbase_events` when no plugin system needed         | Plain `app.rs`                                                |
| Plugin via WASM when a Rust trait impl works           | Only reach for WASM when users write extensions               |
| Generic `engine` / `cli` as `[package] name`           | Use `{project}-engine` / `{project}`                          |
| Isolated `engine/fuzz` excluded from workspace         | Root workspace members `fuzz-common` + `fuzz-core`            |
| Hidden `completions` subcommand                        | Visible, so users discover it                                 |
| `--color` and `NO_COLOR` ignored                       | Support both; detect TTY via `IsTerminal`                     |

## Checklist

- [ ] Engine crate has zero `clap` or `miette` deps and returns typed `Result<T, E>` with `thiserror`
- [ ] All member crates set `[lints] workspace = true`
- [ ] Crate naming strategy chosen; `[package] name` unique on crates.io
- [ ] CLI crate has `main.rs`, `app.rs`, `commands/`
- [ ] `app.rs` owns bootstrap: error reporter, tracing, config loading, signal handler
- [ ] One file per subcommand; every `Args` field has a `///` doc comment
- [ ] Sync vs async decision explicit; `main` returns `Result` so `Drop` flushes
- [ ] All log/trace output to `stderr`; tracing writer set before any MCP mode
- [ ] Exit code mapping exhaustive; SIGINT → `130`
- [ ] Shell completions visible; `clap_complete` + `ValueEnum` wrapper
- [ ] `--color always|auto|never` and `NO_COLOR` supported; `IsTerminal` for TTY detection
- [ ] State-mutating commands accept `--dry-run`; engine respects it
- [ ] Plugin strategy matches decision guide
- [ ] `clap-mcp` maturity evaluated; `reinvocation_safe = false` unless stdout discipline verified
- [ ] `parallel_safe` set per-command based on read-only vs mutating
- [ ] `#[clap_mcp(skip)]` on init, completions, and any stdout-interacting commands
- [ ] `fuzz-common` and `fuzz-core` in root `[workspace] members` with engine `build.rs` auto-regressions
- [ ] CLI tests use `assert_cmd` or `starbase_sandbox` (exact-pinned); engine logic tested in engine
- [ ] `cargo-dist` targets start minimal (3); expand on demand
- [ ] Proto plugin entry added to `tomdavidson/proto`
- [ ] `release-please-config.json` has `release-type: "rust"` and workspace `Cargo.toml` in `extra-files`
- [ ] `docs/adrs/` entries for crate organization (`0001`), plugin strategy, MCP stance
- [ ] `configs/common`, `configs/rust`, `configs/github`, and `.moon` applied via `tack`
