# sbx sandbox scope: moon invocations

> **TL;DR for the implementing agent:** wrap `moon` itself as a devenv script
> (same pattern as `node`, `pnpm`, `cargo`). This is intentional and sufficient
> for the initial implementation. Do not try to wrap individual tools that moon
> spawns — that is tracked in issue #13.

## How moon resolves tools

When you run `moon run ~:test`, moon does not use devenv's PATH. It calls proto
internally to resolve the tool binary (e.g. `~/.proto/tools/node/22.x/bin/node`)
and execs it directly. This means:

- `scripts.node` and `scripts.pnpm` in devenv are **not consulted** by moon tasks
- Wrapping `node` or `pnpm` in devenv only protects direct shell invocations
- Moon tasks (lint, typecheck, test, build, fmt) all run through proto, bypassing
  devenv wrappers entirely

## What the initial sbx implementation does

The devenv script wraps `moon` itself:

```nix
scripts.moon.exec = ''exec sbx "$(proto bin moon)" "$@"'';
```

When you type `moon run ~:test` in the devenv shell, the chain is:

```
moon (sbx wrapper)
  └─ sbx → bwrap sandbox started
       └─ ~/.proto/tools/moon/2.5.5/bin/moon
            └─ proto resolves node → execs node (inside the sandbox)
                 └─ node runs eslint / vitest / tsc / ...
```

Everything moon spawns is inside **one shared sandbox**. This is:
- ✓ Better than no sandbox at all
- ✓ Host `$HOME`, secrets, ssh-agent, Wayland socket all hidden
- ✓ Nix daemon socket hidden
- ✗ All tools in a task share one sandbox — eslint and vitest can see the same
  mounts and env as cargo or wasm-pack
- ✗ No per-tool isolation or per-tool env policy

## The pre-push hook gap

`.moon/workspace-base.yml` embeds a pre-push hook that runs:

```sh
moon run :fmt :lint-fix --affected ...
git add ...
git commit -m "chore: auto-format and lint-fix before push"
.moon/scripts/auto-squash.sh check
```

This is executed by git in whatever shell context `git push` runs in — not inside
the devenv shell and not through the `scripts.moon` wrapper. The hook also calls
`git commit` and `auto-squash.sh` directly. These run fully unsandboxed.

**Accepted risk:** the hook only operates on committed/staged code. Dependency
code (npm packages, cargo crates) is not executed here; only workspace source
files (formatter, linter) are. The exposure is lower than during `pnpm install`
or `cargo build`.

## Trying `MOON_TOOLCHAIN_FORCE_GLOBALS`

Before implementing the full moon plugin (issue #13), try:

```nix
# devenv.nix
env.MOON_TOOLCHAIN_FORCE_GLOBALS = "true";
```

With this set, moon uses tools from PATH instead of proto. The devenv sbx
wrappers for `node`, `pnpm`, `cargo`, etc. then apply to moon tasks too,
giving per-tool sandboxes with no plugin required. The trade-off: moon stops
auto-installing toolchains, so proto must have them installed already. Test
this in the pilot; if it works cleanly, it obviates the issue #13 plugin work.

## Future: moon/proto plugin (issue #13)

See [issue #13](https://github.com/tomdavidson/tack/issues/13) for a full
breakdown of the plugin approach. The WASM plugin hook `extend_task_command`
could prepend `sbx` to every moon task command, giving per-tool sandboxes
that also apply inside VCS hooks. Key unknowns are still being investigated.
