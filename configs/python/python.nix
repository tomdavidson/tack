# configs/python/python.nix
# devenv module imported from the .tack submodule; never materialized.
#
# Consumer devenv.nix (or vars.devenv.imports in tackrc.yml):
#   imports = [ ./.tack/configs/python/python.nix ];
#
# Provides the uv binary and its bwrap wrapper. Nothing here pins an
# interpreter: uv downloads managed Pythons per project from
# .python-version / requires-python. UV_MANAGED_PYTHON=1 forbids falling
# back to a system Python so the host stays untouched.
#
# A devenv module is used instead of a devenv.concat.nix fragment because a
# second `packages = ...` in the same attrset is a Nix "attribute already
# defined" error; the module system merges packages/env/scripts cleanly.
#
# Do NOT also list `uv` in vars.bwrap.tools: that would define scripts.uv
# twice (here and in devenv.nix) and the module system rejects it.
#
# Override rule (ADR-0008): values a consumer may reasonably change carry
# lib.mkDefault so a plain assignment in the consumer devenv.nix wins.
# Invariants (the sandboxed uv wrapper) are defined without a priority;
# a consumer that must replace one uses lib.mkForce and owns the result.
{
  pkgs,
  lib,
  config,
  ...
}:

let
  projectRoot = toString config.devenv.root;
  bwrapRun = "${projectRoot}/.tack/configs/devenv/bwrap-run.sh";
in
{
  packages = [ pkgs.uv ];

  env.UV_MANAGED_PYTHON = lib.mkDefault "1";

  # uv execs the interpreter it manages, so one wrapper sandboxes
  # `uv sync`, `uv run`, build backends, and everything they spawn.
  # Requires vars.bwrap.enabled (default true); bwrap-run.sh lives in .tack.
  #
  # Pass the store path, not the name: bwrap-run resolves bare names via
  # proto/cargo/PATH and deliberately skips */.devenv* PATH entries, which
  # is exactly where devenv exposes pkgs.uv. A path containing "/" is
  # execed verbatim.
  scripts.uv.exec = ''
    exec env \
      BWRAP_REPO_ROOT=${lib.escapeShellArg projectRoot} \
      ${lib.escapeShellArg bwrapRun} ${lib.escapeShellArg (lib.getExe pkgs.uv)} "$@"
  '';
}
