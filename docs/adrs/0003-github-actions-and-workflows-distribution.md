---
number: 3
title: GitHub Actions and workflows distribution
date: 2026-04-23
status: proposed
tags:
  - structure
  - distribution
  - github
---

# 3. GitHub Actions and workflows distribution

Date: 2026-04-23

## Status

Proposed

## Context

Tack distributes two classes of GitHub-specific assets: composite actions that consumers reference via `uses:`, and reusable workflows that live under `.github/workflows/`. Two properties of GitHub's runner and workflow resolver shape how these can be stored and referenced.

1. Composite actions can live at any path inside a repo. `.github/actions/` is a convention, not a requirement. The runner accepts `uses: owner/repo/<any/path>/<name>@<ref>` and `uses: ./<any/path>/<name>` as long as the resolved directory contains `action.yml`.

2. Reusable workflows must live at literal `.github/workflows/*.yml`. Subdirectories are not supported. GitHub does not resolve symbolic links in `.github/workflows/`; a symlink there causes the workflow resolver to fail immediately (community discussion 109744, open feature request as of early 2024).

An earlier draft of this ADR proposed a dual-distribution pattern: a top-level `github/` directory as the source of truth, a `configs/github/` shadow containing symlinks into it, and URL consumers pinning the short canonical path while submodule consumers resolved through the symlink. The goal was a shorter URL reference alongside the tack.sh dispatch path.

The dual-distribution pattern carried real cost: a rule that URL contracts must only pin canonical paths (the runner strips symlinks during archive extraction for `owner/repo@ref` references, per actions/runner and nektos/act maintainers), Windows consumers needing `core.symlinks=true`, and two paths per asset to document. The payoff was a URL shorter by one path segment. Not worth it.

This ADR records the simpler model: single distribution point for each GitHub asset class, and documents the GitHub-specific constraints that make that the right shape. Package naming follows ADR-0002's layout: the package is `configs/github/`, parallel to a future `configs/forgejo/` when other forges are added.

## Decision

All tack-distributed GitHub assets live at a single path under `configs/github/`. No shadow directories, no symlinks into a top-level sibling directory.

## Composite actions

- Source of truth: `configs/github/actions/<name>/action.yml`. This is the only copy in the repo.
- URL consumers reference: `uses: tomdavidson/tack/configs/github/actions/<name>@<ref>`.
- Submodule consumers reference: `uses: ./.tack/configs/github/actions/<name>`. The path is rooted at the consumer's repo root (`$GITHUB_WORKSPACE`), not relative to the workflow file.
- Submodule-mode consumers must check out the tack submodule on the runner. Their `actions/checkout` step needs `submodules: true` (or `recursive`). Without this, `.tack/` is an empty directory on the runner and `uses: ./.tack/...` fails to find `action.yml`.

## Reusable workflows

- Source of truth: `configs/github/workflows/*.yml.tera`. Authored as tera templates because the workflow YAML contains mode-aware reference strings that must be rendered per consumer.
- Distribution: tack.sh renders templates into the consumer's `.github/workflows/*.yml` during dispatch. Never symlinked. Reusable workflows cannot be symlinked: GitHub's workflow resolver does not follow symlinks in `.github/workflows/` (discussion 109744).
- Co-dev loop: a consumer who wants to edit a tack workflow edits the tera template at `.tack/configs/github/workflows/<name>.yml.tera` in the submodule, then re-runs `tack.sh` to re-render their `.github/workflows/`. One extra step compared to action co-dev, where filesystem edits in `.tack/` take effect immediately.

## Mode-aware action references in templates

The `uses:` value for a cross-repo action has the form `owner/repo/path@ref`, with `@ref` at the very end of the string. The reference must differ between URL mode (with `@ref`) and submodule mode (local path, no `@ref`). A single template has to render correctly in either mode based on the consumer's tackrc.yml.

An earlier version of this ADR proposed a tera custom function `tack_github_action(name=...)` that would return the complete `uses:` string for the current mode. This is not achievable with the tera CLI: tera's `register_function` is a library API taking a Rust closure; the standalone `tera` binary does not expose custom function registration. Zola, a Rust site generator that uses tera, has an open issue (2024) requesting this capability; the tera maintainer's response is that it is not possible in current tera and is being considered for a future version via Rhai or WASM. Switching template engines was considered and rejected: moon templates are tera, moon is a first-class tack package, and no handlebars CLI is distributed as a static binary the way tera-cli is.

The mechanism is therefore a pre-computed tera context dict, not a custom function. tack.sh performs the mode resolution in bash during the render pass and passes an `actions` lookup dict to tera.

```yaml
steps:
  - uses: actions/checkout@v4
    with:
      submodules: true
  - uses: {{ tack.actions["setup"] }}
  - uses: {{ tack.actions["conventional-pr"] }}
```

Context passed to tera in URL mode:

```yaml
tack:
  actions:
    setup: "tomdavidson/tack/configs/github/actions/setup@v1"
    conventional-pr: "tomdavidson/tack/configs/github/actions/conventional-pr@v1"
```

Context passed to tera in submodule mode:

```yaml
tack:
  actions:
    setup: "./.tack/configs/github/actions/setup"
    conventional-pr: "./.tack/configs/github/actions/conventional-pr"
```

tack.sh builds this dict by enumerating `configs/github/actions/*/` at render time, applying the mode from tackrc.yml, and adding each entry to the tera context. Template authors see one dict lookup per action reference; tack.sh owns the mode logic centrally.

The `tack.actions` key, and more generally the shape of tack.sh's tera context, is part of tack.sh's stable template-context API and must be versioned accordingly.

## Tack's own CI

Tack's own CI workflows live at tack's `.github/workflows/` and are not distributed. When tack's own CI exercises its own composite actions, workflows use `uses: ./configs/github/actions/<name>` (a repo-root-relative path inside tack itself). No template rendering involved.

## Checkout requirement: both ends of the contract

The `submodules: true` requirement is the consumer's responsibility to set on their `actions/checkout` step. Tack also ships workflow templates that include `submodules: true` on `actions/checkout` by default, so consumers who adopt tack's workflow templates get the correct configuration without additional work. Consumers authoring their own workflows from scratch must set it themselves.

## What this ADR does not cover

- Other forges (Forgejo, GitLab) will get their own distribution ADRs as they are added. Nothing here generalizes automatically; the constraints above are GitHub-specific.
- The URL-length concern that motivated the earlier dual-distribution draft. If future evidence shows URL length is a real problem, a superseding ADR can reintroduce a top-level distribution directory. Not now.

## Consequences

Positive:

- One source of truth per asset. No symlink gymnastics, no runner symlink-stripping exposure, no Windows symlink configuration issue.
- Mode switching between URL and submodule works for both actions and workflows via tera rendering. Submodule-mode consumers can co-dev actions by editing files in `.tack/` directly; filesystem edits take effect on the next CI run.
- Tack's layout stays flat: one top-level `configs/` directory holds all distributed assets, consistent with ADR-0002's consumption model.
- The render mechanism works with the stock tera CLI. No custom tera binary, no new language engine, no new dependency beyond what ADR-0002 already commits to.
- tack.sh owns mode logic centrally. Templates contain no conditional expressions; they just look up strings.

Negative:

- URL path is `tomdavidson/tack/configs/github/actions/<name>@<ref>` rather than a shorter alternative. Accepted. If this ever matters, it is a reversible decision.
- Reusable workflows cannot be co-developed via filesystem symlink. Consumers edit tera templates in `.tack/configs/github/workflows/` and re-run `tack.sh` to see changes in their `.github/workflows/`. One extra step versus action co-dev. Constraint comes from GitHub's workflow resolver, not from tack.
- Submodule-mode consumers must set `submodules: true` on `actions/checkout`. Documented in the consumer README and baked into tack-provided workflow templates. Consumers authoring workflows from scratch own this step.
- Workflow templates depend on tack.sh populating `tack.actions` in the tera render context. The context shape is part of tack.sh's stable template-context API and must be versioned accordingly.
- Every action referenced in a template must exist under `configs/github/actions/<name>/` at render time, or the dict lookup will render as empty and the workflow will fail in CI with a cryptic `uses:` error. tack.sh should surface a clear error when a template references an action name not present in the context.

Evidence:

- Composite actions can live outside `.github/`; path is arbitrary as long as `action.yml` exists there. GitHub community discussion 116540 and standalone action repo conventions confirm this.
- Reusable workflows must be at literal `.github/workflows/*.yml`; subdirectories and symlinks are not resolved. GitHub community discussion 109744 (open feature request) and vscode-github-actions discussion 207 confirm this.
- Runner archive extraction converts symlinks to copies of their targets, so URL references to symlinked paths are unsupported. actions/runner issue 3234 and nektos/act issue 2334 document the behavior. Not relevant to this ADR's final decision but relevant to why the dual-distribution draft was dropped.
- `uses:` string syntax places `@ref` at the end of the full `owner/repo/path@ref` reference, not between path segments. GitHub Actions workflow syntax docs confirm this; it rules out a simple prefix variable.
- tera CLI does not support registering custom functions. register_function is a library API taking a Rust closure; the standalone binary exposes only variable context and built-in filters. Zola issue 2493 (2024) is the open feature request; the tera maintainer's response confirms the limitation. This rules out the function-based approach and motivates the context-dict mechanism.

Open items:

- Decide how tack.sh discovers available actions to populate `tack.actions`. Candidates: glob `configs/github/actions/*/action.yml`, or require `tack-manifest.yml` in the github package to enumerate them explicitly. Glob is lower-friction; explicit enumeration catches typos earlier. Defer to implementation.
- Decide whether tack-provided workflow templates should hard-fail or warn when a consumer's `actions/checkout` is missing `submodules: true` in submodule mode. Runtime failure is loud and obvious; compile-time warning via tack.sh render would be nicer. Defer.
- Decide whether `tack.actions` should flatten (keys are action names) or nest (keys are category/package paths). Flat works for one package (github); nested would generalize to a hypothetical future where multiple packages contribute actions. Start flat, revisit if needed.
