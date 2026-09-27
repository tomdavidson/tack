# Opinionated devenv module for LocalGov Drupal multisite projects.
# Imported by the consumer's devenv.nix via the tack stack-import pattern:
#
#   imports = [ ./.tack/configs/localgov-multisite/devenv.nix ];
#
# Override any value with lib.mkForce or plain assignment in the consumer's
# devenv.nix after the import.
{ pkgs, lib, config, ... }:

let
  # PHP 8.3 built with the Drupal extension set and sane INI defaults.
  # Override by setting languages.php.package in the consumer devenv.nix.
  php = pkgs.php83.buildEnv {
    extensions = { all, enabled }: with all; enabled ++ [
      apcu
      bcmath
      gd
      intl
      opcache
      pdo_mysql
      zip
    ];
    extraConfig = ''
      memory_limit = 512M
      max_execution_time = 120
    '';
  };

  dbName     = lib.mkDefault "drupal";
  dbUser     = lib.mkDefault "drupal";
  dbPassword = lib.mkDefault "drupal";
in
{
  # ---------------------------------------------------------------------------
  # Environment
  # ---------------------------------------------------------------------------
  env = {
    COMPOSER_MEMORY_LIMIT    = lib.mkDefault "-1";
    SIMPLETEST_DB            = lib.mkDefault "mysql://drupal:drupal@127.0.0.1:3306/drupal";
    SIMPLETEST_BASE_URL      = lib.mkDefault "http://127.0.0.1:8080";
    BROWSERTEST_OUTPUT_DIRECTORY = lib.mkDefault "/tmp/browser_output";
    SYMFONY_DEPRECATIONS_HELPER  = lib.mkDefault "disabled";
    DB_HOST     = lib.mkDefault "127.0.0.1";
    DB_PORT     = lib.mkDefault "3306";
    DB_NAME     = lib.mkDefault "drupal";
    DB_USER     = lib.mkDefault "drupal";
    DB_PASSWORD = lib.mkDefault "drupal";
  };

  # ---------------------------------------------------------------------------
  # Packages
  # ---------------------------------------------------------------------------
  packages = with pkgs; [
    git
    curl
    jq
    mariadb_114.client
    # FrankenPHP for local serving; consumers can swap for php -S by
    # overriding processes.web.exec.
    frankenphp
  ];

  # ---------------------------------------------------------------------------
  # PHP
  # ---------------------------------------------------------------------------
  languages.php = {
    enable  = true;
    package = php;
  };

  # ---------------------------------------------------------------------------
  # MariaDB
  # ---------------------------------------------------------------------------
  services.mysql = {
    enable  = true;
    package = pkgs.mariadb_114;
    settings.mysqld = {
      port             = lib.mkDefault 3306;
      bind-address     = "127.0.0.1";
      max_allowed_packet      = lib.mkDefault "64M";
      innodb_buffer_pool_size = lib.mkDefault "256M";
    };
  };

  # ---------------------------------------------------------------------------
  # FrankenPHP web server process
  # ---------------------------------------------------------------------------
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

  # ---------------------------------------------------------------------------
  # Tasks
  # ---------------------------------------------------------------------------
  tasks."app:composer" = {
    description = "composer install (scaffolds web/ and vendor/)";
    status      = "test -f vendor/autoload.php";
    exec        = "composer install --no-interaction";
    before      = [ "devenv:processes:web" ];
  };

  tasks."db:user" = {
    description = "Create the drupal database and user (idempotent)";
    exec        = "scripts/db/ensure-user.sh";
    after       = [ "devenv:processes:mysql@ready" ];
    before      = [ "devenv:processes:web" ];
  };

  tasks."drupal:setup" = {
    description = "Install from config/sync + optional demo module";
    exec        = "scripts/drupal/install.sh";
    after       = [ "app:composer" "db:user" ];
  };

  tasks."drupal:deploy" = {
    description = "updatedb, config:import, cache:rebuild, drift gate";
    exec        = "scripts/drupal/deploy.sh";
    after       = [ "app:composer" "db:user" ];
  };

  tasks."drupal:reset" = {
    description = "Drop and reinstall from config/sync";
    exec        = "scripts/drupal/install.sh --force";
    after       = [ "app:composer" "db:user" ];
  };

  # ---------------------------------------------------------------------------
  # Shell
  # ---------------------------------------------------------------------------
  enterShell = ''
    export PATH="$DEVENV_ROOT/vendor/bin:$PATH"
    echo "localgov-multisite devenv: php $(php -r 'echo PHP_VERSION;')"
    echo "  devenv up                      -> start services"
    echo "  devenv tasks run drupal:setup  -> first-time install"
    echo "  devenv tasks run drupal:deploy -> apply config changes"
    echo "  devenv test                    -> run the CI suite locally"
  '';
}
