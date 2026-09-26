{ pkgs, lib, config, inputs, ... }:

{
  # packages lists additional system-level tools available in the dev shell.
  # Add entries here for tools not managed by proto.
  # PHP, Composer, and services are added when configs/php is consumed.
  packages = with pkgs; [
{% for pkg in vars.devenv.packages | default(value=[]) %}
    {{ pkg }}
{% endfor %}
{% if vars.sbx.enabled | default(value=true) %}
  ] ++ [
    # sbx sandbox tooling, built from the tack flake input. sbx and
    # sbx-apparmor share one bubblewrap so the AppArmor profile matches
    # the exact bwrap store path sbx execs.
    inputs.tack.packages.${pkgs.system}.sbx
    inputs.tack.packages.${pkgs.system}.sbx-apparmor
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
{% if vars.sbx.enabled | default(value=true) %}
    # Report (never fix) AppArmor state for the bwrap binary. Install with:
    #   sbx-apparmor install
    command -v sbx-apparmor >/dev/null 2>&1 && sbx-apparmor check --quiet || true
{% endif %}
  '';

{% if vars.sbx.enabled | default(value=true) %}
  # sbx: run dependency-executing tools inside a bubblewrap sandbox.
  # `sbx <tool>` resolves the real binary on the host (proto bin, proto
  # shims, ~/.cargo/bin) before the sandbox starts, so proto-managed
  # toolchains work. See docs/sbx.md for the mount and cache layout.
  # moon is wrapped at the moon level: everything a moon task spawns runs
  # in ONE sandbox. See docs/sbx-moon-sandbox-scope.md and issue #13.
  scripts = {
{% for tool in vars.sbx.tools %}
    {{ tool }}.exec = ''exec sbx {{ tool }} "$@"'';
{% endfor %}
  };
{% endif %}
}
