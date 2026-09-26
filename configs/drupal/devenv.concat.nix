  # ---------------------------------------------------------------------------
  # Drupal PHP extensions + database service (appended by configs/drupal via tack concat)
  # Override vars.drupal.extensions and vars.drupal.database in your tackrc.yml.
  # ---------------------------------------------------------------------------
  languages.php.extensions = [
{% set default_extensions = ["apcu", "bcmath", "gd", "intl", "opcache", "pdo_mysql", "zip"] %}
{% for ext in vars.drupal.extensions | default(value=default_extensions) %}
    "{{ ext }}"
{% endfor %}
  ];

{% set db = vars.drupal.database | default(value="mysql") %}
  services.{{ db }} = {
    enable = true;
{% if vars.drupal.database_settings is defined %}
{% for k, v in vars.drupal.database_settings %}
    settings.{{ k }} = {{ v }};
{% endfor %}
{% endif %}
  };
