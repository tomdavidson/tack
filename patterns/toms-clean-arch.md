# Tom's Clean Architecture

Clean architecture that separates domain from infrastructure, built on DDD boundaries and dependency inversion.

DDD tells you *what* to model and where boundaries are. Clean Architecture tells you *how* to structure dependencies so the domain stays pure.

Error handling philosophy (errors as values, `Result<T, E>`, railway composition) is owned by [Tom's Clean Code](toms-clean-code.md). This document covers structural layering and boundaries.

Pragmatic over dogmatic. The goal is working systems, not architecture purity points.

## The One Rule

Dependencies point inward. Domain knows nothing about infrastructure. Infrastructure depends on domain via interfaces.

```
┌─────────────────────────────────────────┐
│           Infrastructure                │  ← Frameworks, DB, HTTP, queues
│  ┌───────────────────────────────────┐  │
│  │          Application              │  │  ← Use cases, orchestration
│  │  ┌─────────────────────────────┐  │  │
│  │  │          Domain             │  │  │  ← Entities, value objects, rules
│  │  └─────────────────────────────┘  │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

Violation test: "Would swapping Postgres for DynamoDB break this file?" If yes, it belongs further out.

## Strategic Design (Do First)

### Bounded Contexts

A semantic boundary where terms have one meaning. Each context owns its model and can evolve independently.

Same word can mean different things in different contexts (Order in Orders vs Billing vs Inventory). This is correct. Don't force a shared model.

Maps to: service boundary, team boundary, deployable unit.

### Ubiquitous Language

Shared vocabulary within one bounded context. Code identifiers use these terms exactly.

- Scope is ONE context, not global
- Domain experts and code use identical terms
- If term is ambiguous, you have two contexts

### Subdomain Types

| Type | Description | Investment |
|------|-------------|------------|
| Core | Competitive advantage, complex | High, model carefully |
| Supporting | Necessary, not differentiating | Medium, keep simple |
| Generic | Commodity (auth, email, payments) | Low, buy or copy |

Apply DDD tactical patterns in Core. Use simple CRUD elsewhere.

### Context Relationships

| Pattern | When |
|---------|------|
| Shared Kernel | Two contexts share subset of model |
| Customer-Supplier | Upstream serves downstream's needs |
| Conformist | Downstream adopts upstream's model as-is |
| Anti-Corruption Layer | Translate foreign models at boundary |

Default to ACL. Conformist when upstream is stable and well-designed.

## Tactical Design (Within Contexts)

### Domain Layer

Pure business logic. No frameworks, no IO, no annotations.

**Entity**: Has identity that persists through changes.

**Value Object**: Defined by attributes, immutable, interchangeable.

```
type Money = { amount: number; currency: Currency }
type Email = string & { readonly brand: unique symbol }

const addMoney = (a: Money, b: Money): Result<Money, CurrencyMismatch> =>
  a.currency === b.currency
    ? Ok({ amount: a.amount + b.amount, currency: a.currency })
    : Err("currency_mismatch")
```

Pure domain = trivial to test. No mocks, no setup. This is the payoff.

**Aggregate**: Consistency boundary. One root entity. Transactional unit.

```
type Order = {
  id: OrderId
  customerId: CustomerId        // reference by ID, not object
  items: OrderItem[]            // owned, loaded together
  status: OrderStatus
}

const addItem = (order: Order, item: OrderItem): Result<Order, OrderError> =>
  order.status.type === "draft"
    ? Ok({ ...order, items: [...order.items, item] })
    : Err("order_not_editable")
```

**Aggregate Rules**:
1. Protect invariants, always consistent after operation
2. Design small, root + minimal owned data
3. Reference other aggregates by ID only
4. Update other aggregates via domain events, not direct calls

**Domain Event**: Past-tense fact. Contains data that caused state change.

```
type OrderPlaced = { 
  type: "OrderPlaced"
  orderId: OrderId
  customerId: CustomerId
  items: OrderItem[]
  placedAt: Timestamp
}
```

Pattern: Command → Aggregate → State Change + Event

### Application Layer

Use cases. Orchestrates domain objects and infrastructure ports.

```
const placeOrder = (deps: OrderDeps) => async (cmd: PlaceOrderCommand) => {
  const order = createOrder(cmd)
  if (order.isErr()) return order

  const reserved = await deps.inventory.reserve(order.value.items)
  if (reserved.isErr()) return reserved

  await deps.orderRepo.save(order.value)
  await deps.events.publish({ type: "OrderPlaced", ...order.value })
  return Ok(order.value.id)
}
```

- Defines port interfaces (repos, external services)
- Contains no business rules, delegates to domain
- Coordinates transactions and event publishing

### Infrastructure Layer

Implements ports. All IO lives here.

```
// Port (defined in application layer)
type OrderRepository = {
  findById: (id: OrderId) => Promise<Option<Order>>
  save: (order: Order) => Promise<void>
}

// Adapter (lives in infrastructure)
const postgresOrderRepo = (db: Pool): OrderRepository => ({
  findById: async (id) => { /* SQL here */ },
  save: async (order) => { /* SQL here */ }
})
```

Frameworks, ORMs, HTTP handlers, queue consumers all live here. Thin as possible.

No DI containers. Wire dependencies explicitly in composition root.

## Boundary Crossing

Data crosses boundaries as simple types. No entity references, no ORM objects.

```
// Input DTO
type PlaceOrderRequest = { customerId: string; items: { sku: string; qty: number }[] }

// Output DTO  
type PlaceOrderResponse = { orderId: string } | { error: string }

// Controller (infrastructure)
const placeOrderHandler = (useCase: PlaceOrderUseCase) => async (req: Request) => {
  const cmd = parseCommand(req.body)       // DTO → Command
  const result = await useCase(cmd)
  return result.match({
    ok: (id) => ({ orderId: id }),          // Domain → DTO
    err: (e) => ({ error: e })
  })
}
```

## Error Propagation

Error handling philosophy (errors as values, `Result<T, E>`) is owned by [Tom's Clean Code](toms-clean-code.md). This section covers how errors cross layer boundaries.

Three layers, three error types, explicit mapping at each boundary.

### Domain Errors

Typed, exhaustive, business-language. No HTTP codes, no framework types.

```
type OrderError =
  | { type: "not_editable"; status: OrderStatus }
  | { type: "item_limit_exceeded"; max: number }
  | { type: "duplicate_item"; sku: string }
```

Domain functions return only domain errors. They describe what went wrong in domain terms.

### Application Errors

Union of domain errors plus orchestration failures (port failures, authorization). Still no HTTP or CLI concepts.

```
type PlaceOrderError =
  | OrderError
  | { type: "inventory_unavailable"; items: string[] }
  | { type: "repo_failure"; cause: string }
  | { type: "not_authorized" }
```

Use cases return `Result<T, PlaceOrderError>`. Domain errors pass through or get included in the union.

### Infrastructure Mapping

The outermost shell maps application errors to transport-specific responses. This is the only place HTTP codes, CLI exit codes, or gRPC status codes appear.

```
// HTTP adapter
const toHttpStatus = (error: PlaceOrderError): number => {
  const map: Record<PlaceOrderError["type"], number> = {
    not_editable: 409,
    item_limit_exceeded: 422,
    duplicate_item: 422,
    inventory_unavailable: 503,
    repo_failure: 500,
    not_authorized: 403,
  } as const
  return map[error.type]
}

// CLI adapter
const toExitCode = (error: PlaceOrderError): number =>
  error.type === "not_authorized" ? 77
  : error.type === "repo_failure" ? 1
  : 2
```

### Error Response Shape

All transports use a consistent body:

```
type ErrorResponse = {
  type: string
  message: string
  detail?: unknown
}
```

### Rules

- Domain errors never reference transport concepts (no HTTP status, no "400")
- Application errors are a union that includes domain errors, not a wrapper that hides them
- Mapping functions are exhaustive lookup tables (compiler catches missing variants)
- One mapping function per transport, co-located with that adapter
- Unknown/unexpected errors default to 500 / exit 1, logged with full context

### Rust Equivalent

Same pattern using `thiserror` enums. `impl From<DomainError> for AppError` handles the domain-to-application boundary. Infrastructure mappers use `match` (exhaustive by default).

```
// Domain
#[derive(Debug, thiserror::Error)]
enum OrderError {
    #[error("order not editable in status {0}")]
    NotEditable(OrderStatus),
    #[error("item limit exceeded: max {0}")]
    ItemLimitExceeded(usize),
    #[error("duplicate item: {0}")]
    DuplicateItem(String),
}

// Application
#[derive(Debug, thiserror::Error)]
enum PlaceOrderError {
    #[error(transparent)]
    Order(#[from] OrderError),
    #[error("inventory unavailable")]
    InventoryUnavailable(Vec<String>),
    #[error("repository failure: {0}")]
    RepoFailure(String),
    #[error("not authorized")]
    NotAuthorized,
}

// Infrastructure (HTTP)
impl PlaceOrderError {
    fn http_status(&self) -> u16 {
        match self {
            Self::Order(OrderError::NotEditable(_)) => 409,
            Self::Order(OrderError::ItemLimitExceeded(_)) => 422,
            Self::Order(OrderError::DuplicateItem(_)) => 422,
            Self::InventoryUnavailable(_) => 503,
            Self::RepoFailure(_) => 500,
            Self::NotAuthorized => 403,
        }
    }
}
```

### Anti-Patterns

| Smell | Problem |
|-------|---------|
| Domain error contains HTTP status | Dependency rule violation |
| `catch(e) { res.status(500) }` | Swallows error detail, no exhaustiveness |
| Stringly-typed errors | Loses compiler-checked exhaustiveness |
| Error mapping in middleware | Scattered, hard to audit |
| Wrapping domain errors in generic `AppError(String)` | Loses variant information |

## File Naming Convention

Layer identity is encoded in the file suffix. The suffix determines which lint rules apply (see oxlintrc.json and eslint.config.mjs).

| Suffix | Layer | Contains |
|--------|-------|----------|
| `.domain.ts` | Domain | Types, value objects, entities, invariants, pure functions |
| `.app.ts` | Application | Use cases, orchestration, port interfaces |
| `.infra.ts` | Infrastructure | Adapters, repos, IO, HTTP handlers, CLI |

Files without a layer suffix (e.g., `main.ts`, `shared/types.ts`) are not subject to layer-specific lint rules.

Test files use `.spec.ts`, which replaces the layer suffix. `money.domain.ts` is tested by `money.spec.ts`, not `money.domain.spec.ts`.

## Folder Structure

> "The architecture should scream the intent of the system, not the frameworks."

Organize by business capability. Layers live within features, identified by file suffix.

```
src/
├── orders/                        # ← what the system does
│   ├── types.domain.ts            # entities, value objects
│   ├── invariants.domain.ts       # business rules, validations
│   ├── pricing.app.ts             # use case: calculate pricing
│   ├── place-order.app.ts         # use case: place an order
│   ├── ports.app.ts               # port interfaces (repos, services)
│   ├── postgres.infra.ts          # adapter: Postgres repo
│   └── tests/
│       └── orders.spec.ts         # Layer 2: cross-module tests
├── inventory/
│   ├── stock.domain.ts
│   ├── reserve.app.ts
│   ├── ports.app.ts
│   └── dynamo.infra.ts
├── shared/
│   └── types.ts                   # cross-feature types (no layer suffix)
└── main.ts                        # composition root (no layer suffix)
```

Domain imports nothing. Application imports domain. Infrastructure imports both.

Composition root (`main.ts`): Wire all dependencies explicitly here. No framework magic. Construct and inject manually.

## Decision Heuristics

1. "Is this a business rule?" → Domain
2. "Is this orchestration of a user goal?" → Application
3. "Does this touch IO?" → Infrastructure
4. "What bounded context owns this?" → Determines which module
5. "Entity or value object?" → Identity matters vs attributes matter
6. "Immediate or eventual consistency?" → Same aggregate vs domain event

## Anti-Patterns

| Smell | Problem |
|-------|---------|
| Domain imports ORM | Dependency rule violation |
| Use case calls HTTP directly | Missing port abstraction |
| God aggregate | Won't scale, slow transactions |
| Cross-aggregate transaction | Hidden coupling, use events |
| Shared "common" model across contexts | Forced coupling, language collision |
| Logic in wrong layer | Anemic domain + fat controllers, keep rules in domain |
| File missing layer suffix | Lint rules won't enforce layer constraints |

## When to Break Rules

| Situation | Pragmatic Choice |
|-----------|------------------|
| Simple CRUD, no invariants | Skip aggregates, direct repo access |
| Single context, small team | Skip formal context mapping |
| Prototype / spike | Skip layers, refactor when validated |
| Performance critical path | Allow domain to know persistence shape |
| Generic subdomain | Use simple service + repo, no DDD |

Apply DDD depth proportional to domain complexity. CRUD doesn't need aggregates.

## Checklist

- [ ] Dependencies point inward only
- [ ] Domain has zero framework imports
- [ ] Bounded contexts identified and named
- [ ] Ubiquitous language terms in code match domain expert terms
- [ ] Aggregates are small, reference others by ID
- [ ] Cross-aggregate updates via events
- [ ] Use cases define port interfaces
- [ ] Infrastructure implements ports
- [ ] DTOs at boundaries, domain types inside
- [ ] Composition root wires explicitly, no DI containers
- [ ] Core subdomain gets DDD investment
- [ ] Generic/supporting subdomains kept simple
- [ ] Files use layer suffixes (`.domain.ts`, `.app.ts`, `.infra.ts`)
- [ ] Folder structure screams business intent
- [ ] Domain errors use typed discriminated unions, no transport concepts
- [ ] Application errors are a union that includes domain errors
- [ ] Error-to-transport mapping is exhaustive and co-located with adapter
