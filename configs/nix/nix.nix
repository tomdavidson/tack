# configs/nix/nix.nix
# devenv module imported from the .tack submodule; never materialized.
#
# Consumer devenv.nix (or vars.devenv.imports in tackrc.yml):
#   imports = [ ./.tack/configs/nix/nix.nix ];
#
# Provides statix and deadnix for repositories authoring NixOS configurations,
# flakes, overlays, or Home Manager modules. Consumers that only use a
# rendered devenv.nix do NOT need this module (dprint-common.json already
# formats *.nix via alejandra).
#
# statix and deadnix are intentionally NOT wrapped in bwrap-run: bwrap-run
# pins **/*.nix read-only inside the sandbox (ADR-0008), which would block
# `statix fix` and `deadnix --edit` during `moon run :lint-fix`.
{pkgs, ...}: {
  packages = [
    pkgs.statix
    pkgs.deadnix
  ];
}
