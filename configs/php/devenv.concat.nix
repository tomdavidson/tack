  # ---------------------------------------------------------------------------
  # PHP + Composer (appended by configs/php via tack concat)
  # Override vars.php.version and vars.php.packages in your tackrc.yml.
  # ---------------------------------------------------------------------------
  languages.php = {
    enable = true;
    version = "{{ vars.php.version | default(value='8.3') }}";
    # Composer is enabled automatically when languages.php.enable = true
    # in devenv. No separate languages.php.composer.enable needed.
  };

{% if vars.php.packages is defined and vars.php.packages | length > 0 %}
  # Extra nixpkgs packages for PHP tooling (e.g. php83Packages.composer2).
  # Extend via vars.php.packages in tackrc.yml.
  packages = (config.packages or []) ++ (with pkgs; [
{% for pkg in vars.php.packages %}
    {{ pkg }}
{% endfor %}
  ]);
{% endif %}
{% if vars.bwrap.enabled | default(value=true) %}
  scripts.composer.exec = ''
    exec env \
      BWRAP_REPO_ROOT=${lib.escapeShellArg projectRoot} \
      ${lib.escapeShellArg bwrapRun} composer "$@"
  '';
{% endif %}
