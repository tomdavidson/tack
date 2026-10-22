# Drupal Pattern (Functional Core, Imperative Drupal Shell)

> Architecture and testing pattern for Drupal 11+ applications and custom modules (including
> LocalGov Drupal Microsites `dlg-ms`). Follows [Tom's Clean Code](toms-clean-code.md),
> [Tom's Clean Architecture](toms-clean-arch.md), [PHP Patterns](lang-php.md), and
> [Testing](testing.md).

## Community Compatibility Comes First

This guide extends [PHP Patterns](lang-php.md). For Drupal modules intended for drupal.org, Drupal community conventions and supported framework APIs take precedence over the generic PHP preferences. Apply Strategic FP within those constraints, not by disabling community checks.

- Retain the project's supported `Drupal` and `DrupalPractice` rulesets and its Drupal GitLab CI checks. Passing those checks is necessary for this project's compatibility goal, but is not a guarantee of publication, security coverage, or acceptance.
- Use Drupal's 2-space indentation, same-line braces, naming, declaration spacing, and documentation conventions. Use uppercase `TRUE`, `FALSE`, and `NULL` as executable literals; keep native type keywords and PHPDoc types in their required casing. Plain PHP retains lowercase literals.
- Put each PSR-4 class, interface, trait, or enum in its matching file under the module namespace. The grouped declarations in examples below are explanatory: split them into separate files.
- Supply required class/interface/enum summaries, procedural-file `@file` documentation, and method documentation. Use inherited documentation where appropriate. Omit redundant constructor or typed-property prose only where the installed Coder version and current community standard permit it; retain useful collection types and required descriptions. Do not suppress commenting rules merely to reduce noise.
- Preserve framework method signatures, reference parameters, mutable framework objects, and exception contracts. Do not force readonly classes onto forms, plugins, entities, or other framework subclasses. Add types only where compatible with supported Drupal/PHP versions and inherited APIs.
- Treat code snippets as architecture sketches, not PHPCS-validated drop-in module files. Run the module's actual coding-standard, static-analysis, and test jobs before publishing.
- **Layered configuration (`configs/drupal` extends `configs/php`, ADR-0009)**:
  - `drupal.nix` imports `../php/php.nix` (inheriting the sandboxed `composer` wrapper) and adds Drupal's PHP extension set and FrankenPHP.
  - `.tack/configs/drupal/phpcs.xml` includes `../php/phpcs-base.xml` plus `Drupal` and `DrupalPractice`; the consumer's seed-once `phpcs.xml.dist` stub references `./.tack/configs/drupal/phpcs.xml`.
  - `.tack/configs/drupal/phpstan.neon` includes `../php/phpstan.neon` at `level: 6`; the consumer's seed-once `phpstan.neon.dist` stub includes `.tack/configs/drupal/phpstan.neon`.
  - `configs/drupal/dprint.merge.json` appends `./.tack/configs/drupal/dprint-drupal.json` to the consumer root `dprint.json` `extends` list so `dprint fmt` runs `phpcbf` across `.php`, `.module`, `.inc`, `.install`, `.theme`, `.profile`, and `.engine` files.

## Core Principle: Keep Drupal at the Edge

Drupal's plugin system (`ControllerBase`, `FormBase`, `BlockBase`, `FieldFormatterBase`,
`QueueWorkerBase`), entity API (`EntityInterface`, `NodeInterface`), and hook system (`#[Hook]` /
`*.module`) are **imperative framework shells**. Putting business logic inside controllers, forms,
hooks, or container-coupled service classes makes code slow to test (requiring a full Drupal Kernel
and MariaDB boot) and difficult to reason about.

Instead, structure every custom module around a strict split:

1. **Functional Core (`src/Domain/`, `src/App/`)**:
   - Pure PHP 8.3+ (`declare(strict_types=1);`).
   - Zero imports from `Drupal\Core\*` or contrib modules (except pure value interfaces if unavoidable).
   - Data modeled as `final readonly class` DTOs/Value Objects and backed `enum`s.
   - Business decisions written as stateless pure functions returning `T|DomainError` union values.
   - Tested in milliseconds via `tests/src/Unit/` (`moon run <module>:test-unit`) with **zero
     database or Drupal container bootstrap**.
2. **Imperative Drupal Shell (`src/Controller/`, `src/Form/`, `src/Plugin/`, `src/Hook/`, `src/Infra/`)**:
   - Thin adapters (10–25 lines per method).
   - Extract typed primitives from `EntityInterface` / `FormStateInterface` / `Request` into
     `final readonly class` domain inputs.
   - Call the pure domain/application function.
   - Map the returned `final readonly` result or error value back into a render array,
     `FormStateInterface::setErrorByName()`, `AccessResult`, or entity save.

---

## Repository & Workspace Layout

```text
<repo-root>/
├── .tack/                               # tack submodule
├── devenv.nix                           # imports ./.tack/configs/drupal/variants/dlg-ms.nix
├── phpcs.xml.dist                       # seeded once from configs/drupal
├── phpstan.neon.dist                    # seeded once from configs/drupal
├── phpunit.xml.dist                     # seeded once from configs/drupal
├── apps/
│   └── hub/                             # scaffolded via `moon generate dlg-ms -- --name hub`
│       ├── moon.yml                     # layer: application, tags: ["drupal", "drupal-app"]
│       ├── composer.json                # path repo -> ../../packages/drupal/*
│       ├── config/sync/                 # exported Drupal configuration
│       └── web/
└── packages/
    └── drupal/
        └── my_module/                   # scaffolded via `moon generate drupal-module`
            ├── moon.yml                 # layer: library, tags: ["drupal"]
            ├── my_module.info.yml
            ├── my_module.services.yml
            ├── src/
            │   ├── Domain/              # pure data (final readonly class, enum) + pure rules
            │   ├── App/                 # port interfaces + use-case orchestration
            │   ├── Infra/               # Drupal entity/storage/state adapters implementing ports
            │   ├── Controller/          # thin HTTP/render adapters
            │   ├── Form/                # thin Form API adapters
            │   ├── Hook/                # thin #[Hook] classes (Drupal 11.1+ OOP hooks)
            │   └── Plugin/              # thin Block/Field/Queue plugins
            └── tests/
                └── src/
                    ├── Unit/            # fast unit tests for Domain/ and App/ (runInCI: true)
                    ├── Kernel/          # DB/container adapter tests for Infra/ (test-integration)
                    └── Functional/      # full browser E2E tests (test-e2e)
```

---

## End-to-End Example: Form & Entity Validation

### 1. Pure Domain (`src/Domain/`)

```php
<?php

declare(strict_types=1);

namespace Drupal\my_module\Domain;

enum PublicationTier: string {
  case Standard = 'standard';
  case Priority = 'priority';
}

final readonly class PublishRequest {
  /** @param list<string> $tags */
  public function __construct(
    public string $title,
    public PublicationTier $tier,
    public array $tags,
  ) {}
}

final readonly class ValidationError {
  public function __construct(
    public string $field,
    public string $message,
  ) {}
}

final readonly class ValidatedPublication {
  /** @param list<string> $normalizedTags */
  public function __construct(
    public string $title,
    public PublicationTier $tier,
    public array $normalizedTags,
  ) {}
}

final class PublicationRules {
  private const int MAX_PRIORITY_TAGS = 3;

  private function __construct() {}

  public static function validate(PublishRequest $req): ValidatedPublication|ValidationError {
    $title = trim($req->title);
    if ($title === '') {
      return new ValidationError('title', 'Title is required.');
    }
    $tags = array_values(array_unique(array_filter(
      array_map(static fn(string $t): string => strtolower(trim($t)), $req->tags),
      static fn(string $t): bool => $t !== '',
    )));
    if ($req->tier === PublicationTier::Priority && count($tags) > self::MAX_PRIORITY_TAGS) {
      return new ValidationError('tags', 'Priority publications allow at most 3 tags.');
    }
    return new ValidatedPublication($title, $req->tier, $tags);
  }
}
```

### 2. Thin Imperative Drupal Adapter (`src/Form/`)

```php
<?php

declare(strict_types=1);

namespace Drupal\my_module\Form;

use Drupal\Core\Form\FormBase;
use Drupal\Core\Form\FormStateInterface;
use Drupal\my_module\Domain\PublicationRules;
use Drupal\my_module\Domain\PublicationTier;
use Drupal\my_module\Domain\PublishRequest;
use Drupal\my_module\Domain\ValidationError;

final class PublishForm extends FormBase {
  public function getFormId(): string {
    return 'my_module_publish_form';
  }

  /**
   * @param array<string, mixed> $form
   * @return array<string, mixed>
   */
  public function buildForm(array $form, FormStateInterface $form_state): array {
    // Form element definitions only...
    return $form;
  }

  /** @param array<string, mixed> $form */
  public function validateForm(array &$form, FormStateInterface $form_state): void {
    $req = new PublishRequest(
      title: (string) $form_state->getValue('title', ''),
      tier: PublicationTier::tryFrom((string) $form_state->getValue('tier', 'standard'))
        ?? PublicationTier::Standard,
      tags: explode(',', (string) $form_state->getValue('tags', '')),
    );

    $result = PublicationRules::validate($req);
    if ($result instanceof ValidationError) {
      $form_state->setErrorByName($result->field, $this->t('@msg', ['@msg' => $result->message]));
      return;
    }

    $form_state->set('validated_publication', $result);
  }

  /** @param array<string, mixed> $form */
  public function submitForm(array &$form, FormStateInterface $form_state): void {
    // Persist validated DTO via injected port...
  }
}
```

---

## Thin Classes as Export Interfaces

Expose a module's behavior through a narrow interface when consumers or the framework need a service. Its implementation is a thin adapter or orchestrator, not the home for every business rule:

```text
Form / Controller / Hook / external module
  -> PublicationPublisherInterface
  -> PublicationPublisher (injected storage port)
       -> PublicationRules::validate(request)  [pure decision]
       -> storage port on success             [effect]
```

Register the port-consuming service and its concrete IO adapters in `*.services.yml` where Drupal needs them. Call stateless pure helpers directly; they do not need container entries merely because they contain business logic. Static function-module classes are optional PSR-4 packaging, not a Drupal requirement. Explicitly loaded namespaced functions are also possible.

Unit-test pure helpers directly with values and no container. Unit-test orchestration separately with in-memory port fakes. Use integration tests for container wiring, storage adapters, and framework behavior. An orchestrator that calls IO is not pure; the purpose of the split is to isolate decisions and make effects explicit.

## Dependency Injection & Ports in Drupal

- **Constructor injection only**: never call `\Drupal::service(...)` or `\Drupal::entityTypeManager()`
  inside classes. Use `ContainerInjectionInterface::create(ContainerInterface $container)` or
  Drupal 11's `autowire: true` in `*.services.yml`.
- **Define narrow port interfaces in `src/App/`**: instead of injecting `EntityTypeManagerInterface`
  into an application use-case, define `interface MicrositeLookupPort` in `src/App/` and implement
  it in `src/Infra/DrupalMicrositeLookupAdapter` (which wraps `EntityTypeManagerInterface`).
  That keeps `src/App/` 100% unit-testable with an in-memory fake.

---

## Testing Tiers (`configs/drupal` + ADR-0010)

| Tier           | Directory              | Moon Task                         | Runs in CI (`moon ci`)             | When to Use                                                                                         |
| -------------- | ---------------------- | --------------------------------- | ---------------------------------- | --------------------------------------------------------------------------------------------------- |
| **Unit**       | `tests/src/Unit`       | `moon run <mod>:test-unit`        | **Yes** (cached, < 1 s)            | All `Domain/` and `App/` rules, value objects, and use-case orchestration with in-memory port fakes |
| **Kernel**     | `tests/src/Kernel`     | `moon run <mod>:test-integration` | No (requires MariaDB)              | Testing `Infra/` adapters, entity storage queries, field config schemas, and service wiring         |
| **Functional** | `tests/src/Functional` | `moon run <mod>:test-e2e`         | No (requires FrankenPHP + MariaDB) | End-to-end HTTP journeys, permissions, and rendered page assertions                                 |

### Fast Local Verification

```bash
moon run my_module:verify # runs lint (phpcs) + typecheck (phpstan) + test-unit (phpunit)
```

## Anti-Patterns

| Don't                                                                    | Do Instead                                                                                    |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| Business logic inside `*.module` hooks or `FormBase`                     | Extract to `src/Domain/` pure functions; keep hook/form to 10–25 lines                        |
| Passing `NodeInterface` / `EntityInterface` into domain functions        | Map entity fields to a `final readonly class` DTO at the adapter boundary                     |
| Calling `\Drupal::service()` static locator                              | Inject narrow port interfaces via constructor / `autowire: true`                              |
| Writing Kernel tests for pure branching logic                            | Test all branching/validation rules in `tests/src/Unit`                                       |
| Hand-editing `composer.json` at the repo root                            | Each app (`apps/<name>/composer.json`) owns its manifest; modules live in `packages/drupal/*` |
| Enabling dev-only modules (`devel`, `stage_file_proxy`) in `config/sync` | Keep dev modules out of exported config (`deploy.sh` drift gate refuses them)                 |

## Checklist

- [ ] Module scaffolded with `moon generate drupal-module` under `packages/drupal/<name>`
- [ ] `declare(strict_types=1);` at the top of every `.php`, `.module`, and `.install` file
- [ ] Pure domain types (`final readonly class`, `enum`) and rules in `src/Domain/` with zero Drupal imports
- [ ] Application ports (`interface`) in `src/App/`, implemented by Drupal adapters in `src/Infra/`
- [ ] Controllers, Forms, Plugins, and `#[Hook]` classes act as thin adapters (≤ 25 lines per method)
- [ ] Community `Drupal` / `DrupalPractice` checks pass without style-conflict exclusions
- [ ] Required documentation, uppercase executable literals, and one-type-per-file layout follow the supported Coder standard
- [ ] Complexity budgets are validated against actual PHPCS configuration; nesting metrics do not prove a ban on every branch inside a loop
- [ ] PHPStan passes at the project's configured level; do not claim strict-rules coverage until the extension is installed and enabled

- [ ] All domain/app logic covered by fast unit tests in `tests/src/Unit` (`moon run <mod>:test-unit`)
- [ ] Config export matches active config (`devenv tasks run drupal:deploy` passes drift gate)
