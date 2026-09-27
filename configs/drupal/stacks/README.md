# configs/drupal/stacks

Devenv stack modules for Drupal projects. Each stack is a Nix module
imported by the consumer's `devenv.nix` at eval time via the `.tack`
submodule — never materialized into the project.

## Available stacks

| Stack | Path | Description |
|---|---|---|
| `localgov-multisite` | `configs/drupal/stacks/localgov-multisite` | FrankenPHP + MariaDB 11.4 + PHP 8.3 + LocalGov Drupal multisite |

## Stack selection

In `tackrc.yml`, add the stack package alongside `configs/drupal`:

```yaml
pkgs:
  - configs/common
  - configs/devenv
  - configs/drupal
  - configs/drupal/stacks/localgov-multisite
```

In `devenv.nix`, import the stack module:

```nix
{ pkgs, config, ... }:
{
  imports = [ ./.tack/configs/drupal/stacks/localgov-multisite.nix ];

  # Override stack defaults here:
  env.HASH_SALT = "your-project-specific-value";
}
```

## Post-install hook

The `localgov-multisite` stack package also delivers a post-install hook
script via tack:

```
configs/drupal/stacks/localgov-multisite/
  tack.yml          # path_prefix: scripts/drupal
  post-install.sh   # linked -> scripts/drupal/post-install.sh in consumer
```

The generic `scripts/drupal/install.sh` (from `configs/drupal`) calls
`scripts/drupal/post-install.sh` if it exists after Drupal installation
completes. For LocalGov this enables the demo module, creates multisite
config, etc. Override or replace it in the consumer project.

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

`moon ci` runs `check` by default: lint + analyse + test-unit. Fast,
cacheable, no service spin-up. Use `check-full` for the full integration
suite locally or in a dedicated CI job.

### Per-project overrides

Override any inherited task arg in the project `moon.yml`:

```yaml
# packages/drupal/my_module/moon.yml
tags: ["drupal-module"]
tasks:
  test-unit:
    args: ["--testsuite=unit,kernel", "--configuration=phpunit.xml.dist"]

# microsites/my-council/moon.yml
tags: ["drupal-site"]
tasks:
  test-integration:
    args: ["--testsuite=kernel,custom", "--configuration=phpunit.xml.dist"]
  reset:
    env:
      LOCALGOV_DEMO: "1"
```

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
