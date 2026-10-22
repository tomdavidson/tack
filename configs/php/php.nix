# configs/php/php.nix
# devenv module imported from the .tack submodule; never materialized.
#
# Consumer devenv.nix (or vars.devenv.imports in tackrc.yml):
#   imports = [ ./.tack/configs/php/php.nix ];
#
# Provides PHP + Composer through devenv's languages.php, and a bwrap
# wrapper for composer. Composer is enabled automatically by
# languages.php.enable; no separate composer option is needed.
#
# Consumer overrides go in the consumer's devenv.nix after the import
# (ADR-0009 decision 6: Nix is a module, never a concat fragment):
#   languages.php.version = "8.4";
#   packages = [ pkgs.php84Packages.composer2 ];
# The module system merges `packages`; no `(config.packages or []) ++`.
#
# Override rule (ADR-0008): values a consumer may reasonably change carry
# lib.mkDefault so a plain assignment in the consumer devenv.nix wins.
# Invariants (the sandboxed composer wrapper) are defined without a
# priority; a consumer that must replace one uses lib.mkForce.
{
  pkgs,
  lib,
  config,
  ...
}: let
  projectRoot = toString config.devenv.root;
  bwrapRun = "${projectRoot}/.tack/configs/devenv/bwrap-run.sh";
in {
  languages.php = {
    enable = lib.mkDefault true;
    version = lib.mkDefault "8.3";
  };

  # composer runs inside the bwrap sandbox like every other package
  # manager wrapper tack ships. Requires vars.bwrap.enabled (default
  # true); bwrap-run.sh lives in .tack. A bare name is passed, not a
  # store path, because composer comes from languages.php's PHP package
  # set and bwrap-run resolves it through PATH inside the devenv shell.
  scripts.composer.exec = ''
    exec env \
      BWRAP_REPO_ROOT=${lib.escapeShellArg projectRoot} \
      ${lib.escapeShellArg bwrapRun} composer "$@"
  '';

  enterShell = ''
    export PATH="${projectRoot}/vendor/bin:$PATH"
  '';
}
