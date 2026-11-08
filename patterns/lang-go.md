# Go Patterns

> Go-specific implementation choices for [Tom's Clean Code](toms-clean-code.md). Specifies the
> preferred approach when Go allows several. Go has no sum types, no generics-era `Result`, and
> no `readonly`; this guide names the idiom that stands in for each and what enforces it.

## Strategic FP Philosophy

Go already leans the right way: plain structs, free functions, errors as return values, no
inheritance. What it lacks is the compiler support Rust and TypeScript give the same ideas, so
more of this guide is lint-enforced convention than language feature.

- **Data and behavior are separate**: structs are data; package-level functions are behavior.
  Methods exist for interface satisfaction and trivial accessors, not for logic.
- **Sum types by sealed interface**: an unexported marker method plus `exhaustive` on the type
  switch is the Go spelling of a discriminated union.
- **Errors are values**: `(T, error)` is the `Result`. Typed errors, `errors.Is`/`errors.As`,
  wrapping with `%w`. `panic` is never an error strategy.
- **Zero nested branches in loops**: guard clauses, early `return`/`continue`, and per-element
  helpers. Go has no iterator pipeline worth the name; the discipline is on the loop body.

Rules are split into **Toolchain-Enforced** (`configs/go/golangci.yml`, read through `.tack`) and
**Advisory** (review and package-boundary rules until a linter covers them).

---

## Part 1: Toolchain-Enforced Rules

### 1. Function Size, Complexity, and Flat Control Flow

| Linter / Rule                                                  | Setting | Purpose                                                                 |
| -------------------------------------------------------------- | ------- | ----------------------------------------------------------------------- |
| `gocognit.min-complexity`                                      | `8`     | The lintable proxy for "one idea"                                       |
| `cyclop.max-complexity`                                        | `10`    | Cyclomatic backstop                                                     |
| `nestif.min-complexity`                                        | `2`     | No nested `if` chains; guard clauses instead                            |
| `revive max-control-nesting`                                   | `2`     | Nesting depth across `if`/`for`/`switch`/`select`                       |
| `funlen.lines`                                                 | `60`    | Fits on one screen; comments excluded; aim for about 30                 |
| `revive argument-limit`                                        | `3`     | 4+ parameters become an input struct                                    |
| `revive flag-parameter`                                        | on      | No boolean parameters that switch behavior; two functions or a type     |
| `revive early-return`, `superfluous-else`, `indent-error-flow` | on      | Never `else` after `return`; error path indented, happy path flush left |

```go
// GOOD: guard clauses, zero nesting, happy path flush left
func ValidateOrder(repo OrderRepo, id OrderID) (Order, error) {
	order, found := repo.FindByID(id)
	if !found {
		return Order{}, OrderNotFoundError{ID: id}
	}
	if order.Status != StatusDraft {
		return Order{}, OrderNotEditableError{Status: order.Status}
	}
	if len(order.Items) == 0 {
		return Order{}, ErrEmptyOrder
	}
	return order, nil
}
```

Never put an `if`/`switch` inside a `for` body that does anything but `continue` or `return`.
Extract the per-element decision into a named function and call it from a flat loop.

### 2. Explicit Errors as Data

| Linter                                              | Rule                                                                            |
| --------------------------------------------------- | ------------------------------------------------------------------------------- |
| `errcheck` (`check-blank`, `check-type-assertions`) | Every `error` and every `v, ok :=` assertion is handled; `_ =` needs a comment  |
| `errorlint`                                         | Compare with `errors.Is`/`errors.As`, wrap with `%w`, never `==` or type-assert |
| `errname`                                           | Sentinels are `ErrXxx`; types are `XxxError`                                    |
| `nilerr`                                            | Never `return nil` when `err != nil`                                            |
| `nilnil`                                            | Never `return nil, nil`; absence is a typed zero value or a `found bool`        |
| `revive error-strings`                              | Messages are lowercase, no trailing punctuation                                 |
| `revive unhandled-error`                            | Package-level calls that return `error` are not dropped                         |

- Domain and app packages define their own error types in the package that produces them: a
  sentinel (`var ErrEmptyOrder = errors.New("order has no items")`) when there is nothing to
  carry, a struct type (`type OrderNotFoundError struct{ ID OrderID }`) when there is.
- Wrap on the way out of a layer (`fmt.Errorf("placing order: %w", err)`); match on the way in
  (`errors.As(err, &notFound)`). The caller never string-matches.
- `panic` only in `main` for unrecoverable startup failures and in `init`-time invariants that
  cannot be expressed as types. A `recover` is an infra-only tool for turning a third-party panic
  into an `error` at the boundary.
- Infallible functions return the value alone. Do not return `(T, error)` when `error` is always
  `nil`.

```go
// GOOD: typed error, wrapped on exit, matched on entry
func PlaceOrder(repo OrderRepo, cmd PlaceOrderCmd) (OrderID, error) {
	order, err := NewOrder(cmd)
	if err != nil {
		return OrderID{}, fmt.Errorf("placing order: %w", err)
	}
	if err := repo.Save(order); err != nil {
		return OrderID{}, fmt.Errorf("placing order: %w", err)
	}
	return order.ID, nil
}
```

### 3. Sum Types and Exhaustiveness

Go has no `enum`. Two spellings, both covered by `exhaustive`
(`default-signifies-exhaustive: false`, so a `default:` arm does not excuse missing cases):

**Closed set of tags** (status, kind): a typed constant set.

```go
type OrderStatus int

const (
	StatusDraft OrderStatus = iota
	StatusSubmitted
	StatusCancelled
)

func canEdit(s OrderStatus) bool {
	switch s { // exhaustive: adding a status fails lint here
	case StatusDraft:
		return true
	case StatusSubmitted, StatusCancelled:
		return false
	}
	return false // unreachable; satisfies the compiler
}
```

**Variants carrying different data**: a sealed interface. The unexported marker method means
only this package can add variants, and `exhaustive` checks the type switch.

```go
type PaymentMethod interface{ isPaymentMethod() }

type CardPayment struct{ Last4 string }
type InvoicePayment struct{ DueDate time.Time }

func (CardPayment) isPaymentMethod()    {}
func (InvoicePayment) isPaymentMethod() {}

func describe(m PaymentMethod) string {
	switch v := m.(type) {
	case CardPayment:
		return "card ending " + v.Last4
	case InvoicePayment:
		return "invoice due " + v.DueDate.Format(time.DateOnly)
	}
	return "" // unreachable
}
```

No boolean flag fields where a third state is plausible. No `interface{}`/`any` as a poor man's
union.

### 4. Imperative Shell Hygiene

| Linter                                                 | Rule                                                                    |
| ------------------------------------------------------ | ----------------------------------------------------------------------- |
| `bodyclose`, `rowserrcheck`, `sqlclosecheck`           | Every `http.Response.Body`, `sql.Rows`, and statement is closed         |
| `noctx`, `contextcheck`                                | Outbound calls take a `context.Context` and pass it through             |
| `revive context-as-argument`                           | `ctx` is the first parameter                                            |
| `gosec`                                                | No shell injection, weak crypto, or unchecked file paths                |
| `mnd`                                                  | No magic numbers; `0`, `1`, `-1` inline; tests excepted                 |
| `misspell`, `unconvert`, `wastedassign`, `ineffassign` | Dead and sloppy code                                                    |
| `gocritic` (`diagnostic`, `style`)                     | `ifElseChain` → `switch`, `nestingReduce`, `unnamedResult`, and friends |

### 5. Domain Purity (`depguard`)

Packages under `**/domain/**` or files named `*_domain.go` may not import `net/http`,
`database/sql`, `os`, `encoding/json`, `encoding/xml`, or YAML. Wire formats live in codec
files (below); IO lives in infra. The lint message names the destination.

### 6. Naming

Casing is `gofmt` and `revive var-naming`. [Tom's Clean Code](toms-clean-code.md#naming)
governs the words; [Effective Go](https://go.dev/doc/effective_go#names) and the
[Go Code Review Comments](https://go.dev/wiki/CodeReviewComments) override where they conflict,
because every Go reader expects them.

| Element                       | Convention                                                            | Example                               |
| ----------------------------- | --------------------------------------------------------------------- | ------------------------------------- |
| Exported identifiers          | `PascalCase`                                                          | `PlaceOrder`, `OrderRepo`             |
| Unexported identifiers        | `camelCase`                                                           | `canEdit`, `orderRepo`                |
| Acronyms inside identifiers   | **All caps**, the Go exception (`revive var-naming`)                  | `userID`, `HTTPClient`, `parseJSON`   |
| Packages                      | Single lowercase word, no underscores, no `util`/`common`/`helpers`   | `orders`, `pricing`                   |
| Constants                     | `PascalCase`/`camelCase` by visibility, never `SCREAMING_SNAKE`       | `MaxRetryCount`, `defaultTimeout`     |
| Sentinel errors / error types | `ErrXxx` / `XxxError` (`errname`)                                     | `ErrEmptyOrder`, `OrderNotFoundError` |
| Interfaces                    | Single-method: `-er` noun; multi-method: role noun                    | `Saver`, `OrderRepo`                  |
| Receivers                     | One or two letters, consistent per type (`receiver-naming`)           | `func (o Order) Total()`              |
| Unused bindings               | `_`                                                                   | `_, err := ...`                       |
| Type parameters               | Single capital for one unconstrained parameter; descriptive otherwise | `T`, `Item`                           |

- **No `Get` prefix on accessors**: `order.ID()`, not `order.GetID()`. Setters, if a framework
  forces them, are `SetX`.
- **No stutter**: `orders.Repo`, not `orders.OrderRepo`, when the package name already says it.
- **Predicates**: `Is`, `Has`, `Can` return `bool`.
- **Fallible**: `Parse*` returns `(T, error)`; `Find*` returns `(T, bool)`; `Get*` returns `T`
  and cannot fail.
- **Foreign names are data** ([principle](toms-clean-code.md#domain-and-context)): a header name
  is a `const ThreadIDHeader = "Thread-ID"`, never a struct field. Vendor payload keys appear
  only in struct tags inside `*_codec.go` (Part 2 §2); the Go field beside the tag is a domain
  name.
- **Fixtures** ([principle](toms-clean-code.md#variables-and-constants)): `thread`,
  `expiredThread`, `makeThread(overrides)`. `revive var-naming` still runs in tests, so
  single-letter fixtures are caught.

### 7. Formatting (`gofmt` via `dprint.json`)

`moon run :fmt` runs `dprint`, which delegates Go files to `gofmt` through `dprint-go.json`.
Tabs, no line-width limit (gofmt has none; keep expressions short by extracting names), import
groups `std` / third-party / module in that order (`goimports` ordering).

---

## Part 2: Advisory Patterns (Architecture & Code Review)

> Enforced in review until a linter covers them. `depguard` and package visibility carry part
> of the load; the rest is convention.

### 1. Package Structure

Go packages are directories, so layers are packages and the import direction is checked by the
compiler as soon as you make it a cycle, and by `depguard` for the IO bans.

```text
internal/
├── orders/
│   ├── domain/        // types, sealed interfaces, invariants, pure logic
│   │   ├── order.go
│   │   └── errors.go
│   ├── app/           // use cases, port interfaces (OrderRepo), orchestration
│   │   └── place_order.go
│   └── infra/         // adapters: HTTP handlers, SQL repos, clients, codecs
│       ├── postgres_repo.go
│       ├── http_handler.go
│       └── order_codec.go
├── inventory/
│   └── ...
cmd/
└── api/
    └── main.go        // composition root: wire deps, start runtime
```

- `domain` imports the standard library minus IO and nothing from `app`/`infra`. `app` imports
  `domain`. `infra` imports both. `cmd/*/main.go` imports everything and wires it.
- Port interfaces are declared in `app` where they are consumed, not in `infra` where they are
  implemented. Go interfaces are structural; the implementation never names the interface.
- Small features start as one package (`internal/orders`) with `*_domain.go`, `*_app.go`,
  `*_infra.go` suffixes; `depguard` matches the suffix. Promote to subpackages at 5+ files per
  layer.
- `internal/` for everything not meant to be imported by another module.

### 2. Codecs: Wire Shapes Stay at the Edge

`*_codec.go` (in `infra`) is the only place a foreign shape appears. The struct mirrors the
payload through tags; the field names are ours; `fromWire`/`toWire` translate.

```go
// order_codec.go — infra
type orderWire struct {
	ThreadID string `json:"ThreadID"`
	Success  bool   `json:"success"`
	Items    []itemWire `json:"Items"`
}

func fromWire(w orderWire) (domain.Order, error) {
	if !w.Success {
		return domain.Order{}, ErrUpstreamRejected
	}
	id, err := domain.ParseOrderID(w.ThreadID)
	if err != nil {
		return domain.Order{}, fmt.Errorf("decoding order: %w", err)
	}
	return domain.Order{ID: id, Items: itemsFromWire(w.Items)}, nil
}
```

The wire struct is unexported and never leaves the package. `encoding/json` is imported only
here; `depguard` rejects it anywhere under `domain`.

### 3. Free Functions Over Methods

- Domain and app logic are package-level functions taking and returning values:
  `func AddItem(o Order, item Item) (Order, error)`.
- Methods exist to satisfy interfaces (`Stringer`, ports), for trivial accessors on value
  objects, and when a framework demands a receiver. A method that does not use its receiver is
  a function.
- No struct embedding to simulate inheritance. Compose by holding a field and delegating
  explicitly.

### 4. Immutability by Convention

Go has no `readonly`. The discipline is on signatures:

- Value receivers and value parameters for domain types. Return a modified copy:
  `func Submit(o Order) Order { o.Status = StatusSubmitted; return o }`.
- Pointer receivers only in `infra` (connection handles, buffers) and for types too large to
  copy, documented at the type.
- Slices and maps are references; a function that receives one does not mutate it. Build new
  (`append([]Item(nil), o.Items...)`) before changing.
- `var mu sync.Mutex` guards only live in `infra`. Domain code is never concurrent.

### 5. Iteration

- `for range` with a flat body. The body either calls one function per element or does a guard
  (`if skip(x) { continue }`) followed by one action.
- `slices` and `maps` from the standard library (`slices.ContainsFunc`, `slices.IndexFunc`,
  `slices.SortFunc`) over hand-rolled loops when they say what the loop means.
- Iterator functions (`iter.Seq`) for lazy sequences; do not invent a `Map`/`Filter` library.
- Every `for {}` or retry carries a cap (`maxAttempts`) and returns a typed error when hit.
  `context.Context` deadlines bound IO; they do not excuse an unbounded loop.

### 6. Concurrency at the Boundary

- Goroutines start in `infra` and `main`. Domain and app code are synchronous and know nothing
  about channels.
- `errgroup.Group` for fan-out with error propagation; pass results into pure functions after
  `Wait()`.
- Channels are an infra detail. A port interface returns values, not channels.

### 7. Explicit Dependency Injection

Construct adapters in `main.go`, pass them as interface values to app functions or to a small
struct of ports (`type Deps struct { Orders OrderRepo; Clock Clock }`). No `wire`, no `fx`, no
global registries, no `init()` side effects.

---

## Testing (`go test` + `testing`)

- Table-driven tests with named cases; the case name is a sentence (`"empty order is rejected"`).
- `t.Run` per case, `t.Parallel()` where the case has no shared state.
- `testify` is not approved; the standard `testing` package plus `go-cmp` for diffs.
- Fakes over mocks: a hand-written `fakeOrderRepo` struct implementing the port. No code
  generation for test doubles.
- `_test.go` files are exempt from `funlen`, `gocognit`, `cyclop`, `nestif`, `mnd`, `errcheck`,
  and `gosec`. Naming rules still apply.

## Approved Libraries

| Status      | Library                                             | Use Case                              |
| ----------- | --------------------------------------------------- | ------------------------------------- |
| ✅ Approved | `golang.org/x/sync/errgroup`                        | Fan-out IO with error propagation     |
| ✅ Approved | `github.com/google/go-cmp`                          | Test diffs                            |
| ✅ Approved | `github.com/jackc/pgx`                              | Postgres                              |
| ✅ Approved | `log/slog`                                          | Structured logging (standard library) |
| ❌ Banned   | ORMs, `wire`, `fx`, `dig`, `testify/mock`, `logrus` |                                       |

Standard library first. Add a dependency only when it materially shortens the imperative shell.

## Anti-Patterns

- `interface{}`/`any` where a sealed interface or generic would do
- `panic`/`recover` as control flow
- `err != nil` checks that return `nil` (`nilerr`) or `nil, nil` (`nilnil`)
- Struct embedding for behavior reuse
- Global state and `init()` with side effects
- `GetX()` accessors, `IOrderRepo`, `OrderRepoImpl`
- Foreign names as Go identifiers outside `*_codec.go`
- `switch` with `default:` hiding a missing case

## Checklist

- [ ] Pure functions in `domain`/`app`; IO only in `infra` and `main`
- [ ] `(T, error)` everywhere fallible; typed errors, `%w`, `errors.Is`/`As`
- [ ] Sealed interfaces or typed constants for variants; `exhaustive` passes
- [ ] Guard clauses; nesting ≤ 2; no branches inside loop bodies beyond `continue`/`return`
- [ ] Cognitive ≤ 8, cyclomatic ≤ 10, ≤ 60 lines, ≤ 3 params
- [ ] Value semantics for domain types; no mutation of inputs
- [ ] `depguard` clean: no IO or wire-format imports under `domain`
- [ ] Foreign shapes only in `*_codec.go`; domain names on every field
- [ ] Acronyms all-caps (`userID`, `HTTPClient`); `revive var-naming` clean
- [ ] Loops and retries bounded; caps return typed errors
- [ ] Zero lint warnings; `//nolint:<linter> // reason` scoped to one line
