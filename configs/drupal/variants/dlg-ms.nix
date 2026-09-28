# devenv variant for LocalGov DLG-MS (DLG Microsites) projects.
# Imports configs/drupal/drupal.nix and adds MariaDB 11.4, RustFS, and
# the LocalGov-specific tasks and environment.
#
# Consumer devenv.nix:
#
#   imports = [ ./.tack/configs/drupal/variants/dlg-ms.nix ];
#
# Override any value with a plain assignment after the import.
# lib.mkDefault is used throughout so consumer overrides always win.
{ pkgs, lib, config, ... }:

let
  # Single source for dev credentials.
  dbName      = "drupal";
  dbTestName  = "drupal_test";
  dbUser      = "drupal";
  dbPassword  = "drupal";
  s3AccessKey = "devadmin";
  s3SecretKey = "devsecret";

  platformHost  = builtins.baseNameOf (toString config.devenv.root);
  webPort       = config.processes.web.ports.http.value;
  dbPort        = config.services.mysql.settings.mysqld.port;
  s3Port        = config.processes.rustfs.ports.api.value;
  s3ConsolePort = config.processes.rustfs.ports.console.value;

  tackScripts = ".tack/configs/drupal/scripts";

  printUrls = ''
    port=$(cat "$DEVENV_STATE/web.port" 2>/dev/null || echo "${toString webPort}")
    echo ""
    echo "dlg-ms dev URLs"
    echo "  Drupal          http://${platformHost}.localhost:$port"
    echo "  S3 API (RustFS) $S3_ENDPOINT   bucket: $S3_BUCKET"
    echo "  RustFS console  http://127.0.0.1:${toString s3ConsolePort}   ($S3_ACCESS_KEY / $S3_SECRET_KEY)"
    echo "  MariaDB         $DB_HOST:$DB_PORT   db=$DB_NAME user=$DB_USER pass=$DB_PASSWORD"
    echo "  Drupal admin    admin / $DRUPAL_ADMIN_PASSWORD   (or: drush uli)"
    echo ""
  '';
in
{
  imports = [ ../drupal.nix ];

  # ---------------------------------------------------------------------------
  # Additional PHP extensions for DLG-MS (pdo_mysql for MariaDB).
  # ---------------------------------------------------------------------------
  languages.php.package = lib.mkForce (pkgs.php83.buildEnv {
    extensions = { all, enabled }: with all; enabled ++ [
      apcu bcmath gd intl opcache pdo_mysql zip
    ];
    extraConfig = ''
      memory_limit = 512M
      max_execution_time = 120
    '';
  });

  # ---------------------------------------------------------------------------
  # Additional packages
  # ---------------------------------------------------------------------------
  packages = with pkgs; [ mariadb_114.client ];

  # ---------------------------------------------------------------------------
  # Environment — DB, S3, PHPUnit
  # ---------------------------------------------------------------------------
  env = {
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
    AWS_REQUEST_CHECKSUM_CALCULATION = lib.mkDefault "when_required";
    AWS_RESPONSE_CHECKSUM_VALIDATION = lib.mkDefault "when_required";

    SIMPLETEST_BASE_URL = lib.mkDefault "http://127.0.0.1:${toString webPort}";
    SIMPLETEST_DB       = lib.mkDefault "mysql://${dbUser}:${dbPassword}@127.0.0.1:${toString dbPort}/${dbTestName}";
  };

  # ---------------------------------------------------------------------------
  # MariaDB 11.4
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
  # RustFS
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
  # Tasks
  # ---------------------------------------------------------------------------
  tasks."db:user" = {
    description = "Create ${dbName}+${dbTestName} databases and ${dbUser} user (idempotent)";
    exec        = ''
      mysql -u root -h 127.0.0.1 -P ${toString dbPort} -e "
        CREATE DATABASE IF NOT EXISTS \`${dbName}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE DATABASE IF NOT EXISTS \`${dbTestName}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE USER IF NOT EXISTS '${dbUser}'@'localhost' IDENTIFIED BY '${dbPassword}';
        CREATE USER IF NOT EXISTS '${dbUser}'@'127.0.0.1' IDENTIFIED BY '${dbPassword}';
        GRANT ALL ON \`${dbName}\`.* TO '${dbUser}'@'localhost';
        GRANT ALL ON \`${dbName}\`.* TO '${dbUser}'@'127.0.0.1';
        GRANT ALL ON \`${dbTestName}\`.* TO '${dbUser}'@'localhost';
        GRANT ALL ON \`${dbTestName}\`.* TO '${dbUser}'@'127.0.0.1';
        FLUSH PRIVILEGES;
      "
    '';
    after  = [ "devenv:processes:mysql@ready" ];
    before = [ "devenv:processes:web" ];
  };

  tasks."s3:buckets" = {
    description = "Create files and backup buckets on RustFS (idempotent)";
    exec        = "${tackScripts}/s3/bootstrap-buckets.sh";
    after       = [ "devenv:processes:rustfs@ready" ];
    before      = [ "devenv:processes:web" ];
  };

  tasks."drupal:setup" = {
    description = "Install from config/sync + LocalGov post-install hook (with demo content)";
    exec        = "LOCALGOV_DEMO=1 ${tackScripts}/drupal/install.sh";
    after       = [ "app:composer" "db:user" "s3:buckets" ];
  };

  # Override drupal:deploy and drupal:reset to also wait for db:user.
  tasks."drupal:deploy".after = lib.mkForce [ "app:composer" "db:user" ];
  tasks."drupal:reset".after  = lib.mkForce [ "app:composer" "db:user" "s3:buckets" ];

  # ---------------------------------------------------------------------------
  # URLs process + script
  # ---------------------------------------------------------------------------
  processes.urls.exec = ''
    while ! curl -s "http://127.0.0.1:${toString webPort}/core/misc/druplicon.png" >/dev/null 2>&1; do
      sleep 0.5
    done
    ${printUrls}
  '';

  scripts.urls.exec = printUrls;

  # Override enterShell to add dlg-ms hints.
  enterShell = lib.mkAfter ''
    echo "dlg-ms variant:  devenv tasks run drupal:setup  -> first-time install (+ demo)"
    echo "                 urls                           -> show service URLs"
  '';
}
