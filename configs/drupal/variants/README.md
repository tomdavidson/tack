# configs/drupal/variants

Devenv variant modules and extra scaffolding for Drupal projects. Each variant
is a Nix module imported by the consumer's `devenv.nix` from `.tack`.

## Available variants

| Variant              | Nix module                                       | Package                                      | Description                                                              |
| -------------------- | ------------------------------------------------ | -------------------------------------------- | ------------------------------------------------------------------------ |
| `dlg-ms`             | `configs/drupal/variants/dlg-ms.nix`             | `configs/drupal/variants/dlg-ms`             | FrankenPHP + MariaDB 11.4 + RustFS (S3) + LocalGov DLG Microsites        |
| `localgov-multisite` | `configs/drupal/variants/localgov-multisite.nix` | `configs/drupal/variants/localgov-multisite` | Compatibility shim importing `dlg-ms.nix`; migrate consumers to `dlg-ms` |

## Variant selection (`dlg-ms`)

A variant uses two entries — `pkgs` in `tackrc.yml` delivers the variant's
templates, Caddyfile, and post-install hook, and `imports` in `devenv.nix`
loads the Nix module:

```yaml
# tackrc.yml
pkgs:
  - configs/common
  - configs/devenv
  - configs/drupal
  - configs/drupal/variants/dlg-ms
vars:
  project:
    name: your-org/your-project
```

```nix
# devenv.nix
{ pkgs, lib, config, ... }:
{
  imports = [ ./.tack/configs/drupal/variants/dlg-ms.nix ];

  env.APP_ROOT  = "${config.devenv.root}/apps/hub";
  env.HASH_SALT = "your-project-specific-value";
}
```

After running `.tack/tack.sh`, scaffold the Drupal app with Moon:

```bash
moon generate dlg-ms -- --name hub
```

## Post-install hook

The `dlg-ms` variant package delivers `post-install.sh` (with `overwrite: false`)
to `scripts/drupal/post-install.sh` in the consumer repo.

`.tack/configs/drupal/scripts/drupal/install.sh` calls
`scripts/drupal/post-install.sh` if it exists after Drupal installation
completes. For LocalGov this enables the demo module and grants the
`microsites_controller` role.

---

## Moon task integration (ADR-0010)

`configs/drupal` delivers `.moon/tasks/drupal/all.yml` and
`.moon/tasks/drupal/app.yml` (tack-owned). Tag your projects to opt in:

```yaml
# apps/hub/moon.yml (Drupal application)
layer: application
tags: ["drupal", "drupal-app"]

# packages/drupal/my_module/moon.yml (custom module)
layer: library
tags: ["drupal"]
```

### Task tiers

```text
lint              phpcs                         No services. Cached by moon.
lint-fix          phpcbf                        No services. Local only.
typecheck         phpstan analyse               No services. Cached by moon.
test-unit         phpunit --testsuite=unit      No services. Cached by moon.
test-integration  #drupal-app:test-prepare + phpunit --testsuite=kernel
test-e2e          #drupal-app:test-prepare + phpunit --testsuite=functional
test              all test tiers (or devenv test on the app)
verify            lint + typecheck + test-unit  Fast local/pre-push gate.
```

### Service readiness

`test-integration` and `test-e2e` depend on `#drupal-app:test-prepare`, which
runs `devenv tasks run drupal:setup` (on first run) or
`devenv tasks run drupal:deploy`. This triggers devenv's task DAG:

```text
drupal:deploy
  after: app:composer     # composer install if needed
  after: db:user          # waits for mysql@ready, creates db + user
  after: s3:buckets       # waits for rustfs@ready, creates buckets
  runs: deploy.sh         # drush updb, cim, cr, drift gate
```

### CI defaults

| Task               | Services     | Cached | Runs in CI (`moon ci`) |
| ------------------ | ------------ | ------ | ---------------------- |
| `lint`             | ✗            | ✓      | ✓                      |
| `lint-fix`         | ✗            | ✗      | ✗                      |
| `typecheck`        | ✗            | ✓      | ✓                      |
| `test-unit`        | ✗            | ✓      | ✓                      |
| `test-integration` | ✓ via devenv | ✗      | ✗                      |
| `test-e2e`         | ✓ via devenv | ✗      | ✗                      |
| `test`             | ✓ via devenv | ✗      | ✗                      |
| `verify`           | ✗            | ✗      | ✗ (local fast gate)    |
| `deploy`           | must be up   | ✗      | ✗                      |
| `reset`            | must be up   | ✗      | ✗                      |

### Per-module PHPUnit scoping

Generated modules (`moon generate drupal-module`) scope PHPUnit to their own
directory via `PHPUNIT_TARGET` with `mergeEnv: append`:

```yaml
# packages/drupal/my_module/moon.yml
id: "my_module"
layer: library
tags: ["drupal"]

tasks:
  test-unit:
    env:
      PHPUNIT_TARGET: "tests/src/Unit"
    options:
      mergeEnv: append
```

### LocalGov Microsites: MariaDB required for kernel tests

Use MariaDB (`drupal_test`) for `SIMPLETEST_DB` when running kernel tests
against a LocalGov Microsites platform until SQLite compatibility with the
Group module schema is verified (see [issue #21](https://github.com/tomdavidson/tack/issues/21)).

### LocalGov Microsites: local hostnames

Local microsite hostnames follow `{microsite}.{project}.localhost:{port}`.
`*.localhost` resolves to `127.0.0.1` in all modern browsers — no `/etc/hosts`
entries or DNS configuration needed.
