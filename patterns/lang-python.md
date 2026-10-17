# Python Patterns

> Python-specific implementation choices for [Tom's Clean Code](toms-clean-code.md) and
> [Tom's Clean Architecture](toms-clean-arch.md). Assumes Python 3.12+, `uv`, `ruff`,
> `basedpyright`, `pytest`, and `hypothesis`. When Python offers both an OOP option and a
> functional option, always choose the functional option.

## Strategic FP Philosophy

Python defaults to mutable objects and class hierarchies, which makes discipline essential. Write
Python in the same style as TypeScript and Rust:

- **Data and behavior are separate**: model data with `@dataclass(frozen=True, slots=True)`,
  `TypedDict`, and `NewType` (zero methods on data classes); write behavior as module-level pure
  functions.
- **Make illegal states unrepresentable**: model state transitions as algebraic union types
  (`type OrderState = DraftOrder | SubmittedOrder | CancelledOrder`) narrowed with exhaustive
  `match`/`case` and `typing.assert_never`.
- **Errors are values**: domain and application functions return explicit error values (`Result[T, E]`
  or union of success and frozen error dataclasses). `try`/`except` is restricted to infrastructure
  boundaries (`infra.py`) that translate third-party exceptions into domain errors.
- **Zero nested branches in control loops**: guard clauses (early `return`) and declarative
  comprehensions keep control flow flat.

Rules below are split into **Toolchain-Enforced** (`configs/python/ruff.toml` + `basedpyright` +
`@dprint/ruff`) and **Advisory** (enforced via architecture review until AST/lint rules cover them).

---

## Part 1: Toolchain-Enforced Rules

### 1. Anti-OOP & Data ≠ Behavior (`PLR0904`, `PLR6301`, `SLF`)

Configured in `configs/python/ruff.toml` (with `preview = true`):

| Rule / Setting                     | Value   | Purpose                                                                |
| ---------------------------------- | ------- | ---------------------------------------------------------------------- |
| `PLR0904` (`max-public-methods`)   | `0`     | Data classes (`@dataclass`, `TypedDict`) may have 0 public OOP methods |
| `PLR6301` (`no-self-use`)          | `error` | Any method not reading `self` must be a module-level free function     |
| `RUF008` / `RUF009` / `RUF012`     | `error` | Ban mutable class and dataclass attributes/defaults                    |
| `B006` / `B008` (`flake8-bugbear`) | `error` | Ban mutable default function arguments (`def f(items=[])`)             |
| `PLW0602` / `PLW0603`              | `error` | Ban `global` variable mutation inside functions                        |
| `SLF001` (`flake8-self`)           | `error` | Ban reaching into `obj._private` attributes across objects             |

`PLR0904` (`max-public-methods = 0`) is relaxed only in `**/app.py` (where `typing.Protocol` port
interfaces are declared), `**/infra.py` / `**/adapters/**` (where thin framework or port adapter
classes live), and `**/tests/**`.

### 2. Function Size, Complexity, and Flat Control Flow

| Rule / Setting                       | Value | Purpose                                                             |
| ------------------------------------ | ----- | ------------------------------------------------------------------- |
| `C901` (`mccabe.max-complexity`)     | `8`   | Cap cyclomatic complexity (matches Rust `8` / TS `5`)               |
| `PLR1702` (`max-nested-blocks`)      | `2`   | Forbid nested branches inside loops (matches TS/Rust depth `2`)     |
| `PLR0915` (`max-statements`)         | `30`  | Keep functions small (5–30 statements)                              |
| `PLR0913` (`max-args`)               | `4`   | 2–3 params typical; 4+ requires a frozen dataclass or `TypedDict`   |
| `PLR0912` (`max-branches`)           | `8`   | Cap branching sprawl                                                |
| `PLR0911` (`max-returns`)            | `6`   | Allow flat guard clauses while capping sprawl                       |
| `RET505`–`RET508` (`flake8-return`)  | `err` | No `else` / `elif` after `return`, `raise`, `break`, `continue`     |
| `FBT001`–`FBT003` (`boolean-trap`)   | `err` | No boolean flag parameters; use `Literal` or `Enum`                 |
| `PLR2004` (`magic-value-comparison`) | `err` | Extract magic numbers/strings to named constants (relaxed in tests) |
| `SIM` + `FURB`                       | `err` | Rewrite imperative loop mutations into declarative transforms       |

```python
# GOOD — flat guard clauses, zero else after return, explicit return type
def validate_order(repo: OrderRepo, order_id: OrderId) -> Order | OrderError:
    order = repo.find_by_id(order_id)
    if order is None:
        return OrderNotFoundError(order_id=order_id)
    if not isinstance(order, DraftOrder):
        return OrderNotEditableError(order_id=order_id)
    if not order.items:
        return EmptyOrderError(order_id=order_id)
    return order
```

Never put nested `if`/`match` branches inside a `for` loop. Extract the per-item decision into a
named pure helper function and call it from a comprehension or `filter`/`map` pipeline.

### 3. Explicit Types Everywhere (`ANN` + `basedpyright`)

| Tool / Rule                       | Setting    | Purpose                                                      |
| --------------------------------- | ---------- | ------------------------------------------------------------ |
| `ANN001`–`ANN206`                 | `error`    | Require explicit parameter and return types on all functions |
| `ANN401`                          | `error`    | Ban `typing.Any` in function signatures                      |
| `basedpyright` (`typecheck` task) | `standard` | Static type checking, union narrowing, and exhaustiveness    |
| `UP` (`pyupgrade`)                | `error`    | Use modern `X                                                |

```python
from typing import NewType

OrderId = NewType("OrderId", str)
CustomerId = NewType("CustomerId", str)
Cents = NewType("Cents", int)
```

### 4. Error Boundary & Imperative Shell Hygiene

| Rule Family                   | Purpose                                                                 |
| ----------------------------- | ----------------------------------------------------------------------- |
| `BLE001` (`blind-except`)     | Ban bare `except:` and blind `except Exception:`                        |
| `TRY301` (`raise-within-try`) | Forbid raising and catching inside the same `try` block as control flow |
| `TRY201` + `RSE` + `B904`     | Clean exception chaining (`raise ... from err`) at adapter boundaries   |
| `C4` (`comprehensions`)       | Prefer declarative list/dict/set comprehensions over builder calls      |
| `T20` (`flake8-print`)        | Ban `print()` in library and application code (allowed in `scripts/`)   |
| `PTH` (`use-pathlib`)         | Require `pathlib.Path` over `os.path` string manipulation               |
| `DTZ` (`datetimez`)           | Require timezone-aware `datetime` objects (`tz=datetime.UTC`)           |
| `ARG` (`unused-arguments`)    | Flag unused arguments unless explicitly prefixed with `_`               |
| `A` (`flake8-builtins`)       | Prevent shadowing built-ins (`id`, `type`, `list`, `input`)             |
| `ERA` (`eradicate`)           | Flag commented-out dead code                                            |
| `S` (`bandit`)                | Flag `eval`, `exec`, shell injection, hardcoded secrets                 |

### 5. Formatting (`@dprint/ruff`)

Always format with `moon run :fmt` (`dprint fmt`, which formats Python via `@dprint/ruff`):

- 4-space indentation, 100-character line width, double quotes, sorted imports.
- Do not add a `[format]` table to `ruff.toml`; `dprint.json` is the single formatting authority.
  (`line-length = 100` remains in `ruff.toml` only because Ruff ignores `.editorconfig` and uses
  `line-length` when wrapping `ruff check --fix` autofixes.)

---

## Part 2: Advisory Patterns (Architecture & Code Review)

> These patterns cannot be fully enforced by Ruff alone (e.g., local variable reassignment,
> requiring `frozen=True` on every `@dataclass`, or forbidding `raise` in domain modules). Treat
> them as mandatory review standards.

### 1. Feature-First Module Structure

Organize by feature, separated into `domain.py`, `app.py`, and `infra.py` (matches
[Tom's Clean Architecture](toms-clean-arch.md)):

```text
src/my_pkg/
├── orders/
│   ├── __init__.py          # re-exports public feature API
│   ├── domain.py            # frozen dataclasses, sum types, pure functions
│   ├── app.py               # use cases, Protocol ports, orchestration
│   └── infra.py             # adapters: SQL/HTTP/filesystem, DTO validation
├── inventory/
│   ├── __init__.py
│   ├── domain.py
│   ├── app.py
│   └── infra.py
├── shared/
│   └── types.py             # NewType primitives, Result[T, E] helpers
└── main.py                  # composition root: wire adapters, start CLI/server
```

- `domain.py` imports nothing outside the Python standard library (`dataclasses`, `typing`, `enum`,
  `decimal`) and `shared`.
- `app.py` imports `domain.py` and defines structural ports via `typing.Protocol`.
- `infra.py` imports external libraries (`httpx`, `sqlalchemy`, `pydantic`) and implements ports.

### 2. Algebraic Data Types & Exhaustive `match`

Model domain entities and states with `@dataclass(frozen=True, slots=True)` and union types—never
mutable classes with methods or boolean state flags:

```python
from dataclasses import dataclass, replace
from typing import assert_never


@dataclass(frozen=True, slots=True)
class DraftOrder:
    id: OrderId
    customer_id: CustomerId
    items: tuple[OrderItem, ...]


@dataclass(frozen=True, slots=True)
class SubmittedOrder:
    id: OrderId
    customer_id: CustomerId
    items: tuple[OrderItem, ...]
    total_cents: Cents


type Order = DraftOrder | SubmittedOrder


def describe_order(order: Order) -> str:
    match order:
        case DraftOrder(id=order_id, items=items):
            return f"Draft {order_id} ({len(items)} items)"
        case SubmittedOrder(id=order_id, total_cents=total):
            return f"Submitted {order_id} ({total} cents)"
        case _ as unreachable:
            assert_never(unreachable)
```

Use `tuple[T, ...]` instead of `list[T]` on frozen dataclasses so nested collections are deeply
immutable (`hash()`-safe and mutation-proof). Use `dataclasses.replace(order, ...)` for state
updates.

### 3. Explicit Errors as Data (No Exceptions for Control Flow)

Do not raise exceptions for expected domain or application failures. Model failures as frozen
dataclasses and return a union (`Order | OrderError` or a lightweight `Ok[T] | Err[E]`):

```python
@dataclass(frozen=True, slots=True)
class ItemLimitExceededError:
    limit: int
    actual: int


@dataclass(frozen=True, slots=True)
class DuplicateItemError:
    sku: str


type OrderDomainError = ItemLimitExceededError | DuplicateItemError


def add_item(order: DraftOrder, item: OrderItem) -> DraftOrder | OrderDomainError:
    if len(order.items) >= MAX_ITEMS:
        return ItemLimitExceededError(limit=MAX_ITEMS, actual=len(order.items) + 1)
    if any(existing.sku == item.sku for existing in order.items):
        return DuplicateItemError(sku=item.sku)
    return replace(order, items=(*order.items, item))
```

In `infra.py`, catch library exceptions (`httpx.HTTPError`, `sqlite3.Error`, `pydantic.ValidationError`)
immediately and return a typed infrastructure error value.

### 4. Structural Ports via `typing.Protocol` (No ABC Inheritance)

Define ports in `app.py` using `typing.Protocol` instead of `abc.ABC`. Adapters and test fakes
satisfy the port structurally (Go/TypeScript style) without inheritance coupling:

```python
from typing import Protocol


class OrderRepo(Protocol):
    def save(self, order: Order) -> None | RepoError: ...
    def find_by_id(self, order_id: OrderId) -> Order | None: ...
```

### 5. Async Only at IO Boundaries

- Keep all domain logic synchronous and pure.
- Use `asyncio.TaskGroup` for concurrent independent IO, then pass fetched data to synchronous
  pure functions.
- Never mutate local state across `await` points.

---

## Testing (`pytest` + `hypothesis`)

| Purpose     | Tool / Library              | Notes                                                            |
| ----------- | --------------------------- | ---------------------------------------------------------------- |
| Runner      | `pytest` (`moon run :test`) | Plain `assert` statements + function-scoped fixtures             |
| Property    | `hypothesis`                | `@given(...)` strategies for domain invariants & roundtrips      |
| Typecheck   | `basedpyright`              | Run via `moon run :typecheck` (`uv run --frozen basedpyright`)   |
| Fast / Slow | `-m "not slow"`             | Mark heavy Hypothesis/integration tests with `@pytest.mark.slow` |

- **No `unittest.TestCase` classes**: write tests as plain `def test_<unit>_<behavior>()` functions.
- **In-memory fakes over `unittest.mock`**: implement `OrderRepo` `Protocol` with an in-memory
  dict fake; reserve `monkeypatch` for the four allowed mocking cases in [Testing](testing.md).

## Anti-Patterns

| Smell                                 | Problem                                | Instead                                    |
| ------------------------------------- | -------------------------------------- | ------------------------------------------ |
| Stateful classes with business logic  | Fails `PLR0904` (`max-public-methods`) | `@dataclass(frozen=True, slots=True)` + fn |
| `list` / `dict` fields on dataclasses | Mutates behind frozen reference        | `tuple[T, ...]` / `MappingProxyType`       |
| Raising exceptions for domain errors  | Invisible control flow in signature    | Return union `T \| DomainError`            |
| Nested `if`/`match` inside `for` loop | Fails `PLR1702` (`max-nested-blocks`)  | Extract pure helper + comprehension        |
| `abc.ABC` inheritance for ports       | Nominal coupling across layers         | `typing.Protocol` structural typing        |
| Pydantic `BaseModel` in `domain.py`   | Couples domain to wire serializer      | Keep Pydantic in `infra.py` DTOs           |
| `Any` in function signatures          | Fails `ANN401`                         | `NewType`, `TypedDict`, generics, or union |

## Checklist

- [ ] Toolchain-enforced: `configs/python` applied (`ruff.toml` extended, `basedpyright` in dev deps)
- [ ] Zero public methods on domain/data classes (`PLR0904`, `PLR6301`)
- [ ] Every function has explicit parameter and return type annotations (`ANN`, zero `Any`)
- [ ] Functions ≤ 30 statements, ≤ 4 parameters, cyclomatic complexity ≤ 8, nesting depth ≤ 2
- [ ] Zero `else` after `return` / `raise` (`RET505`–`RET508`); zero boolean flag params (`FBT`)
- [ ] Advisory: feature-based module layout (`domain.py`, `app.py`, `infra.py`)
- [ ] Advisory: `@dataclass(frozen=True, slots=True)` with `tuple` collections for domain data
- [ ] Advisory: module-level pure functions for domain logic; `typing.Protocol` for ports
- [ ] Advisory: union types + exhaustive `match`/`case` with `assert_never`
- [ ] Advisory: expected errors returned as values; `try`/`except` restricted to `infra.py`
