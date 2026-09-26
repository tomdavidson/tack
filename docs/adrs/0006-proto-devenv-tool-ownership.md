---
number: 6
title: Proto and devenv tool ownership
date: 2026-09-25
status: proposed
tags:
  - devenv
  - proto
  - devcontainer
  - php
---

# 6. Proto and devenv tool ownership

Date: 2026-09-25

## Status

Proposed

## Context

The tack-dev base image (ADR-0005) provides both proto and devenv. Both can
install and manage tools, and they overlap for some use cases. Without a clear
boundary, consumers will duplicate tool definitions and versions will drift.

moon's toolchain layer is built on top of proto and has no equivalent
integration with Nix or devenv. Proto's per-project `.prototools` files feed
directly into moon's dependency-manager and version-resolution model.

devenv excels at native library dependencies, PHP extensions, and running
process-based services (databases, caches). Proto handles these poorly or not
at all.

## Decision

Tool ownership is split by capability, not by language:

**Proto owns:**
- Tools that are self-contained binaries with a well-defined proto plugin.
- Tools that moon integrates with at a toolchain level (node, pnpm, rust).
- Tools where per-project version override is the normal case.
- Default: lnko, tera, yq, dprint, shfmt, shellcheck, moon, node, pnpm, rust.

**devenv owns:**
- Tools that require native library linking or system-level configuration.
- PHP and Composer (no proto plugin; requires extension management).
- Services (databases, caches, mail) that run as background processes.
- Default in this PR: present but empty of language/service declarations;
  PHP and services are added in a follow-up PR.

**Neither owns node/pnpm in the base image.** They are project-level tools and
stay in consumer `.prototools` files, not the global image file.

**devenv.nix renders with `overwrite: false`** so consumer edits survive tack
re-runs. Tack provides the initial scaffold; the consumer owns subsequent edits.

**devenv.lock is not templated.** The consumer commits it after first `devenv shell`.

## Consequences

- Consumers with PHP or services add the devenv package and extend `devenv.nix`.
- Consumers without PHP still get devenv present via the base image but do not
  need `configs/devenv` unless they add services.
- Running both proto and devenv for the same tool (e.g. a future proto PHP
  plugin) requires an explicit override decision and a note in the consumer
  `tackrc.yml`.
- `devenv.nix` being `overwrite: false` means tack cannot update it after first
  render. Consumer must manually reconcile template changes.
