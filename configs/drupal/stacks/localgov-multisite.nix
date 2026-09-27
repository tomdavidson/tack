# Opinionated devenv module for LocalGov Drupal multisite projects.
# Imported by the consumer's devenv.nix via the tack stack-import pattern:
#
#   imports = [ ./.tack/configs/drupal/stacks/localgov-multisite.nix ];
#
# Override any attribute with a plain assignment (or lib.mkForce) after the
# import in the consumer's devenv.nix.
{ pkgs, lib, config, ... }:

let
  php = pkgs.php83.buildEnv {
    extensions = { all, enabled }: with all; enabled ++ [
      apcu bcmath gd intl opcache pdo_mysql zip
    ];
    extraConfig = ''
      memory_limit = 512M
      max_execution_time = 120
    '';
  };
in
{
  env = {
    COMPOSER_MEMORY_LIMIT        = lib.mkDefault "-1";
    SIMPLETEST_DB                = lib.mkDefault "mysql://drupal:drupal@127.0.0.1:3306/drupal";
    SIMPLETEST_BASE_URL          = lib.mkDefault "http://127.0.0.1:8080";
    BROWSERTEST_OUTPUT_DIRECTORY = lib.mkDefault "/tmp/browser_output";
    SYMFONY_DEPRECATIONS_HELPER  = lib.mkDefault "disabled";
    DB_HOST                      = lib.mkDefault "127.0.0.1";
    DB_PORT                      = lib.mkDefault "3306";
    DB_NAME                      = lib.mkDefault "drupal";
    DB_USER                      = lib.mkDefault "drupal";
    DB_PASSWORD                  = lib.mkDefault "drupal";
  };

  packages = with pkgs; [ git curl jq mariadb_114.client frankenphp ];

  languages.php = { enable = true; package = php; };

  services.mysql = {
    enable  = true;
    package = pkgs.mariadb_114;
    settings.mysqld = {
      port                    = lib.mkDefault 3306;
      bind-address            = "127.0.0.1";
      max_allowed_packet      = lib.mkDefault "64M";
      innodb_buffer_pool_size = lib.mkDefault "256M";
    };
  };

  processes.web = {
    ports.http.allocate = lib.mkDefault 8080;
    exec = ''
      cd "$DEVENV_ROOT"
      exec frankenphp run --config Caddyfile
    '';
    ready.http.get = {
      port = config.processes.web.ports.http.value;
      path = "/core/misc/druplicon.png";
    };
  };

  tasks."app:composer" = {
    description = "composer install";
    status      = "test -f vendor/autoload.php";
    exec        = "composer install --no-interaction";
    before      = [ "devenv:processes:web" ];
  };

  tasks."db:user" = {
    description = "Create drupal db + user (idempotent)";
    exec        = "scripts/db/ensure-user.sh";
    after       = [ "devenv:processes:mysql@ready" ];
    before      = [ "devenv:processes:web" ];
  };

  tasks."drupal:setup"  = { description = "Install from config/sync";          exec = "scripts/drupal/install.sh";         after = [ "app:composer" "db:user" ]; };
  tasks."drupal:deploy" = { description = "updatedb + config:import + cr";      exec = "scripts/drupal/deploy.sh";          after = [ "app:composer" "db:user" ]; };
  tasks."drupal:reset"  = { description = "Drop and reinstall from config/sync"; exec = "scripts/drupal/install.sh --force"; after = [ "app:composer" "db:user" ]; };

  enterShell = ''
    export PATH="$DEVENV_ROOT/vendor/bin:$PATH"
    echo "localgov-multisite devenv: php $(php -r 'echo PHP_VERSION;')"
    echo "  devenv up                      -> start services"
    echo "  devenv tasks run drupal:setup  -> first-time install"
    echo "  devenv tasks run drupal:deploy -> apply config changes"
    echo "  devenv test                    -> run the CI suite locally"
  '';
}
