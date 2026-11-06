# configs/freecad/freecad.nix
# devenv module imported from the .tack submodule; never materialized.
#
# Consumer devenv.nix (or vars.devenv.imports in tackrc.yml):
#   imports = [
#     ./.tack/configs/python/python.nix   # sandboxed uv; required
#     ./.tack/configs/freecad/freecad.nix
#   ];
#
# Consumer devenv.yaml (seed-once, consumer-owned). nixos-25.11 ships
# FreeCAD 1.0.2; the 1.1 line needs a second input:
#   inputs:
#     nixpkgs-freecad:
#       url: github:NixOS/nixpkgs/nixos-unstable
# Without it the module falls back to pkgs.freecad so evaluation never
# fails; freecad-lens's version guard then reports the mismatch.
#
# Provides (ADR-0011):
#   - pkgs.freecad in the shell, pinned by devenv.lock, visible inside the
#     bwrap sandbox because /nix is bound (ADR-0007). This is the headless
#     binary moon tasks run. The modelling GUI stays host-installed; on
#     non-NixOS hosts the Nix GUI needs nixGL and is not supported here.
#   - env.FREECADCMD: store path of FreeCADCmd. freecad-lens spawns this
#     and must prefer it over any in-process `import FreeCAD`.
#   - scripts.freecad-lens: the task-facing entry point. Shared task files
#     call `freecad-lens` by name and never a repo-relative path.
#       FREECAD_LENS_PROJECT=<dir>  -> uv run --project <dir> freecad-lens
#       else FREECAD_LENS_SPEC      -> uv tool run --from <spec> freecad-lens
#     Both go through the sandboxed `uv` script from python.nix.
#   - tack.bwrap.passEnv entries (via ../devenv/bwrap.nix) so the variables
#     above survive bwrap-run's --clearenv. Without this the sandboxed tool
#     never sees FREECADCMD and shutil.which falls back to the host's
#     /usr/bin/freecadcmd through the read-only /usr bind, which is exactly
#     the silent version drift ADR-0011 exists to stop.
#
# Override rule (ADR-0008): values a consumer may reasonably change carry
# lib.mkDefault so a plain assignment in the consumer devenv.nix wins.
# The freecad-lens wrapper is an invariant; replace it with lib.mkForce.
{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: let
  freecadPkgs =
    if inputs ? "nixpkgs-freecad"
    then
      import inputs."nixpkgs-freecad" {
        inherit (pkgs.stdenv.hostPlatform) system;
        config = {};
      }
    else pkgs;
  freecad = freecadPkgs.freecad;
  freecadCmd = "${freecad}/bin/FreeCADCmd";
in {
  imports = [../devenv/bwrap.nix];

  packages = [freecad];

  tack.bwrap.passEnv = [
    "FREECADCMD"
    "FREECAD_LENS_PROJECT"
    "FREECAD_LENS_SPEC"
    "QT_QPA_PLATFORM"
  ];

  env = {
    FREECADCMD = lib.mkDefault freecadCmd;
    # In-repo checkout of freecad-lens (pyproject dir). Empty = use SPEC.
    FREECAD_LENS_PROJECT = lib.mkDefault "";
    # Published or git spec for `uv tool run --from`. Pin a version or
    # commit here once freecad-lens has its own repository.
    FREECAD_LENS_SPEC = lib.mkDefault "freecad-lens";
  };

  scripts.freecad-lens.exec = ''
    # Headless Qt: FreeCADCmd still probes a platform plugin.
    export QT_QPA_PLATFORM="''${QT_QPA_PLATFORM:-offscreen}"
    if [ -n "''${FREECAD_LENS_PROJECT:-}" ]; then
      exec uv run --project "$FREECAD_LENS_PROJECT" freecad-lens "$@"
    fi
    exec uv tool run --from "$FREECAD_LENS_SPEC" freecad-lens "$@"
  '';
}
