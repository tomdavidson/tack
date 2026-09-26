---
number: 7
title: Adopt bubblewrap sandboxing for dependency-executing tools
date: 2026-09-26
status: proposed
tags:
  - devenv
  - sbx
  - security
  - bwrap
---

# 7. Adopt bubblewrap sandboxing for dependency-executing tools

Date: 2026-09-26

## Status

Proposed

## Context

devenv and proto make development environments reproducible, but nothing
constrains what installed dependencies execute. A malicious `preinstall`
script in an npm package, a compromised crate build script, or a typo-squat
on PyPI runs with the developer's full credentials: ssh keys, cloud tokens,
browser profiles, and write access to everything the user can write.

Containers solve this badly in this setting. Nesting Podman or Docker
inside the devcontainer or devenv shell requires privileged mode or a
shared daemon socket, and both defeat the isolation goal. MicroVMs (Kata,
Docker Sandboxes) need nested KVM. Landlock covers filesystem rules only.
Bubblewrap is the same unprivileged user-namespace mechanism Flatpak uses:
no daemon, sub-millisecond startup, and it works as a plain wrapper around
individual commands (see `docs/sbx.md` for the comparison).

Ubuntu 23.10+ restricts unprivileged user namespaces through AppArmor, so
a host-side profile is required for bwrap to run at all (ADR-0006 hosts
are KDE Neon on a 24.04 base).

Toolchain ownership is split between proto and devenv (ADR-0006): node,
pnpm, moon, and rust come from proto; PHP and services come from devenv.
The sandbox wrapper must resolve tools from both sources.

moon resolves task binaries through proto directly, bypassing devenv's
PATH, so per-tool wrappers do not cover moon tasks.

## Decision

1. Adopt bubblewrap, packaged inside tack (no separate toolbox repo),
   exported from a root `flake.nix` as `sbx`, `sbx-apparmor`, and the
   pinned `bubblewrap`. The helper scripts live in `pkgs/` and are
   shellcheck-clean so CI validates them.

2. devenv scripts wrap tools with `exec sbx <tool>`. `sbx` resolves the
   real binary on the host before the sandbox starts: `proto bin` first,
   then proto shims, then `~/.cargo/bin`, then PATH. This handles both
   proto-owned and devenv-owned tools with one mechanism.

3. Wrap `moon` itself, not the tools it spawns. Everything a moon task
   runs shares one sandbox. This is an accepted scope decision; per-tool
   wrapping inside moon is tracked in issue #13 and
   `docs/sbx-moon-sandbox-scope.md`.

4. The AppArmor profile is managed by `sbx-apparmor`, which binds the
   profile to the exact bwrap store path built alongside it. One
   `sudo sbx-apparmor install` per machine; re-run when bubblewrap
   updates change the store path. `enterShell` checks state and never
   runs sudo itself.

5. Writable surface is minimized to the repo root plus a shared dev root
   (`~/dev` by default) that also holds the package caches. Keeping the
   pnpm store and all projects under one bind mount preserves pnpm
   hardlink dedup; splitting them makes pnpm silently fall back to
   copying. Sibling projects under the dev root are writable from inside
   the sandbox, which is accepted.

6. `devenv.nix` and `devenv.yaml` render with `overwrite: false`
   (ADR-0006), so existing consumers reconcile this template change by
   hand.

## Consequences

- `tackrc-defaults.yml` moves `devenv:` under `vars:`, fixing a latent
  mismatch where templates referenced `vars.devenv.*` against a
  top-level `devenv:` key that never resolved.
- Sandboxed tools lose read access to host credentials by design. Tools
  that legitimately need them (git push over ssh, cloud CLIs) fail and
  must run unsandboxed or receive scoped tokens explicitly.
- The pnpm store, cargo registry, and other caches live under
  `$SBX_DEV_ROOT/.sbx` and are shared across projects inside the sandbox.
- Python venv activation inside the sandbox bypasses the wrapper; use
  `uv run` (documented in `docs/sbx.md`).
- The moon pre-push hook runs outside the devenv shell and is not
  sandboxed (accepted risk: it only operates on committed code).
- Items not verifiable in CI (bwrap on a restricted host, DNS through
  `/run/systemd/resolve`, hardlink behavior of the pinned pnpm) are
  listed in `docs/sbx.md` as host acceptance steps.
