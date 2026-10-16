---
number: 8
title: Writable .tack with a read-only host-executed surface
date: 2026-10-13
status: proposed
---

# 8. Writable .tack with a read-only host-executed surface

Date: 2026-10-13

## Status

Proposed

## Context

ADR-0007 mounts the whole submodule read-only inside the bwrap sandbox so that sandboxed dependency code cannot plant persistence in files that later execute on the host. tack's theory of use conflicts with that blanket mount: shared configuration is linked, not copied, so a consumer edits , , or a in place, the change lands in the submodule working tree, and the consumer commits it there and opens a pull request upstream. Other consumers bump the submodule to receive it. Editor edits and git operations run on the host and are unaffected by the mount, but sandboxed tools that legitimately rewrite linked configuration (, , on a linked , migrations, codegen tasks) fail with EROFS. The failure surfaced on 2026-10-13 in a consumer whose had been linked into by an over-broad in ; the read-only mount turned silent cross-repo cache pollution into a hard error (fixed separately by ignoring and in that package). Dev-time symlinks () are also in use; bwrap-run already resolves them with realpath and binds the real target.Only a small subset of executes on the host: and the package behind it (runs lnko and renders templates), (, , and the Tera templates that become , , and ), the devenv modules that consumers import by path (, , ), whose , , , and are evaluated and executed by devenv on the host, and the submodule's git hooks (, or for a dev symlink). Everything else in is data read by tools that already run inside the sandbox.A related question is whether imported tack modules override the consumer's . They do not replace it; the module system merges them. List options (, ) concatenate, is and concatenates, attribute sets (, ) merge per key, and a scalar or same-key definition in both files is a conflicting-definition error unless one side sets a priority. Tack modules therefore use for anything a consumer may plausibly override and plain definitions only for invariants (e.g. the wrapper), so the consumer's ordinary definition wins without .

## Decision

The guiding rule: inside the sandbox, code the host executes is read-only; everything else in `.tack` is data and stays writable. Where `tack.sh` currently turns data into host execution, `tack.sh` changes so that the data can remain data.

1. `.tack` is bind-mounted writable inside the sandbox, as part of the writable repo root, both when it is a real submodule and when it is a symlink to a local checkout (bound at the realpath). Sandboxed tools can edit linked configuration (`ruff.toml`, `biome.json`, `.moon/tasks/*.yml`, `tack.yml`, `.prototools`, `tackrc-defaults.yml`) and the consumer commits and contributes it upstream.

2. The host-executed surface inside `.tack` is pinned read-only on top of the writable bind, using the same layering bwrap-run already applies to `.envrc`, `devenv.nix`, and `.git/hooks` at the repo root. The surface is defined by location, not by an enumerated file list: (a) `tack.sh`; (b) the whole `configs/devenv/` directory (bwrap scripts and the Tera templates that become `.envrc`, `devenv.nix`, `devenv.yaml`); (c) `configs/<area>/scripts/` directories, which devenv modules execute as tasks and processes (today `configs/drupal/scripts/`); (d) every `*.nix` file under `.tack`, bound individually so sibling data files stay writable, because devenv evaluates them and runs their `enterShell`/`scripts`/`tasks` on the host; (e) the submodule's git hooks directory, located by reading the `gitdir:` pointer in `.tack/.git` (and `commondir` for linked worktrees) without shelling out to git.

3. Convention: host-executed code in tack lives only in `tack.sh`, `configs/devenv/`, `configs/<area>/scripts/`, and `*.nix` devenv modules. Modules must not reference other files in `.tack` via relative paths, `builtins.readFile`, or `import` except files inside that set. Templates and `.envrc` likewise reference only the pinned surface.

4. `tack.sh` treats checkout data as data. It runs on the host, initially outside any devenv shell and afterwards only on updates or during tack development, so it: (a) executes `post:` command lines and the proto-provisioned `yq`/`tera` binaries through `bwrap-run` whenever bwrap is on PATH, can create a user namespace, and `TACK_ROOT` is the consumer's `.tack`; otherwise it runs them directly with a logged notice. The first run of a fresh clone has no bwrap and no executed dependency code; a host whose kernel restricts unprivileged user namespaces and has no `bwrap-apparmor` profile also runs direct, because `tack.sh` must work before any host setup. The sandbox is therefore best-effort in `tack.sh` and mandatory only in the devenv wrappers. `TACK_SANDBOX=0` forces direct execution. Sandboxed helpers run with `BWRAP_STRICT=1` (tack.sh never writes into `.tack`) and with `TMPDIR` under the consumer root so scratch files are visible inside the sandbox; (b) refuses to write, link, or redirect (`files.<src>.target`, `path_prefix`, `mode:`) into protected consumer paths — `.envrc`, `devenv.*`, `flake.*`, `nix/`, `.git/`, `.tack/`, any path containing `..` — unless the source file is itself pinned: under `configs/devenv/` or a `*.nix` file; (c) keeps `proto trust` scoped to `configs/common/.prototools` as today; a tampered pinfile can at most install a binary that then runs confined by (a).

5. Tests: `configs/devenv/tests/bwrap.bats` collects every `.tack/`-relative path referenced from the Tera templates, `.envrc`, and all `*.nix` files and fails if any falls outside the pinned surface; fixture tests run bwrap-run against a submodule-style and a symlinked `.tack` and assert that `ruff.toml` and a `tack.yml` are writable while `tack.sh`, `bwrap-run.sh`, `python.nix`, a `configs/*/scripts/` file, and the hooks directory fail with EROFS, and that `BWRAP_STRICT=1` makes all of `.tack` read-only. `tests/protected.bats` asserts the protected-target refusals, the pinned-source allowances, and the sandbox-selection rules.

6. `BWRAP_STRICT=1` keeps the ADR-0007 behaviour of mounting all of `.tack` read-only.

7. Tack devenv modules set `lib.mkDefault` on any option a consumer may reasonably override and document in a header comment which definitions are invariants, so the rendered `devenv.nix` comment "override any module default after this import block" stays accurate.

8. The `.moon` package ignores `cache/*` and `hooks/*` so moon runtime state present in a dev checkout is never linked into consumers; this is what surfaced the problem and remains required regardless of the mount layout.

## Consequences

Linked configuration under , including package manifests and pin files, is editable by sandboxed formatters, package managers, and moon tasks; the edit-commit-PR loop tack is designed around works without leaving the sandbox or toggling environment variables.The protection ADR-0007 provides is unchanged in kind: every file the host executes directly remains read-only to sandboxed code, and the indirect paths through (, target redirection, provisioned binaries) are closed in itself rather than by widening the read-only set.Sandboxed code can modify tack data that other consumers receive after a submodule bump; that path already exists for the consumer's own and is gated by pull-request review. modules cannot be rewritten by sandboxed tools (e.g. a sandboxed ); nix formatters are nix-provided, not pip/npm tools, so they run unsandboxed on the host.Adding host-executed code outside , , or a module is a convention violation caught by the bats guard; the guard, not a hand-maintained bind list, must stay correct. gains a dependency on for its own helper execution when available; first-run bootstrap without bwrap is logged, not blocked.bwrap-run gains one mount per file; negligible against bwrap's startup cost.The package must keep and ignored; a writable would otherwise hide, rather than fail on, consumer state written into the shared checkout.Follow-up outside this ADR: in the consumer repo and for the submodule carry and and are writable today; they belong in the read-only set alongside .Supersedes the implicit whole-submodule read-only mount in ADR-0007 decision 6; the rest of ADR-0007 stands.
