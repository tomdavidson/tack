# configs/drupal/stacks

Devenv stack modules for Drupal projects. Each stack is a Nix module
imported by the consumer's `devenv.nix`. The import is automated by the
tack tera renderer — the consumer does not write the `imports` line manually.

## Available stacks

| Stack | Path | Description |
|---|---|---|
| `localgov-multisite` | `configs/drupal/stacks/localgov-multisite.nix` | FrankenPHP + MariaDB 11.4 + PHP 8.3 + LocalGov Drupal multisite |

## Stack selection

A stack requires two entries in `tackrc.yml` — one to select the devenv
Nix module, one to deliver the stack's extra scripts:

```yaml
pkgs:
  - configs/drupal
  - configs/drupal/stacks/localgov-multisite   # delivers post-install.sh

vars:
  drupal:
    stack: localgov-multisite                  # renders the devenv.nix import
```

`vars.drupal.stack` is read by `configs/devenv/devenv.tera.nix` and renders
to:

```nix
imports = [ ./.tack/configs/drupal/stacks/localgov-multisite.nix ];
```

The consumer's `devenv.nix` only needs overrides — no manual import line:

```nix
{ pkgs, config, ... }:
{
  # Stack imported automatically via vars.drupal.stack in tackrc.yml.
  # Override stack defaults here:
  env.HASH_SALT = "your-project-specific-value";
}
```

Tack has no dependency mechanism so the two entries are intentionally
separate: `pkgs` controls file delivery, `vars` controls tera rendering.
Stacks are permitted to be slightly wet rather than forcing an abstraction
tack doesn't have.

## Post-install hook

The `localgov-multisite` stack package delivers a post-install hook via tack's
`path_prefix` mechanism:

```
configs/drupal/stacks/localgov-multisite/
  tack.yml          # path_prefix: scripts/drupal
  post-install.sh   # linked -> scripts/drupal/post-install.sh in consumer
```

`scripts/drupal/install.sh` (from `configs/drupal`) calls
`scripts/drupal/post-install.sh` if it exists after Drupal installation
completes. For LocalGov this enables the demo module and configures multisite.
Override or replace it in the consumer project.

To enable the demo module on `reset`:

```yaml
# microsites/my-site/moon.yml
tasks:
  reset:
    env:
      LOCALGOV_DEMO: "1"
```

---

## Moon task integration

The `.moon/tasks/drupal-site.yml` and `.moon/tasks/drupal-module.yml`
packages (delivered via `configs/.moon`) provide inherited task sets for
Drupal site and module projects. Tag your project to opt in:

```yaml
# moon.yml (site)
tags: ["drupal-site"]

# moon.yml (custom module)
tags: ["drupal-module"]
```

### Task tiers

```
test-unit         phpunit --testsuite=unit    No services. Cached by moon.
test-integration  devenv tasks run + phpunit  Services started via devenv DAG.
test-e2e          devenv tasks run + phpunit  Services started via devenv DAG.
test              devenv test                 Full ci.sh: install+smoke+phpunit.
```

### Service readiness

`test-integration` and `test-e2e` open with:

```bash
devenv tasks run drupal:deploy
```

This triggers devenv's task DAG:

```
drupal:deploy
  after: app:composer     # composer install if needed
  after: db:user          # waits for mysql@ready, creates db + user
  after: s3:buckets       # waits for rustfs@ready, creates buckets
  runs: deploy.sh         # drush updb, cim, cr, drift gate
```

By the time `deploy.sh` exits, MariaDB and the web server are confirmed
live. PHPUnit then runs against a fully installed, deployed site. No
polling loop or persistent moon task needed.

If `devenv up` is already running in another terminal, `devenv tasks run`
reuses the existing services.

### CI defaults

| Task | Services | Cached | Runs in CI |
|---|---|---|---|
| `lint` | ✗ | ✓ | ✓ |
| `lint-fix` | ✗ | ✓ | ✗ |
| `analyse` | ✗ | ✓ | ✓ |
| `test-unit` | ✗ | ✓ | ✓ |
| `test-integration` | ✓ via devenv | ✗ | ✗ |
| `test-e2e` | ✓ via devenv | ✗ | ✗ |
| `test` | ✓ via devenv | ✗ | ✓ |
| `check` | ✗ | ✓ | ✓ (moon ci default) |
| `check-full` | ✓ | ✗ | ✗ (explicit opt-in) |
| `deploy` | must be up | ✗ | ✗ |
| `reset` | must be up | ✗ | ✗ |

`moon ci` is the primary task runner. It runs `check` by default: lint +
analyse + test-unit. Fast, cacheable, no service spin-up. `runInCI: true`
is the default. Devenv manages services. Use `check-full` for the full
integration suite locally or in a dedicated CI job.

### Per-project overrides

Override any inherited task arg in the project `moon.yml`:

```yaml
# packages/drupal/my_module/moon.yml
tags: ["drupal-module"]
tasks:
  test-unit:
    args: ["--testsuite=unit,kernel", "--configuration=phpunit.xml.dist"]
```

### LocalGov Microsites: MariaDB required for tests

Use MariaDB for `SIMPLETEST_DB` when running tests against a LocalGov
Microsites platform. LocalGov's Group module schema has not been validated
against sqlite. Drupal kernel tests install a fresh Drupal into `drupal_test`
using random table prefixes — no clone of the dev database is involved.

Sqlite offers a potential 25–33% speed improvement for kernel tests but is
deferred until compatibility with LocalGov's Group schema is confirmed.
See [issue #21](https://github.com/tomdavidson/tack/issues/21).

### Workspace globs

Add these globs to the consumer's `.moon/workspace.yml` so moon discovers
all module and site projects:

```yaml
projects:
  globs:
    - "packages/drupal/*"
    - "microsites/*"
    - "."
```
