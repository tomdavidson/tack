# configs/devenv/bwrap.nix
# devenv module imported from the .tack submodule; never materialized.
#
# Declares `tack.bwrap.passEnv`: variable names that must cross the
# bwrap-run sandbox boundary. bwrap-run.sh starts every sandbox with
# --clearenv and re-adds a fixed allowlist (PATH, HOME, NIX_*, ...), so a
# variable a devenv module sets for a tool (a pinned binary path such as
# FREECADCMD) is invisible to that tool once it runs sandboxed unless it is
# listed here. The merged list is rendered into env.BWRAP_PASS_ENV, which
# bwrap-run reads; exact names, no globs, and bwrap-run's secret-name
# filter (*TOKEN*, *KEY*, ...) still drops matches.
#
# Any module may import this file and append to the list; the module system
# merges lists, so several packs can declare their names independently:
#
#   imports = [ ../devenv/bwrap.nix ];
#   tack.bwrap.passEnv = [ "FREECADCMD" "QT_QPA_PLATFORM" ];
#
# Consumers may add names in their own devenv.nix the same way. Lives in
# configs/devenv/ so it is part of the ADR-0008 host-executed surface and
# other modules may reference it by relative path.
{
  lib,
  config,
  ...
}: {
  options.tack.bwrap.passEnv = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    example = ["FREECADCMD" "QT_QPA_PLATFORM"];
    description = ''
      Environment variable names that bwrap-run passes into the sandbox
      in addition to its fixed allowlist. Exact names only.
    '';
  };

  config.env.BWRAP_PASS_ENV =
    lib.concatStringsSep ":" (lib.unique config.tack.bwrap.passEnv);
}
