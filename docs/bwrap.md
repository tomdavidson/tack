# bwrap-run: bubblewrap sandboxing for tack devenv shells

bwrap-run runs development tools inside an unprivileged bubblewrap sandbox
so a malicious dependency (an npm `preinstall` script, a crate `build.rs`, a
typo-squat on PyPI) cannot read ssh keys and cloud credentials, exfiltrate
shell history, or plant persistence in files that execute outside the
project.

Implementation: `configs/devenv/bwrap-run.sh` (wrapper) and
`configs/devenv/bwrap-apparmor.sh` (host AppArmor helper), plain shell
scripts that stay inside tack. Consumers execute them through the tack
submodule at `.tack/configs/devenv/`; they are never copied or symlinked
into the consuming repository. The consumer's devenv provides
`pkgs.bubblewrap` and `pkgs.apparmor-utils` from its own pinned nixpkgs.
Decision record: ADR-0007.

## Why bubblewrap

Full container engines are the wrong layer for wrapping ad-hoc CLI calls
inside an existing devcontainer or devenv shell. Nested Podman/Docker needs
privileged mode or a shared daemon socket, which removes the boundary the
sandbox exists to create. MicroVMs (Kata, Docker Sandboxes) need nested KVM.
Landlock is filesystem-only. Bubblewrap is the unprivileged user-namespace
mechanism Flatpak uses: no daemon, instant startup, and it wraps single
commands.

The tradeoff is that bwrap needs unprivileged user namespaces. Ubuntu 23.10+
(and KDE Neon on a 24.04 base) restrict those through AppArmor, so one host
setup step is required (below).

## What the sandbox does

Visible to the wrapped tool:

- `$HOME` is an empty tmpfs. `~/.ssh`, `~/.aws`, `~/.config`, browser
  profiles, and shell history do not exist inside.
- `/run` is an empty tmpfs (no ssh-agent, gpg-agent, D-Bus, Wayland, or
  Nix daemon sockets). `/run/systemd/resolve` is bound back read-only for
  DNS.
- `/media` and `/mnt` are absent. `/nix` is read-only.
- `/usr`, `/etc`, `/opt`, and usrmerge dirs are read-only.
- Repo files that later execute outside the sandbox are read-only:
  `.git/hooks`, `.envrc`, `devenv.nix`, `devenv.yaml`, `devenv.lock`,
  `flake.lock`, `nix/`, and the `.tack` submodule. Sandboxed code cannot
  plant a git hook or edit devenv to run as you later.
- Nested user namespaces are disabled (`--disable-userns` together with
  `--unshare-user`), so sandboxed code cannot escape into its own userns.
  `BWRAP_ALLOW_USERNS=1` opts in for Chromium and Playwright.
- The environment is cleared and rebuilt from an allowlist (PATH, HOME,
  TERM, locale, `NIX_*` compiler vars, `PKG_CONFIG*`, proto/cargo/rustup
  homes). Anything named like a secret (TOKEN, SECRET, PASSWORD, KEY, CRED)
  is dropped even if it matches the allowlist.
- Network is shared by default; `BWRAP_NO_NET=1` disables it.

Writable:

- The repo root, always.
- When the repo is under the dev root (default `~/dev`, or
  `BWRAP_DEV_ROOT`), the entire dev root is one bind mount: sibling
  projects are writable, in exchange for pnpm hardlink dedup across them
  (see caches).
- Package caches under the dev root's `.bwrap/` directory.

Git identity survives: `~/.gitconfig` and `~/.config/git` are bound
read-only so `git commit` inside the sandbox still has user.name and
user.email. Do not store credentials in gitconfig; they would be readable.

## Tool resolution

`bwrap-run <tool>` resolves the real binary on the host, before the
sandbox starts, because `proto bin` and `$HOME` lookups must not run inside
it:

1. An explicit path (contains `/`) is used verbatim.
2. `proto bin <tool>` for proto tool IDs (node, pnpm, moon).
3. `$PROTO_HOME/shims/<tool>` for proto-provided bins (npx, npm, corepack).
4. `$CARGO_HOME/bin/<tool>` for rust; proto's rust plugin keeps its
   binaries there and creates no shims.
5. PATH, skipping `*/.devenv*` script wrappers (they call back into
   bwrap-run).

Re-entry is a no-op: `BWRAP_ACTIVE` is set in the sandbox, and bwrap-run
called from inside it execs the resolved command directly. A moon task that
invokes `node` through devenv's wrapped PATH therefore resolves the real
node inside the same sandbox instead of nesting.

`bwrap-run --print-cmd <tool>` prints the resolved path without starting a
sandbox (used by the test suite and useful for debugging).

## Caches

All caches live under the dev root's `.bwrap/` (`$BWRAP_DEV_ROOT/.bwrap`),
or `~/.cache/bwrap` when the repo is not under a dev root:

- pnpm store: `.bwrap/pnpm-store`, set via `pnpm_config_store_dir`.
  pnpm 10+ only reads `pnpm_config_*`, not `npm_config_*`.
- cargo: `~/.cargo` is bound read-only with `registry/` and `git/`
  overlaid writable onto the cache. When the host has no rust toolchain,
  `CARGO_HOME` points at `.bwrap/cargo-home` instead.
- pip and uv: `PIP_CACHE_DIR`, `UV_CACHE_DIR`.
- proto: `~/.proto` is read-only; `~/.proto/cache` is overlaid writable.
  A missing tool cannot auto-install inside the sandbox (read-only
  `~/.proto/tools`); install it on the host with `proto install`.

### pnpm hardlinks and the single mount

Hardlinks cannot cross mount points: `link(2)` returns `EXDEV` even on the
same filesystem when the two paths are on different bind mounts, and pnpm
then silently falls back to copying every file. bwrap-run puts the store
and the projects on ONE bind mount (the dev root), so hardlinks work and
the store is shared across projects. When the repo is outside the dev root,
bwrap-run logs a notice and pnpm copies; move the repo under the dev root
or set `BWRAP_DEV_ROOT` to restore dedup.

The pnpm documentation only recommends sharing a store between processes
you trust. Every project under the dev root can read and write the shared
store; a poisoned store is a cross-project attack channel. `BWRAP_STRICT=1`
binds only the current repo (pnpm then copies instead of linking).

## Host setup: AppArmor

Check whether the kernel restricts unprivileged user namespaces:

```sh
sysctl kernel.apparmor_restrict_unprivileged_userns
```

If it prints `0`, nothing is needed. If it prints `1` (Ubuntu 23.10+,
KDE Neon on 24.04), bwrap is blocked until a profile allows it:

```sh
bwrap-apparmor install   # one-time sudo; writes /etc/apparmor.d/bwrap-run-<hash>
```

`bwrap-apparmor` writes the profile bound to the exact bwrap path it
resolves (`BWRAP_BIN`, default the bubblewrap on PATH, which is the
consumer's `pkgs.bubblewrap`), tighter than a `/nix/store/*-bubblewrap-*`
glob, which any process that can write to the Nix store could match. sudo
and `/usr/sbin/apparmor_parser` come from the host on purpose: setuid sudo
cannot come from the Nix store, and the parser must match the host kernel.

Commands: `check [--quiet]` (no root, used by `enterShell`), `install`,
`prune` (drop profiles whose bwrap was garbage-collected), `uninstall`,
`path` (print the profiled bwrap).

Re-run `install` whenever bubblewrap updates and its store path changes;
`enterShell` reports the failure. Because bwrap comes from the consumer's
own pinned nixpkgs, the profile and the executed binary stay in lockstep
with `devenv.lock`.

## Consumer setup

Apply `configs/devenv` (default through `pkgs: configs/*`). Only the
templates materialize; the sandbox scripts stay in the `.tack` submodule.
The rendered `devenv.nix` gains `pkgs.bubblewrap` and `pkgs.apparmor-utils`,
an `enterShell` AppArmor check, and one script per tool:

```nix
scripts.moon.exec = ''
  exec env \
    BWRAP_REPO_ROOT=<projectRoot> \
    <projectRoot>/.tack/configs/devenv/bwrap-run.sh moon "$@"
'';
```

Wrappers invoke `.tack/configs/devenv/bwrap-run.sh` by absolute path
(derived from `config.devenv.root`, shell-quoted with
`lib.escapeShellArg`) and pass `BWRAP_REPO_ROOT`, so bwrap-run never has
to guess the repo root. bwrap-run treats `BWRAP_REPO_ROOT` as
authoritative; when the script is invoked directly, without it, an
ancestor walk from the working directory finds the nearest repository
root without running git: a `.git` directory stops the walk, a `.git`
file pointing through `/modules/` (submodule worktree) continues upward,
and one pointing through `/worktrees/` (linked worktree) stops there.

Defaults (override in the consumer `tackrc.yml` under `vars:`):

```yaml
vars:
  bwrap:
    enabled: true
    tools: [node, npx, pnpm, moon, cargo, rustc]
```

Set `enabled: false` to render the plain template with no sandbox wiring
(no scripts, no `let` block, no bubblewrap packages). tack only
materializes files whose location in the consuming repository is
functionally significant; the bwrap scripts have none, so they are
excluded from materialization entirely. `devenv.nix` and `devenv.yaml`
render with `overwrite: false`, so existing consumers reconcile template
changes by hand (ADR-0006).

The pre-push hook in `.moon/workspace-base.yml` runs outside the devenv
shell and stays unsandboxed; accepted in
`docs/bwrap-moon-sandbox-scope.md` (rename of
`docs/sbx-moon-sandbox-scope.md` pending after this change lands).

## Tool notes

- **pnpm**: use pnpm 10.26+ (blocks dependency install scripts by default
  and fixes CVE-2025-69264). Approve builds explicitly with
  `pnpm approve-builds`. Store sharing and hardlinks are covered above.
- **moon**: wrapped at the moon level; every tool a task spawns runs in
  one sandbox. Per-tool wrapping is issue #13.
- **cargo/rustc**: resolved from `~/.cargo/bin`; `~/.rustup` is bound
  read-only. `build.rs` and proc macros run inside the sandbox.
- **rust-analyzer** runs build scripts; keep using it through the wrapped
  `cargo` (editor-launched instances that call the raw binary are not
  covered).
- **pip/uv**: caches redirected; `PYTHONDONTWRITEBYTECODE=1` because
  site-packages are read-only. Activating a venv puts the raw interpreter
  first on PATH and bypasses the wrapper; use `uv run` instead.
- **composer**: `auth.json` is hidden with the rest of `$HOME`. Passing
  `COMPOSER_AUTH` or a GitHub token into the sandbox exposes it to every
  process in it, the code you are containing included; prefer short-lived
  narrowly scoped tokens and explicit opt-in.
- **node**: `npx` is wrapped by default because it executes arbitrary
  remote packages.
- **git**: reads and writes only the repo. Host credentials are hidden;
  push from outside the sandbox or pass scoped tokens deliberately.

## Settings

| Variable             | Default   | Effect                                                           |
| -------------------- | --------- | ---------------------------------------------------------------- |
| `BWRAP_REPO_ROOT`    | detected  | repo root exposed as writable; the devenv wrappers always set it |
| `BWRAP_BIN`          | from PATH | bwrap binary (the devenv `pkgs.bubblewrap`)                      |
| `BWRAP_DEV_ROOT`     | `~/dev`   | shared writable root for projects + caches                       |
| `BWRAP_STRICT`       | 0         | bind only the repo root; pnpm loses hardlinks                    |
| `BWRAP_NO_NET`       | 0         | 1 disables network access                                        |
| `BWRAP_ALLOW_USERNS` | 0         | 1 allows nested user namespaces                                  |
| `BWRAP_ACTIVE`       | unset     | set inside the sandbox; re-entry execs directly                  |

## Accepted risks

- Projects under the dev root can write each other and the shared pnpm
  store (the price of hardlink dedup). `BWRAP_STRICT=1` narrows it.
- The repo root itself is writable: sandboxed code can modify project
  source. Executable escape hatches that run later outside the sandbox are
  read-only, but code review still gates what you commit.
- Network is on by default: anything readable inside the sandbox can be
  sent out, including tokens passed in explicitly.
- Interactive `moon` runs are sandboxed; git hooks and editor-launched
  tooling are not.
- `~/.gitconfig` and `~/.config/git` are readable inside the sandbox.
- devenv's own bundled Node (used for some editor TypeScript tooling) is
  not wrapped.

## Acceptance checklist

Run these on the target host after wiring a consumer:

1. `bwrap-apparmor check` reports ok (or `install` then ok).
2. `devenv shell` prints the AppArmor warning only when a profile is
   missing.
3. `type -a pnpm node cargo moon` shows the devenv script wrappers first,
   then the real tools.
4. `pnpm install` inside the shell completes and
   `stat -c '%h' node_modules/.pnpm/**/package.json` shows link counts
   above 1 when the repo is under the dev root.
5. `node -e "require('fs').readdirSync(process.env.HOME + '/.ssh')"`
   fails inside the sandbox.
6. `pnpm store path` prints the store under the dev root's `.bwrap/`.
7. A `git commit` from inside the sandbox still has user identity.
8. `journalctl -k | grep -i apparmor` shows no bwrap denials.

## Unverified items

These could not be verified in CI and need a host check:

- The pinned nixpkgs provides bubblewrap with `--disable-userns` (expected
  on nixos-25.05).
- DNS resolution through `/run/systemd/resolve` on the target Neon install
  (behavior differs when `/etc/resolv.conf` is a plain file).
- The pnpm version resolved by the consumer's proto pins honors
  `pnpm_config_store_dir` and `pnpm_config_cache_dir` (pnpm 10.26+).
- devenv `scripts` wrappers take PATH precedence over proto shims and
  devenv `packages` (asserted by devenv's script generation order).
- `config.devenv.root` in a consumer's rendered devenv.nix resolves to the
  expected project root when tack is checked out as the `.tack` submodule.
