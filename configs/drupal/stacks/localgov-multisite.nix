# Opinionated devenv module for LocalGov Drupal multisite projects.
# Imported by the consumer's devenv.nix via the tack stack-import pattern:
#
#   imports = [ ./.tack/configs/drupal/stacks/localgov-multisite.nix ];
#
# Override any value with a plain assignment (or lib.mkForce) after the import
# in the consumer's devenv.nix. lib.mkDefault is used throughout so consumer
# overrides always win without needing mkForce.
{ pkgs, lib, config, ... }:

let
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

  # Single source for dev credentials — referenced by both services and env.
  # Override in the consumer devenv.nix after the import.
  dbName      = "drupal";
  dbUser      = "drupal";
  dbPassword  = "drupal";
  s3AccessKey = "devadmin";
  s3SecretKey = "devsecret";

  # Defaults to <project-dirname>.localhost so each checkout gets a unique
  # hostname automatically. Override in the consumer devenv.nix if needed:
  #   env.PLATFORM_HOST = lib.mkForce "myproject.localhost";
  platformHost = builtins.baseNameOf (toString config.devenv.root);

  # Allocated ports — resolved after devenv assigns them.
  webPort       = config.processes.web.ports.http.value;
  dbPort        = config.services.mysql.settings.mysqld.port;
  s3Port        = config.processes.rustfs.ports.api.value;
  s3ConsolePort = config.processes.rustfs.ports.console.value;

  # Path to the tack scripts directory inside the submodule.
  tackScripts = ".tack/configs/drupal/scripts";

  printUrls = ''
    port=$(cat "$DEVENV_STATE/web.port" 2>/dev/null || echo "${toString webPort}")
    echo ""
    echo "localgov-multisite dev URLs"
    echo "  Drupal            http://${platformHost}.localhost:$port"
    echo "  S3 API (RustFS)   $S3_ENDPOINT   bucket: $S3_BUCKET"
    echo "  RustFS console    http://127.0.0.1:${toString s3ConsolePort}   ($S3_ACCESS_KEY / $S3_SECRET_KEY)"
    echo "  MariaDB           $DB_HOST:$DB_PORT   db=$DB_NAME user=$DB_USER pass=$DB_PASSWORD"
    echo "  Drupal admin      admin / $DRUPAL_ADMIN_PASSWORD   (or: drush uli)"
    echo ""
  '';
in
{
  # ---------------------------------------------------------------------------
  # Environment contract — must match settings.php and scripts/lib/env.sh.
  # Override project-specific values (HASH_SALT etc.) in the consumer's
  # devenv.nix after the import.
  # ---------------------------------------------------------------------------
  env = {
    APP_ENV               = lib.mkDefault "development";
    HASH_SALT             = lib.mkDefault "local-dev-only-not-for-production";
    CRON_KEY              = lib.mkDefault "local-cron-key";
    DRUPAL_ADMIN_PASSWORD = lib.mkDefault "admin";

    PLATFORM_HOST = lib.mkDefault "${platformHost}.localhost";
    PLATFORM_URI  = lib.mkDefault "http://${platformHost}.localhost:${toString webPort}";
    TRUSTED_HOSTS = lib.mkDefault "localhost,127.0.0.1,*.localhost,*.ddev.site";
    WEB_PORT      = lib.mkDefault (toString webPort);

    DB_HOST     = lib.mkDefault "127.0.0.1";
    DB_PORT     = lib.mkDefault (toString dbPort);
    DB_NAME     = lib.mkDefault dbName;
    DB_USER     = lib.mkDefault dbUser;
    DB_PASSWORD = lib.mkDefault dbPassword;

    S3_ENDPOINT   = lib.mkDefault "http://127.0.0.1:${toString s3Port}";
    S3_ACCESS_KEY = lib.mkDefault s3AccessKey;
    S3_SECRET_KEY = lib.mkDefault s3SecretKey;
    S3_REGION     = lib.mkDefault "auto";
    S3_BUCKET     = lib.mkDefault "drupal-files";
    S3_PATH_STYLE = lib.mkDefault "1";
    BACKUP_BUCKET = lib.mkDefault "drupal-backups";
    # Required by the AWS SDK for PHP (s3fs); cannot be renamed.
    AWS_REQUEST_CHECKSUM_CALCULATION = lib.mkDefault "when_required";
    AWS_RESPONSE_CHECKSUM_VALIDATION = lib.mkDefault "when_required";

    # PHPUnit
    SIMPLETEST_BASE_URL          = lib.mkDefault "http://127.0.0.1:${toString webPort}";
    SIMPLETEST_DB                = lib.mkDefault "mysql://${dbUser}:${dbPassword}@127.0.0.1:${toString dbPort}/${dbName}";
    BROWSERTEST_OUTPUT_DIRECTORY = lib.mkDefault "/tmp/browser_output";
    SYMFONY_DEPRECATIONS_HELPER  = lib.mkDefault "disabled";

    # FrankenPHP / Caddy: listen on the devenv-allocated port; no TLS locally.
    # SERVER_NAME drives the `{$SERVER_NAME::8080}` block in the Caddyfile.
    SERVER_NAME = lib.mkDefault ":${toString webPort}";
    # Empty defaults so Caddyfile interpolation never hits an unset variable.
    # Set these in the consumer devenv.nix to inject extra Caddy config.
    CADDY_GLOBAL_OPTIONS          = lib.mkDefault "";
    CADDY_SERVER_EXTRA_DIRECTIVES = lib.mkDefault "";
  };

  # ---------------------------------------------------------------------------
  # Packages
  # ---------------------------------------------------------------------------
  packages = with pkgs; [
    git
    curl
    jq
    mariadb_114.client
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
  # devenv's service is always services.mysql regardless of the package used.
  # No initialDatabases/ensureUsers: devenv skips those during `devenv up`
  # (cachix/devenv#2852). The db:user task creates the database and user.
  # ---------------------------------------------------------------------------
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

  # ---------------------------------------------------------------------------
  # RustFS — local S3-compatible object store for s3fs.
  # ---------------------------------------------------------------------------
  services.rustfs = {
    enable      = true;
    package     = pkgs.rustfs;
    port        = lib.mkDefault 9000;
    consolePort = lib.mkDefault 9001;
    accessKey   = s3AccessKey;
    secretKey   = s3SecretKey;
  };

  # ---------------------------------------------------------------------------
  # Web server — FrankenPHP with the project Caddyfile.
  # SERVER_NAME drives the Caddyfile `{$SERVER_NAME::8080}` block so it
  # listens on the devenv-allocated port. The port is also written to
  # $DEVENV_STATE/web.port so other shells and `urls` can find it.
  # ---------------------------------------------------------------------------
  processes.web = {
    ports.http.allocate = lib.mkDefault 8080;
    exec = ''
      echo ${toString webPort} > "$DEVENV_STATE/web.port"
      cd "$DEVENV_ROOT"
      exec frankenphp run --config Caddyfile
    '';
    ready.http.get = {
      port = webPort;
      path = "/core/misc/druplicon.png";
    };
  };

  # Prints the URL table in the devenv up TUI once the web server is ready.
  processes.urls.exec = ''
    while ! curl -s "http://127.0.0.1:${toString webPort}/core/misc/druplicon.png" >/dev/null 2>&1; do
      sleep 0.5
    done
    ${printUrls}
  '';

  # `urls` shell command — print service URLs and credentials at any time.
  scripts.urls.exec = printUrls;

  # ---------------------------------------------------------------------------
  # Tasks
  # All scripts live in .tack/configs/drupal/scripts/ (via the submodule).
  # post-install.sh for LocalGov-specific setup (role grant, demo module) lives
  # in .tack/configs/drupal/stacks/localgov-multisite/ and must be symlinked or
  # copied to scripts/drupal/post-install.sh in the consumer project.
  # ---------------------------------------------------------------------------
  tasks."app:composer" = {
    description = "composer install (scaffolds web/ and vendor/)";
    status      = "test -f vendor/autoload.php";
    exec        = "${tackScripts}/drupal/../../../scripts/drupal/install.sh";
    before      = [ "devenv:processes:web" ];
  };

  tasks."app:composer" = {
    description = "composer install";
    status      = "test -f vendor/autoload.php";
    exec        = "composer install --no-interaction";
    before      = [ "devenv:processes:web" ];
  };

  tasks."db:user" = {
    description = "Create the ${dbName} database and ${dbUser} user (idempotent)";
    exec        = "${tackScripts}/db/ensure-user.sh";
    after       = [ "devenv:processes:mysql@ready" ];
    before      = [ "devenv:processes:web" ];
  };

  tasks."s3:buckets" = {
    description = "Create the files and backup buckets on RustFS (idempotent)";
    exec        = "${tackScripts}/s3/bootstrap-buckets.sh";
    after       = [ "devenv:processes:rustfs@ready" ];
    before      = [ "devenv:processes:web" ];
  };

  tasks."drupal:setup" = {
    description = "Install from config/sync + post-install hook (with demo module)";
    exec        = "LOCALGOV_DEMO=1 ${tackScripts}/drupal/install.sh";
    after       = [ "app:composer" "db:user" "s3:buckets" ];
  };

  tasks."drupal:deploy" = {
    description = "updatedb, config:import, cache:rebuild, cron key, drift gate";
    exec        = "${tackScripts}/drupal/deploy.sh";
    after       = [ "app:composer" "db:user" ];
  };

  tasks."drupal:reset" = {
    description = "Drop and reinstall from config/sync + post-install hook (with demo module)";
    exec        = "LOCALGOV_DEMO=1 ${tackScripts}/drupal/install.sh --force";
    after       = [ "app:composer" "db:user" "s3:buckets" ];
  };

  # ---------------------------------------------------------------------------
  # Test + Shell
  # ---------------------------------------------------------------------------
  enterTest = ''
    scripts/test/ci.sh
  '';

  enterShell = ''
    export PATH="$DEVENV_ROOT/vendor/bin:$PATH"
    echo "localgov-multisite devenv: php $(php -r 'echo PHP_VERSION;') (APP_ENV=$APP_ENV)"
    echo "  devenv up                       -> start services (prints URLs)"
    echo "  devenv tasks run drupal:setup   -> first-time install (+ demo)"
    echo "  devenv tasks run drupal:deploy  -> apply config changes"
    echo "  devenv test                     -> run the CI suite locally"
    echo "  urls                            -> show service URLs"
  '';
}
