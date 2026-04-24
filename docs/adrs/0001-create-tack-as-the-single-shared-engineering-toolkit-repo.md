---
number: 1
title: Create tack as the single shared engineering toolkit repo
date: 2026-04-17
status: proposed
---

# 1. Create tack as the single shared engineering toolkit repo

Date: 2026-04-17

## Status

Proposed

## Context

Shared engineering assets (GitHub Actions, reusable workflows, tool configs, moon task definitions, code-pattern standards, and policy-as-code) are currently scattered across individual project repos, primarily in astro-bay. This duplication leads to drift, inconsistent CI behavior across repos, and no single place to update shared conventions.

Multiple orgs (tomdavidson, td7x, and potentially others) need to consume the same shared assets. A future Forgejo self-hosted instance will need comparable automation alongside GitHub.

## Decision

Create `tomdavidson/tack` as the single canonical repository for all shared engineering standards, tool configurations, moon workspace patterns, and forge-specific automation.

The name "tack" references equestrian tack: a curated, purposeful kit of equipment used together to outfit a horse for work. Each piece has a specific job, but together they form a coherent system.

### Key properties

- **Single source of truth.** All shared engineering assets live in tack, not scattered across app repos.
- **Cross-org consumption.** Consuming orgs (td7x, etc.) add `tomdavidson/tack/*` to their GitHub Actions allow-list. If tack is public, no allow-list is needed.
- **Forge-agnostic at the top level.** GitHub-specific material lives under `gh/`; a future Forgejo equivalent will live under `forgejo/`. The top-level structure does not assume any single forge.
- **Self-hosting (dogfooding).** tack itself is a moon workspace that consumes its own exported configs, moon task definitions, and reusable workflows for its own CI. Any change to shared assets is validated against tack before consumers pick it up.
- **Versioned via tags.** Consumers pin to `@v1`, `@v2`, etc. A single tag covers the entire catalog; per-action independent versioning is deferred unless action evolution rates diverge significantly.

### What belongs in tack

- Human and LLM-consumable engineering standards (code patterns, conventions)
- Machine-consumable tool configuration presets (dprint, oxlint, eslint, tsconfig, gitleaks, actlint, editorconfig, gitignore, gitattributes)
- Shared moon workspace configuration (tasks, toolchains, workspace defaults, templates)
- Forge-specific composite actions, reusable workflows, starter workflow templates, and policy examples
- Bootstrap and sync scripts
- Documentation for adoption, versioning, and conventions

### What does not belong in tack

- Standalone CLIs (e.g., actlint) that have their own release cadence, CI, and packaging. tack integrates these via wrapper actions and config presets.
- Application code or libraries.
- Per-repo configurations (tack provides presets; each repo owns its local config).
- Secrets, tokens, or environment-specific values.
- Experimental or unstable actions (these should graduate into tack after stabilization).

## Consequences

- Every new project bootstraps from tack rather than copying CI and config from an existing repo.
- Shared config updates propagate deliberately: consumers bump their tag pin.
- tack's own CI catches regressions in shared assets before any consumer is affected.
- A single repo issue tracker and CODEOWNERS file governs all shared engineering assets.
- If tack grows too large or concerns diverge, splitting is possible by extracting subtrees into new repos and updating consumer refs. The cost is proportional to the number of consumers.
