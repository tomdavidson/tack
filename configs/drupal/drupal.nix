# Base devenv module for any Drupal application managed by tack.
# Imported by the consumer's devenv.nix:
#
#   imports = [ ./.tack/configs/drupal/drupal.nix ];
#
# Provides PHP 8.3, FrankenPHP, composer, and the shared Drupal task scripts.
# Does NOT provide a database or S3 service — add a variant for those.
#
# APP_ROOT defaults to DEVENV_ROOT (Drupal at the repo root). Set it in the
# consumer devenv.nix when Drupal lives in a subdirectory (e.g. apps/hub):
#
#   env.APP_ROOT = "${config.devenv.root}/apps/hub";
{ pkgs, lib, config, ... }:

let
  php = pkgs.php83.buildEnv {
    extensions = { all, enabled }: with all; enabled ++ [
      apcu
      bcmath
      gd
      intl
      opcache
      zip
    ];
    extraConfig = ''
      memory_limit = 512M
      max_execution_time = 120
    '';
  };

  appRoot   = config.env.APP_ROOT or config.devenv.root;
  webPort   = config.processes.web.ports.http.value;

  # Path to tack scripts inside the submodule.
  tackScripts = ".tack/configs/drupal/scripts";
in
{
  # ---------------------------------------------------------------------------
  # Environment
  # ---------------------------------------------------------------------------
  env = {
    # APP_ROOT: set to repo root by default; override in the consumer
    # devenv.nix when Drupal lives in a subdirectory.
    APP_ROOT              = lib.mkDefault config.devenv.root;
    APP_ENV               = lib.mkDefault "development";
    HASH_SALT             = lib.mkDefault "local-dev-only-not-for-production";
    CRON_KEY              = lib.mkDefault "local-cron-key";
    DRUPAL_ADMIN_PASSWORD = lib.mkDefault "admin";

    PLATFORM_HOST = lib.mkDefault "${builtins.baseNameOf (toString config.devenv.root)}.localhost";
    PLATFORM_URI  = lib.mkDefault "http://${builtins.baseNameOf (toString config.devenv.root)}.localhost:${toString webPort}";
    TRUSTED_HOSTS = lib.mkDefault "localhost,127.0.0.1,*.localhost";
    WEB_PORT      = lib.mkDefault (toString webPort);

    # FrankenPHP / Caddy port binding via SERVER_NAME.
    SERVER_NAME                   = lib.mkDefault ":${toString webPort}";
    CADDY_GLOBAL_OPTIONS          = lib.mkDefault "";
    CADDY_SERVER_EXTRA_DIRECTIVES = lib.mkDefault "";

    BROWSERTEST_OUTPUT_DIRECTORY = lib.mkDefault "/tmp/browser_output";
    SYMFONY_DEPRECATIONS_HELPER  = lib.mkDefault "disabled";
  };

  # ---------------------------------------------------------------------------
  # Packages
  # ---------------------------------------------------------------------------
  packages = with pkgs; [
    git
    curl
    jq
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
  # Web server — FrankenPHP with APP_ROOT/Caddyfile.
  # ---------------------------------------------------------------------------
  processes.web = {
    ports.http.allocate = lib.mkDefault 8080;
    exec = ''
      echo ${toString webPort} > "$DEVENV_STATE/web.port"
      cd "${appRoot}"
      exec frankenphp run --config Caddyfile
    '';
    ready.http.get = {
      port = webPort;
      path = "/core/misc/druplicon.png";
    };
  };

  # ---------------------------------------------------------------------------
  # Tasks
  # ---------------------------------------------------------------------------
  tasks."app:composer" = {
    description = "composer install (scaffolds web/ and vendor/)";
    status      = "test -f '${appRoot}/vendor/autoload.php'";
    exec        = "cd '${appRoot}' && composer install --no-interaction";
    before      = [ "devenv:processes:web" ];
  };

  tasks."drupal:deploy" = {
    description = "updatedb, config:import, cache:rebuild, cron key, drift gate";
    exec        = "${tackScripts}/drupal/deploy.sh";
    after       = [ "app:composer" ];
  };

  tasks."drupal:reset" = {
    description = "Drop and reinstall from config/sync (forces reinstall)";
    exec        = "${tackScripts}/drupal/install.sh --force";
    after       = [ "app:composer" ];
  };

  # ---------------------------------------------------------------------------
  # Shell
  # ---------------------------------------------------------------------------
  enterTest = ''
    moon ci
  '';

  enterShell = ''
    export PATH="${appRoot}/vendor/bin:$PATH"
    echo "drupal devenv: php $(php -r 'echo PHP_VERSION;') (APP_ENV=$APP_ENV, APP_ROOT=$APP_ROOT)"
    echo "  devenv up                       -> start services"
    echo "  devenv tasks run drupal:deploy  -> apply config changes"
    echo "  devenv tasks run drupal:reset   -> drop and reinstall"
    echo "  devenv test                     -> run moon ci"
  '';
}
