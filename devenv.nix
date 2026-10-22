{
  pkgs,
  lib,
  config,
  ...
}: let
  # bwrap scripts stay in the .tack submodule and are never materialized
  # into the consumer repo (ADR-0007); the devenv wrappers invoke them by
  # absolute path. Wrappers pass BWRAP_REPO_ROOT so bwrap-run never
  # has to guess the repo root from the working directory.
  projectRoot = toString config.devenv.root;
  bwrapRun = "${projectRoot}/./configs/devenv/bwrap-run.sh";
  bwrapAppArmor = "${projectRoot}/./configs/devenv/bwrap-apparmor.sh";
in {
  # packages lists additional system-level tools available in the dev shell.
  # Add entries here for tools not managed by proto.
  # PHP, Composer, and services are added by the drupal variant module.
  packages = with pkgs; [
    # bwrap-run sandboxing: bwrap comes from this nixpkgs (pinned by
    # devenv.lock), so the AppArmor profile managed by bwrap-apparmor
    # matches the binary the shell actually executes.
    bubblewrap
    apparmor-utils
  ];

  # env sets environment variables available inside devenv shell and processes.
  env = {
  };

  # enterShell runs once when the shell starts.
  enterShell = ''
    echo "devenv ready"

    # Report (never fix) AppArmor state for the bwrap binary. Install with:
    #   bwrap-apparmor install
    command -v bwrap-apparmor >/dev/null 2>&1 && bwrap-apparmor check --quiet || true

  '';

  scripts = {
    # `git push` from inside the shell runs tidy-push (fix, roll-up, merge trunk)
    # before the real push. Everything else passes straight through to the
    # nixpkgs git pinned by devenv.lock. The real git is resolved at Nix
    # evaluation time, never by searching PATH: any other git wrapper on the
    # host that calls `git` by name would otherwise bounce back into this shim
    # and fork until the OOM killer fires. Opt out: vars.devenv.git_shim = false.
    git.exec = ''
      real_git=${lib.escapeShellArg (lib.getExe pkgs.git)}
      # Preserve every explicit git invocation; only bare interactive push is tidied.
      if [[ $# == 1 && $1 == push && -t 0 && -t 1 && -z "''${TIDY_PUSH_ACTIVE:-}" ]]; then
        worktree="$("$real_git" rev-parse --show-toplevel 2>/dev/null)" || exec "$real_git" "$@"
        project_root="''${DEVENV_ROOT:-}"
        # Compare directory identity, not spelling; do not intercept nested repos.
        if [[ -n "$project_root" && "$worktree" -ef "$project_root" && -x "$project_root/.moon/scripts/tidy-push.sh" ]]; then
          cd -- "$worktree" || exit 1
          # Direct exec avoids moon's outer task-runner noise around prompts.
          exec "$worktree/.moon/scripts/tidy-push.sh" push
        fi
      fi
      exec "$real_git" "$@"
    '';

    # bwrap-run: run dependency-executing tools inside a bubblewrap sandbox.
    bwrap-run.exec = ''
      exec env \
        BWRAP_REPO_ROOT=${lib.escapeShellArg projectRoot} \
        ${lib.escapeShellArg bwrapRun} "$@"
    '';
    bwrap-apparmor.exec = ''
      exec ${lib.escapeShellArg bwrapAppArmor} "$@"
    '';

    node.exec = ''
      exec env \
        BWRAP_REPO_ROOT=${lib.escapeShellArg projectRoot} \
        ${lib.escapeShellArg bwrapRun} node "$@"
    '';

    npx.exec = ''
      exec env \
        BWRAP_REPO_ROOT=${lib.escapeShellArg projectRoot} \
        ${lib.escapeShellArg bwrapRun} npx "$@"
    '';

    pnpm.exec = ''
      exec env \
        BWRAP_REPO_ROOT=${lib.escapeShellArg projectRoot} \
        ${lib.escapeShellArg bwrapRun} pnpm "$@"
    '';

    moon.exec = ''
      exec env \
        BWRAP_REPO_ROOT=${lib.escapeShellArg projectRoot} \
        ${lib.escapeShellArg bwrapRun} moon "$@"
    '';

    cargo.exec = ''
      exec env \
        BWRAP_REPO_ROOT=${lib.escapeShellArg projectRoot} \
        ${lib.escapeShellArg bwrapRun} cargo "$@"
    '';

    rustc.exec = ''
      exec env \
        BWRAP_REPO_ROOT=${lib.escapeShellArg projectRoot} \
        ${lib.escapeShellArg bwrapRun} rustc "$@"
    '';
  };
}
