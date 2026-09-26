{ pkgs, lib, config, ... }:

{% if vars.bwrap.enabled | default(value=true) %}
let
  # bwrap scripts stay in the .tack submodule and are never materialized
  # into the consumer repo (ADR-0007); the devenv wrappers invoke them by
  # absolute path. Wrappers pass BWRAP_REPO_ROOT so bwrap-run never
  # has to guess the repo root from the working directory.
  projectRoot = toString config.devenv.root;
  bwrapRun = "${projectRoot}/.tack/configs/devenv/bwrap-run.sh";
  bwrapAppArmor = "${projectRoot}/.tack/configs/devenv/bwrap-apparmor.sh";
in {
{% else %}
{
{% endif %}
  # packages lists additional system-level tools available in the dev shell.
  # Add entries here for tools not managed by proto.
  # PHP, Composer, and services are added when configs/php is consumed.
  packages = with pkgs; [
{% for pkg in vars.devenv.packages | default(value=[]) %}
    {{ pkg }}
{% endfor %}
{% if vars.bwrap.enabled | default(value=true) %}
    # bwrap-run sandboxing: bwrap comes from this nixpkgs (pinned by
    # devenv.lock), so the AppArmor profile managed by bwrap-apparmor
    # matches the binary the shell actually executes.
    bubblewrap
    apparmor-utils
{% endif %}
  ];

  # env sets environment variables available inside devenv shell and processes.
  env = {
{% if vars.devenv.env is defined %}
{% for key, value in vars.devenv.env %}
    {{ key }} = "{{ value }}";
{% endfor %}
{% endif %}
  };

{% if vars.devenv.languages is defined %}
  languages = {
{% for lang, cfg in vars.devenv.languages %}
    {{ lang }} = {
      enable = {{ cfg.enable | default(value=false) }};
{% if cfg.version is defined %}
      version = "{{ cfg.version }}";
{% endif %}
    };
{% endfor %}
  };
{% endif %}

{% if vars.devenv.services is defined %}
  services = {
{% for svc, cfg in vars.devenv.services %}
    {{ svc }} = {
      enable = {{ cfg.enable | default(value=false) }};
{% if cfg.settings is defined %}
{% for k, v in cfg.settings %}
      settings.{{ k }} = {{ v }};
{% endfor %}
{% endif %}
    };
{% endfor %}
  };
{% endif %}

  # enterShell runs once when the shell starts.
  enterShell = ''
    echo "devenv ready"
{% if vars.bwrap.enabled | default(value=true) %}
    # Report (never fix) AppArmor state for the bwrap binary. Install with:
    #   bwrap-apparmor install
    command -v bwrap-apparmor >/dev/null 2>&1 && bwrap-apparmor check --quiet || true
{% endif %}
  '';

{% if vars.bwrap.enabled | default(value=true) %}
  # bwrap-run: run dependency-executing tools inside a bubblewrap sandbox.
  # The scripts live in the .tack submodule; these wrappers invoke them by
  # absolute path with the repo root passed explicitly.
  #
  # `bwrap-run <tool>` resolves the real binary on the host (proto bin,
  # proto shims, ~/.cargo/bin) before the sandbox starts, so proto-managed
  # toolchains work. See docs/bwrap.md for the mount and cache layout.
  # moon is wrapped at the moon level: everything a moon task spawns runs
  # in ONE sandbox. See docs/bwrap-moon-sandbox-scope.md (rename pending)
  # and issue #13.
  scripts = {
    bwrap-run.exec = ''
      exec env \
        BWRAP_REPO_ROOT=${lib.escapeShellArg projectRoot} \
        ${lib.escapeShellArg bwrapRun} "$@"
    '';
    bwrap-apparmor.exec = ''
      exec ${lib.escapeShellArg bwrapAppArmor} "$@"
    '';
{% for tool in vars.bwrap.tools %}
    {{ tool }}.exec = ''
      exec env \
        BWRAP_REPO_ROOT=${lib.escapeShellArg projectRoot} \
        ${lib.escapeShellArg bwrapRun} {{ tool }} "$@"
    '';
{% endfor %}
  };
{% endif %}
}
