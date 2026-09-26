{ pkgs, lib, config, ... }:

{
  # packages lists additional system-level tools available in the dev shell.
  # Add entries here for tools not managed by proto.
  # PHP, Composer, and services are added when configs/php is consumed.
  packages = with pkgs; [
{% for pkg in vars.devenv.packages | default(value=[]) %}
    {{ pkg }}
{% endfor %}
  ];

  # env sets environment variables available inside devenv shell and processes.
  env = {
{% for key, value in vars.devenv.env | default(value={}) %}
    {{ key }} = "{{ value }}";
{% endfor %}
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
  '';
}
