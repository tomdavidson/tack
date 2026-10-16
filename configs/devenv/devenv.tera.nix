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

{% set extra_imports = vars.devenv.imports | default(value=[]) %}
{% if vars.drupal.variant is defined or extra_imports | length > 0 %}
  # devenv modules imported directly from the .tack submodule.
  # vars.drupal.variant selects a Drupal variant (configs/drupal/variants/).
  # vars.devenv.imports lists further modules, e.g. ./.tack/configs/python/python.nix.
  # Override any module default after this import block.
  imports = [
{% if vars.drupal.variant is defined %}
    ./.tack/configs/drupal/variants/{{ vars.drupal.variant }}.nix
{% endif %}
{% for m in extra_imports %}
    {{ m }}
{% endfor %}
  ];

{% endif %}
  # packages lists additional system-level tools available in the dev shell.
  # Add entries here for tools not managed by proto.
  # PHP, Composer, and services are added by the drupal variant module.
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
{% if vars.bwrap.enabled | default(value=true) %}
{% if vars.bwrap.dev_root_depth is defined %}
    # bwrap-run reads BWRAP_DEV_ROOT on the host: one writable bind for every
    # repo under it plus <dev_root>/.bwrap caches (pnpm hardlinks, uv pythons).
    # Computed from the repo location so the committed file has no home path;
    # vars.bwrap.dev_root_depth = {{ vars.bwrap.dev_root_depth }} directories up.
    BWRAP_DEV_ROOT = {% for _ in range(end=vars.bwrap.dev_root_depth) %}builtins.dirOf ({% endfor %}config.devenv.root{% for _ in range(end=vars.bwrap.dev_root_depth) %}){% endfor %};
{% elif vars.bwrap.dev_root is defined %}
    # Absolute dev root from vars.bwrap.dev_root; machine-specific, prefer
    # vars.bwrap.dev_root_depth for anything committed.
    BWRAP_DEV_ROOT = "{{ vars.bwrap.dev_root }}";
{% endif %}
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
