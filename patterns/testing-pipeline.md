# Pipeline Testing - draft

Scope: after `git push`. Complements [Testing](testing.md) (local development).

Local tests verify correctness. Pipeline tests verify safety, compatibility, and deployability.

---

## Stage Gates

| Stage | Timing | Budget | Blocks |
|-------|--------|--------|--------|
| Pre-push (local) | Before commit | 30s | Push |
| Pre-merge (CI) | On PR | 10min | Merge |
| Post-deploy | After release to staging/prod | 5min | Rollback |

Pre-push runs locally. Pre-merge runs in CI on every PR. Post-deploy runs against live environment.

---

## Pre-merge CI

Runs on every PR. Must pass before merge.

| Test Type | What Runs |
|-----------|-----------|
| Unit | All |
| Integration | Full suite with testcontainers |
| Property | All |
| Contract | Consumer publish, provider verify |
| SAST | Every commit |
| SCA | Every commit |
| Secrets scan | Every commit |
| Container scan | On image build |
| Fuzz | Scheduled (not every PR) |

Target: 10 minutes max. Parallelize test suites. Cache dependencies aggressively.

---

## Post-deploy

Runs against staging after deployment. Minimal scope—verify deployment health, not correctness.

| Test Type | What Runs |
|-----------|-----------|
| Smoke | 1-2 critical paths only |
| DAST | Full scan against running app |
| Synthetic monitoring | Health checks, latency baselines |
| Performance | Baseline comparison |

Smoke tests answer: "Did the deployment succeed?" Not: "Does the feature work?"

---

## Security Scanning

### SAST (Static Application Security Testing)

Scans source code for vulnerabilities before execution.

| Detects | Stage | Blocks On |
|---------|-------|-----------|
| SQL injection | Pre-merge | High/Critical |
| Hardcoded credentials | Pre-merge | Any finding |
| Buffer overflows | Pre-merge | High/Critical |
| Insecure deserialization | Pre-merge | High/Critical |

Tools: Semgrep, CodeQL, Snyk Code, SonarQube

Run on every commit. High/Critical findings block merge.

### SCA (Software Composition Analysis)

Scans dependencies for known vulnerabilities and license issues.

| Detects | Stage | Blocks On |
|---------|-------|-----------|
| Known CVEs | Pre-merge | High/Critical or CVSS ≥ 7.0 |
| Outdated libraries | Pre-merge | Advisory |
| License conflicts | Pre-merge | Policy violation |
| Transitive vulnerabilities | Pre-merge | High/Critical |

Tools: Snyk, Dependabot, Trivy, Grype

Run on every commit. Block on High/Critical CVEs. Track license compliance (GPL in proprietary = block).

### Secrets Detection

Scans commits for leaked credentials.

| Detects | Stage | Blocks On |
|---------|-------|-----------|
| API keys | Pre-merge | Any finding |
| Passwords | Pre-merge | Any finding |
| Private keys | Pre-merge | Any finding |
| Connection strings | Pre-merge | Any finding |

Tools: Gitleaks, TruffleHog, detect-secrets

Run on every commit. Any finding blocks merge. No exceptions.

### Container Scanning

Scans container images for vulnerabilities before deployment.

| Detects | Stage | Blocks On |
|---------|-------|-----------|
| Base image CVEs | Pre-deploy | High/Critical |
| Misconfigurations | Pre-deploy | High/Critical |
| Embedded secrets | Pre-deploy | Any finding |

Tools: Trivy, Grype, Snyk Container

Scan after image build, before push to registry. Use minimal base images (distroless, alpine).

### DAST (Dynamic Application Security Testing)

Scans running application for runtime vulnerabilities.

| Detects | Stage | Blocks On |
|---------|-------|-----------|
| XSS | Post-deploy | High/Critical |
| Authentication bypass | Post-deploy | High/Critical |
| Session hijacking | Post-deploy | High/Critical |
| Injection flaws | Post-deploy | High/Critical |

Tools: OWASP ZAP, Burp Suite, Nuclei

Run post-deploy against staging. Requires running application with authentication configured.

ZAP automation example:
```
# zap-config.yaml
env:
  contexts:
    - name: "app"
      urls: ["https://staging.example.com"]
      authentication:
        method: "form"
        parameters:
          loginUrl: "https://staging.example.com/login"
          loginRequestBody: "username={%username%}&password={%password%}"
jobs:
  - type: spider
    parameters:
      maxDuration: 5
  - type: activeScan
    parameters:
      policy: "API-Scan"
```

---

## Contract Testing (Pact)

For service boundaries where you own both sides or have provider cooperation.

### Workflow

```
Consumer CI:
  1. Run consumer tests (generates pact file)
  2. Publish pact to broker
  3. can-i-deploy --to staging
  4. Deploy if green

Provider CI:
  1. Fetch pacts from broker (for this provider)
  2. Run provider verification
  3. Publish verification results
  4. can-i-deploy --to staging
  5. Deploy if green

Webhook (on new pact published):
  → Trigger provider verification
  → Results published to broker
```

### can-i-deploy

The critical gate. Queries the Pact Broker matrix to determine if versions are compatible.

```
# Before deploying consumer
pact-broker can-i-deploy \
  --pacticipant order-service \
  --version $(git rev-parse HEAD) \
  --to staging

# Before deploying provider
pact-broker can-i-deploy \
  --pacticipant inventory-api \
  --version $(git rev-parse HEAD) \
  --to staging
```

Exit 0 = safe to deploy. Exit 1 = incompatible versions exist.

### Version Tagging

Tag versions after successful deployment:

```
pact-broker create-version-tag \
  --pacticipant order-service \
  --version $(git rev-parse HEAD) \
  --tag staging
```

Tags enable `can-i-deploy --to <environment>` queries.

### When You Don't Own Both Sides

| Scenario | Approach |
|----------|----------|
| Internal service, you own both | Full Pact workflow |
| Internal service, other team owns provider | Publish pact, coordinate on verification |
| External API | No Pact—use adapter + typed fake (from testing.md) |
| Provider publishes OpenAPI | Bi-directional contracts (PactFlow) |

Bi-directional: Consumer publishes pact, provider publishes OpenAPI spec. PactFlow compares without running provider tests.

### Broker Setup

Self-hosted: Pact Broker (Docker)
Managed: PactFlow (SaaS)

Broker stores:
- Pact files (consumer expectations)
- Verification results (provider confirmations)
- Version matrix (what works with what)
- Environment tags (what's deployed where)

---

## Fuzz Testing

Targets parsers, deserializers, validators, and protocol handlers with random/malformed input.

### Scheduling

| Approach | When | Why |
|----------|------|-----|
| Scheduled | Nightly or weekly | Long-running, finds deep bugs |
| Per-commit | Never | Too slow, diminishing returns |
| On change | When parser/handler code changes | Targeted coverage |

Fuzz runs are expensive. Schedule during low-activity periods.

### Corpus Management

```
corpus/
├── seed/           # Valid inputs (manually curated)
├── generated/      # Fuzzer-discovered inputs (auto)
└── crashes/        # Inputs that caused failures (auto)
```

Seed corpus: Start with valid examples from tests, real requests, API specs.
Generated corpus: Fuzzer mutates seeds, keeps interesting inputs.
Crash corpus: Inputs that triggered bugs—become regression tests.

### Crash Triage Workflow

```
1. Fuzzer finds crash → input saved to crashes/
2. CI creates issue with reproduction steps
3. Developer minimizes input (most fuzzers have minimize command)
4. Fix bug
5. Add minimized input to regression test suite
6. Input remains in corpus forever
```

Crashes become permanent test cases. Fuzz coverage only grows.

### Targets

Prioritize entry points:
- JSON/XML/YAML parsers
- Protocol decoders (HTTP, gRPC, WebSocket)
- File format handlers
- User input validators
- Query parsers

Don't fuzz:
- Pure business logic (use property tests)
- Database queries (use integration tests)
- External APIs (use contract tests)

---

## Environment Strategy

### Ephemeral Environments

Spin up per PR. Destroy after merge or close.

| Property | Ephemeral | Long-lived Staging |
|----------|-----------|-------------------|
| Configuration drift | None | Accumulates |
| Data freshness | Always clean | Stale, polluted |
| Resource contention | None | Queue for deploys |
| Cost | Pay per use | Always running |
| Reproducibility | High | Low |

Implementation:
```
# On PR open/update
- provision infrastructure (terraform/pulumi)
- deploy application
- run integration/smoke tests
- post environment URL to PR

# On PR merge/close
- destroy infrastructure
```

Tools: Qovery, Vercel Preview, Kubernetes namespaces, Terraform workspaces

### Data Seeding

| Approach | Use Case | Tradeoffs |
|----------|----------|-----------|
| Empty + builders | Unit/integration tests | Fast, deterministic |
| Synthetic generation | Load testing, fuzzing | Realistic scale, no PII risk |
| Anonymized production | Staging smoke tests | Real edge cases, compliance overhead |

Never use production data without anonymization. Each test environment owns its data—no shared seeds across PRs.

### Why Not Long-lived Staging

Problems:
- **Configuration drift**: Staging diverges from production over time
- **Data pollution**: Tests leave behind garbage, affecting other tests
- **Deployment queues**: Teams wait to deploy, blocking each other
- **"Works in staging"**: False confidence—staging ≠ production
- **Flaky tests**: Shared state causes non-deterministic failures

Long-lived staging is acceptable only for:
- DAST scans (needs stable target)
- Performance baselines (needs consistent environment)
- Manual QA (if unavoidable)

Even then, reset data regularly. Never rely on staging state.

---

## Performance Testing

### Baselines, Not Absolutes

Bad: "Response time must be < 200ms"
Good: "Response time must not regress > 10% from baseline"

Baselines account for infrastructure variance. Absolute thresholds cause false positives.

### When to Run

| Type | Stage | Frequency |
|------|-------|-----------|
| Micro-benchmarks | Pre-merge | On perf-critical code changes |
| Load tests | Post-deploy staging | Every release |
| Stress tests | Scheduled | Weekly/monthly |
| Soak tests | Scheduled | Weekly |

Never run load tests against production. Use staging with production-like data volumes.

### What to Measure

| Metric | Baseline Source | Alert Threshold |
|--------|-----------------|-----------------|
| p50 latency | Last N releases | > 10% regression |
| p99 latency | Last N releases | > 20% regression |
| Throughput (RPS) | Last N releases | > 10% regression |
| Error rate | Last N releases | > 1% increase |
| Memory usage | Last N releases | > 20% increase |

Track trends over releases. Single-run variance is noise.

### Data Volumes

Test with realistic data:
- Production-scale row counts (anonymized)
- Representative query patterns
- Realistic payload sizes

Synthetic data that doesn't match production distribution gives false confidence.

---

## Observability Gates

Post-deploy checks that validate deployment health.

### Synthetic Monitoring

Automated checks simulating user behavior:
```
- Health endpoint returns 200
- Login flow completes
- Critical API responds within SLA
- Database connectivity OK
```

Run every 1-5 minutes. Alert on failure. Trigger rollback on sustained failure.

### Canary Metrics

Compare new version metrics against baseline:
```
- Error rate (new vs old)
- Latency percentiles (new vs old)
- Resource utilization (new vs old)
```

Automatic rollback if new version performs worse. Requires traffic splitting (canary deployment).

### Rollback Triggers

| Signal | Action |
|--------|--------|
| Error rate > 5% | Automatic rollback |
| p99 latency > 2x baseline | Automatic rollback |
| Health check failures > 3 | Automatic rollback |
| DAST critical finding | Manual review, block promotion |

Rollback should be automated and fast. If rollback is scary, deployments will be scary.

---

## Anti-Patterns

| Anti-Pattern | Why It Fails | Instead |
|--------------|--------------|---------|
| Long-lived staging | Config drift, stale data, "works in staging" | Ephemeral per-PR environments |
| E2E-heavy pipelines | Slow, flaky, duplicates unit/contract coverage | 1-2 smoke tests post-deploy only |
| Retry-until-pass | Masks flakiness, false confidence | Quarantine + fix root cause |
| Shared test databases | Test pollution, ordering dependencies | Each test owns its data |
| Manual security gates | Slows releases, human error | Policy-as-code, automated enforcement |
| DAST in pre-merge | Slow, needs running app | DAST post-deploy only |
| Fuzz every commit | Too slow, diminishing returns | Scheduled or on-change |
| Absolute perf thresholds | False positives from infra variance | Baseline comparison |
| Skip can-i-deploy | Deploy incompatible versions | Always gate on can-i-deploy |
| Secrets in test fixtures | Leak risk, rotation pain | Generate ephemeral credentials |
| Test against production | Risk, compliance, data pollution | Staging with anonymized data |

---

## Pipeline Failure Response

| Failure Type | Response | Timeline |
|--------------|----------|----------|
| Unit/Integration test | Fix or revert | Block merge |
| SAST High/Critical | Fix finding | Block merge |
| SCA High/Critical | Update dependency or accept risk | Block merge |
| Secrets detected | Rotate immediately, fix code | Block merge, rotate now |
| Contract verification | Coordinate with provider/consumer | Block merge |
| DAST High/Critical | Assess exploitability, fix or mitigate | Block promotion |
| Smoke test failure | Rollback, investigate | Immediate |
| Performance regression | Assess impact, fix or accept | Block promotion |

Never skip. Never "fix later." Pipeline failures are deployment blockers.

---

## Checklist

Pre-merge CI:
- [ ] All unit tests pass
- [ ] All integration tests pass (testcontainers)
- [ ] All property tests pass
- [ ] Contract tests: consumer pact published
- [ ] Contract tests: provider verification green
- [ ] can-i-deploy returns success
- [ ] SAST: no High/Critical findings
- [ ] SCA: no High/Critical CVEs
- [ ] Secrets scan: no findings
- [ ] Container scan: no High/Critical findings

Post-deploy:
- [ ] Smoke tests pass (critical paths only)
- [ ] DAST scan complete, no High/Critical
- [ ] Synthetic monitoring healthy
- [ ] Performance within baseline tolerance
- [ ] Version tagged in Pact Broker

Environment:
- [ ] Ephemeral environments for PRs
- [ ] No long-lived staging dependencies
- [ ] Each test owns its data
- [ ] No production data without anonymization

Security:
- [ ] SAST every commit
- [ ] SCA every commit
- [ ] Secrets scan every commit
- [ ] Container scan before deploy
- [ ] DAST post-deploy
- [ ] High/Critical findings block release

Contracts:
- [ ] Consumer publishes pact on change
- [ ] Provider verifies on pact webhook
- [ ] can-i-deploy gates all deployments
- [ ] Versions tagged after deploy