---
number: 11
title: Pin task-executed desktop toolchains in devenv
date: 2026-10-29
status: proposed
tags:
  - devenv
  - bwrap
  - freecad
---

# 11. Pin task-executed desktop toolchains in devenv

Date: 2026-10-29

## Status

Proposed

## Context

ADR-0006 splits tool ownership between proto (self-contained binaries) and
devenv (native-library tools, services). It does not name a third class:
desktop applications whose headless binary is executed by moon tasks.
FreeCAD is the first instance. The modeller runs in a GUI the host installs
however it likes (AppImage, distro package, flatpak); `freecad-lens` tasks
spawn `freecadcmd` to read and, on import, save the same documents.

A consumer (`domus-labora`, 2026-10-29) wrote "desktop apps come from the
host" into its `tackrc.yml`, left `freecadcmd` unpinned, and resolved it with
`shutil.which`. Inside the ADR-0007 sandbox `$HOME` is a tmpfs and `/usr` is
bound read-only, so the only FreeCAD visible to a moon task was the distro's
1.0 while the author modelled in a 1.1 AppImage under `~/Applications`. Every
`test-unit` run silently loaded 1.1 documents with 1.0, and an `import` would
have saved through 1.0. Nothing declared the required version and nothing
checked it; the one file that could (`devenv.nix`) is seed-once and
consumer-owned, so tack never touched it. This is the drift ADR-0006 exists to
prevent, in a tool class it did not cover.

Two facts constrain the fix. The GUI and the headless binary need not be the
same build: FreeCAD documents are compatible within a minor release and the
user `Mod/` directory is per-major, so a Nix `freecadcmd` 1.1.x and an
AppImage GUI 1.1.y coexist. And the headless binary must live where the
sandbox can see it: `/nix` is bound read-only into every bwrap sandbox
(ADR-0007); `~/Applications` never is.

## Decision

1. A desktop application's headless binary that any moon task executes is a
   toolchain. It is pinned by devenv (native-library tools, ADR-0006) or by
   proto where a plugin exists. Resolving it from the host `PATH` is never
   acceptable for task execution. Consumers may still install the GUI from
   the host; that install is not what tasks run.

2. Each such tool is a tack package delivering a devenv module (ADR-0009
   decision 6): `configs/<tool>/<tool>.nix`, imported from `.tack`, never
   materialized. The module adds the package, exports an environment
   variable naming the headless binary by store path (`FREECADCMD`), and
   uses `lib.mkDefault` for everything a consumer may override (ADR-0008).

3. When the stable nixpkgs the consumer tracks is behind the version the
   modelling GUI uses, the module takes the package from a second input the
   consumer declares in its seed-once `devenv.yaml` (`nixpkgs-<tool>`), and
   falls back to `pkgs.<tool>` when that input is absent so evaluation never
   fails. The input is pinned by the consumer's `devenv.lock` like any other.

4. Tools that drive the headless binary (`freecad-lens`) are reached by
   name through a devenv script the module defines, never by a repo-relative
   path in a shared task file. The script selects an in-repo checkout
   (`<TOOL>_PROJECT`, `uv run --project`) or a published/git spec
   (`<TOOL>_SPEC`, `uv tool run --from`), both through the sandboxed `uv`
   from `configs/python`.

5. Task files for the package live in the package (`configs/<tool>/.moon/
   tasks/<tool>.yml`, ADR-0010), are delivered as copies (moon skips symlinks
   under `.moon/tasks/`), and are inherited by `tags: [<tool>]`.

6. The driving tool must verify the binary it spawns: read the version from
   the child process and refuse when it does not satisfy the range declared
   in the project's config (`freecad-lens.toml` `[model] freecad = "~=1.1"`).
   It must prefer the pinned environment variable over any in-process import
   when the variable is set. tack cannot enforce this inside the tool, but
   the package README states it as the contract.

## Consequences

- `configs/freecad` is the first package under this ADR: `freecad.nix`,
  `tack.yml`, `.moon/tasks/freecad.yml`, a `vars.freecad` stanza in
  `tackrc-defaults.yml`. A second FreeCAD project enables it with one `pkgs`
  line, one import, and one `devenv.yaml` input.
- Consumers pay a FreeCAD Nix closure (roughly 2 to 3 GB) for a binary they
  never launch as a GUI. The GUI stays host-installed; on non-NixOS hosts the
  Nix GUI would need nixGL and is not supported by this package.
- `freecadcmd` from nixpkgs may trail the GUI by a patch release. The
  driving tool's guard compares major.minor and warns on patch.
- The tackrc comment "desktop apps come from the host" in existing consumers
  is wrong under this ADR and is removed when they adopt the package.
- Supplements ADR-0006; neither supersedes the other.
