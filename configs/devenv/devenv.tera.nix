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

  # enterShell runs once when the shell starts.
  enterShell = ''
    echo "devenv ready"
  '';
}
