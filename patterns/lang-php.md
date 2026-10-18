# PHP Patterns

> PHP-specific implementation choices for [Tom's Clean Code](toms-clean-code.md) and
> [Tom's Clean Architecture](toms-clean-arch.md). Assumes PHP 8.3+, Composer, PHP_CodeSniffer
> (`phpcs` + `slevomat/coding-standard`), PHPStan (`level: 8` + `phpstan-strict-rules` +
> `spaze/phpstan-disallowed-calls`), and PHPUnit 10+. When PHP offers both an OOP option and a
> functional option, prefer the functional option where it improves clarity and testability.
> Community and framework contracts take precedence: see the When in Rome standing rule.
> [Drupal Pattern](drupal-pattern.md) extends this guide with Drupal-specific conventions.

## Shared PHP Surface Conventions

- Use 2-space indentation and same-line opening braces for declarations and control blocks.
- Use lowercase `true`, `false`, and `null` in plain PHP. Drupal overrides executable literal casing.
- Use one named class, interface, trait, or enum per PSR-4 file, with a matching namespace and filename. Split related variants into small files rather than defeating autoloading.
- Use native types and add PHPDoc when it conveys information native types cannot express, such as collection element types. Avoid redundant prose where the project's community standard permits omission.
- Omit constructor and typed-property documentation only when it adds no useful information and the applicable standard allows it. Framework overrides may require documentation or inherited API signatures.
- Follow an existing project's published style instead of imposing this baseline on it.

## Strategic FP Philosophy

Traditional PHP leans heavily on mutable service classes, inheritance hierarchies, and exceptions
for control flow. Modern PHP 8.3+ supports a clean, Go/Rust/TypeScript-style functional subset:

- **Data and behavior are separate**: model data with `final readonly class` value objects/DTOs
  (promoted constructor properties, zero business methods) and backed `enum`s; write behavior as
  pure functions.
- **Make illegal states unrepresentable**: model state transitions as union types
  (`DraftOrder|SubmittedOrder`) and backed `enum`s, dispatched with exhaustive `match (...)`
  expressions (never `switch`).
- **Errors are values**: domain and application functions return explicit union types
  (`Order|OrderError` where each error variant is a `final readonly class` or `enum`). Exceptions
  (`try`/`catch`) are restricted to infrastructure adapters (`Infra/`) that translate PDO, HTTP, or
  framework exceptions into domain error values.
- **Zero nested branches in control loops**: guard clauses (early `return`) and `array_map` /
  `array_filter` / `array_reduce` with `static fn(...) => ...` closures keep control flow flat.

Rules below are split into **Toolchain-Enforced** (`phpcs.xml.dist` + `phpstan.neon.dist`) and
**Advisory** (enforced via architecture review until AST/lint rules cover them).

---

## Part 1: Enforcement Targets and Tooling

The tables below are delivered by `configs/php` via ADR-0009 stub + extend composition:

- **PHP_CodeSniffer**: `.tack/configs/php/phpcs-base.xml` defines the framework-neutral Strategic FP / Clean Code sniffs shared by plain PHP and Drupal. `.tack/configs/php/phpcs.xml` layers plain-PHP formatting conventions and `RequireReadonlyProperty` on top. Consumer repos receive a seed-once `phpcs.xml.dist` stub extending `./.tack/configs/php/phpcs.xml`.
- **PHPStan**: `.tack/configs/php/phpstan.neon` sets the `level: 8` baseline; consumer repos receive a seed-once `phpstan.neon.dist` stub with `includes: [.tack/configs/php/phpstan.neon]`.
- **Formatting (`dprint fmt`)**: `configs/php/dprint.merge.json` appends `./.tack/configs/php/dprint-php.json` to the consumer's root `dprint.json` `extends` list, wiring `phpcbf` via `dprint-plugin-exec` so `moon run :fmt` and `moon run <proj>:lint` never disagree.
- **Moon tasks**: `.moon/tasks/php.yml` provides `lint`, `lint-fix`, `typecheck`, `test-unit`, `test`, and `verify` for projects tagged `php`.

Nesting and complexity metrics are approximations: a depth threshold does not prohibit every conditional inside a loop, and function size does not prove purity. Do not equate these metrics across languages.

Framework signatures, mutable adapter objects, and documented exception contracts may require scoped exceptions to this proposed profile. Do not impose readonly properties or domain-only type restrictions on framework classes indiscriminately.

### 1. Function Size, Complexity, and Flat Control Flow (`phpcs.xml.dist`)

| Sniff / Metric                                                                           | Setting | Purpose                                                          |
| ---------------------------------------------------------------------------------------- | ------- | ---------------------------------------------------------------- |
| `Generic.Metrics.NestingLevel`                                                           | `2`     | Forbid nested branches inside loops (matches TS/Rust/Py depth 2) |
| `Generic.Metrics.CyclomaticComplexity`                                                   | `8`     | Cap branching complexity per function (error at `10`)            |
| `SlevomatCodingStandard.Functions.FunctionLength`                                        | `30`    | Keep functions small (≤ 30 lines)                                |
| `SlevomatCodingStandard.ControlStructures.EarlyExit`                                     | `error` | Enforce guard clauses; forbid `else` after `return`              |
| `SlevomatCodingStandard.ControlStructures.DisallowContinueWithoutIntegerOperandInSwitch` | `error` | Prevent `switch`/`loop` continue bugs                            |

```php
<?php

declare(strict_types=1);

namespace App\Orders\App;

// GOOD — flat guard clauses, zero else after return, explicit union return type
function validateOrder(OrderRepo $repo, OrderId $id): DraftOrder|OrderError {
  $order = $repo->findById($id);
  if ($order === null) {
    return new OrderNotFoundError($id);
  }
  if (!$order instanceof DraftOrder) {
    return new OrderNotEditableError($id);
  }
  if ($order->items === []) {
    return new EmptyOrderError($id);
  }
  return $order;
}
```

Never nest `if`/`match` branches inside a `foreach` loop. Extract the per-item decision into a
named pure function and compose with `array_map` or `array_filter`.

### 2. Strict & Explicit Types Everywhere (`phpcs` + `phpstan`)

| Rule / Setting                                           | Setting | Purpose                                                                                        |
| -------------------------------------------------------- | ------- | ---------------------------------------------------------------------------------------------- |
| `SlevomatCodingStandard.TypeHints.DeclareStrictTypes`    | `error` | Require `declare(strict_types=1);` at the top of every PHP file                                |
| `SlevomatCodingStandard.TypeHints.ParameterTypeHint`     | `error` | Require explicit native + PHPDoc generic types on all params                                   |
| `SlevomatCodingStandard.TypeHints.ReturnTypeHint`        | `error` | Require explicit native + PHPDoc generic return types                                          |
| `SlevomatCodingStandard.TypeHints.PropertyTypeHint`      | `error` | Require explicit native types on all properties                                                |
| `SlevomatCodingStandard.TypeHints.DisallowMixedTypeHint` | `error` | Ban `mixed` (PHP's equivalent of `any`) in domain/app signatures                               |
| `phpstan` `level`                                        | `8`     | Full union, generic, and nullability checking (6+ in Drupal)                                   |
| `phpstan-strict-rules`                                   | enabled | Strict boolean conditions (`if ($count > 0)`, not `if ($count)`), strict `in_array(..., true)` |

### 3. Immutability, Pure Closures, and Anti-OOP Hygiene

| Rule / Sniff                                                           | Setting | Purpose                                                                      |
| ---------------------------------------------------------------------- | ------- | ---------------------------------------------------------------------------- |
| `SlevomatCodingStandard.Classes.RequireReadonlyProperty`               | `error` | All properties must be `readonly` (`final readonly class`)                   |
| `SlevomatCodingStandard.Classes.DisallowLateStaticBindingForConstants` | `error` | Prefer `self::` + `final` over inheritance hierarchies                       |
| `SlevomatCodingStandard.Functions.StaticClosure`                       | `error` | Require `static fn(...) => ...` so closures never capture `$this`            |
| `SlevomatCodingStandard.Variables.DisallowSuperGlobalVariable`         | `error` | Ban `$_GET`, `$_POST`, `$_SERVER`, `$GLOBALS` outside boundary               |
| `Generic.PHP.ForbiddenFunctions` / `phpstan-disallowed-calls`          | `error` | Ban `eval`, `extract`, `compact`, `var_dump`, `print_r`, `dd`, `die`, `exit` |

---

## Part 2: Advisory Patterns (Architecture & Code Review)

> These patterns cannot be enforced by PHPCS or PHPStan alone without custom rules. Treat them as
> mandatory review standards.

### 1. Feature-First Directory Layout

Organize by feature, separated into `Domain/`, `App/`, and `Infra/`:

```text
src/
├── Orders/
│   ├── Domain/
│   │   ├── Order.php            // final readonly class DTOs & sum-type unions
│   │   ├── OrderStatus.php      // backed enum
│   │   ├── OrderError.php       // final readonly error value classes
│   │   └── OrderRules.php       // pure functions (or static pure methods for PSR-4)
│   ├── App/
│   │   ├── OrderRepo.php        // interface (port)
│   │   └── PlaceOrder.php       // pure orchestration over injected ports
│   └── Infra/
│       └── PdoOrderRepo.php     // thin adapter implementing OrderRepo
└── Shared/
    └── Money.php                // cross-cutting value objects
```

- `Domain/` imports nothing outside PHP stdlib and `Shared/`.
- `App/` imports `Domain/` and declares port `interface`s.
- `Infra/` implements ports and translates framework/PDO/HTTP exceptions into domain error values.

### 2. Data ≠ Behavior: `final readonly class` + Pure Functions

Model data with `final readonly class` and promoted constructor properties—with **zero business
methods**:

```php
<?php

declare(strict_types=1);

namespace App\Orders\Domain;

final readonly class OrderItem {
  public function __construct(
    public Sku $sku,
    public int $quantity,
    public Cents $unitPrice,
  ) {}
}

final readonly class DraftOrder {
  /** @param list<OrderItem> $items */
  public function __construct(
    public OrderId $id,
    public CustomerId $customerId,
    public array $items,
  ) {}
}
```

Because Composer's PSR-4 autoloader only autoloads classes/interfaces/enums on demand (not
standalone `function` declarations unless listed in `composer.json` `autoload.files`), choose one
of two patterns consistently for pure functions:

1. **Namespaced free functions** in `Domain/*Functions.php` registered under `composer.json`
   `autoload.files`.
2. Stateless function-module classes: use `final class OrderRules` with a private constructor and static pure methods when class-based autoloading is useful. Never combine `final` and `abstract`. This packaging is an option, not a community requirement or a reason to turn every helper into a class.

The adjacent `OrderItem` and `DraftOrder` declarations above illustrate related types; put them in `OrderItem.php` and `DraftOrder.php` in a PSR-4 project. Namespaced free functions remain appropriate when explicitly loaded; do not assume PSR-4 autoloads function calls.

### Thin Export Interfaces and Services

A class may expose a module's public API without containing all its business logic. Define a narrow interface for consumers, implement it with a thin service that injects IO ports, and delegate decisions to small pure helpers. Register services only where lifecycle management, dependencies, or framework integration justify it. Pure helpers need no container registration.

Test pure helpers directly with ordinary values. Test orchestration separately with in-memory port fakes, then integration-test framework wiring. Calling an IO port makes orchestration effectful even when it is easy to unit-test; only the decision-making helpers are pure.

### 3. Algebraic State & Exhaustive `match` (Never `switch`)

Use PHP 8's `match` expression instead of `switch`. Unlike `switch`, `match` uses strict `===`
comparison, returns a value as an expression, does not fall through, and PHPStan verifies
exhaustiveness across backed `enum`s and union types:

```php
enum OrderStatus: string {
  case Draft = 'draft';
  case Submitted = 'submitted';
  case Cancelled = 'cancelled';
}

function isEditable(OrderStatus $status): bool {
  return match ($status) {
    OrderStatus::Draft => true,
    OrderStatus::Submitted, OrderStatus::Cancelled => false,
  };
}
```

Never pass boolean flag parameters (`function process(Order $o, bool $dryRun)`). Define a
two-case `enum ExecutionMode { case Live; case DryRun; }` instead.

### 4. Declarative Collection Pipelines

Prefer `array_map`, `array_filter`, and `array_reduce` with `static fn` arrows over mutating
`foreach` loops:

```php
/**
 * @param list<OrderItem> $items
 * @return int
 */
function calculateTotalCents(array $items): int {
  return array_reduce(
    $items,
    static fn(int $sum, OrderItem $item): int => $sum + ($item->quantity * $item->unitPrice->value),
    0,
  );
}
```

When `array_filter` is used on a `list<T>`, wrap with `array_values(...)` so PHPStan preserves the
`list<T>` type without gaps in integer keys.

---

## Testing (`PHPUnit`)

| Suite       | Moon Task                          | Scope & Rules                                                    |
| ----------- | ---------------------------------- | ---------------------------------------------------------------- |
| Unit        | `moon run <proj>:test-unit`        | Pure `Domain/` and `App/` logic with in-memory `interface` fakes |
| Integration | `moon run <proj>:test-integration` | Real DB/framework kernel tests (`runInCI: false` by default)     |
| E2E         | `moon run <proj>:test-e2e`         | Full HTTP/browser tests (`runInCI: false`)                       |

- Implement port `interface`s with in-memory fake classes (`final class FakeOrderRepo implements OrderRepo`) rather than PHPUnit `$this->createMock(...)`.
- Use `#[DataProvider('...')]` with `static` generator methods for table-driven and boundary-value
  tests.

## Anti-Patterns

| Smell                                        | Problem                                      | Instead                                                |
| -------------------------------------------- | -------------------------------------------- | ------------------------------------------------------ |
| Missing `declare(strict_types=1);`           | Silent scalar type coercion                  | First statement of every `.php` file                   |
| Mutable entities with setters                | Shared mutable state across layers           | `final readonly class` + return new instance           |
| `switch` statement                           | Loose `==`, fallthrough bugs, non-exhaustive | `match (...)` expression                               |
| Throwing exceptions for domain rule failures | Invisible in PHP type signatures             | Return union `Order\|OrderError`                       |
| Nested `if`/`switch` inside `foreach`        | Fails `Generic.Metrics.NestingLevel` (`2`)   | Guard clauses (`EarlyExit`) + pure helper function     |
| Untyped `array` parameters/returns           | Loses static analysis (`mixed` elements)     | `@param list<OrderItem>` / `@param array<string, int>` |
| Closures without `static`                    | Implicitly binds `$this` to closure scope    | `static fn(...) => ...`                                |

## Checklist

- [ ] `declare(strict_types=1);` at the top of every PHP file
- [ ] Native parameter, return, and property types on every declaration + PHPDoc `list<T>` / `array<K, V>`
- [ ] PHPStan `level: 8` (or `level: 6+` with `phpstan-strict-rules` in Drupal)
- [ ] Functions ≤ 30 lines, cyclomatic complexity ≤ 8, nesting depth ≤ 2
- [ ] Guard clauses (`EarlyExit`), zero `else` after `return`
- [ ] `final readonly class` for all domain/DTO types; zero mutable properties
- [ ] Backed `enum`s and union types with exhaustive `match (...)` (never `switch`)
- [ ] `static fn(...) => ...` on all closures
- [ ] Expected domain/application errors returned as union values; `try`/`catch` restricted to `Infra/`
