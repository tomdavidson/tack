---
number: 5
title: Tack base image and devcontainer
date: 2026-09-25
status: proposed
tags:
  - devcontainer
  - image
  - isolation
---

# 5. Tack base image and devcontainer

Date: 2026-09-25

## Status

Proposed

## Context

Consumers need isolation, not only reproducible toolchains. proto shims and a
native `devenv shell` pin versions but run with full host access.

Planned PHP/Drupal support needs tools proto handles poorly (PHP, Composer,
services). devenv provides them and requires Nix. Requiring Nix, devenv, proto,
moon, lnko, tera, and yq on every host is a bootstrap problem.

Every tack consumer already needs moon, proto, and tack's own runtime
dependencies, which justifies one shared base image.

## Decision

- Publish `ghcr.io/tomdavidson/tack-dev`, built from `images/tack-dev/Containerfile`.
- Base is Debian slim (trixie-slim).
  - Rejected NixOS: no FHS dynamic linker, so the VS Code server, the VSCodium
    server, and proto-installed prebuilt binaries fail without nix-ld.
  - Rejected fully Nix-built images (dockerTools, nix2container): viable only if
    Nix provides every tool, which drops proto and moon's toolchain integration.
- Contents: non-root `dev` user (uid 1000), single-user Nix, devenv, proto, and
  tack runtime tools (lnko, tera, yq) installed via proto using existing proto
  plugin definitions at tomdavidson.github.io/proto.
- A global `.prototools` at `/home/dev/.proto/.prototools` holds tack's tools.
  It is proto's lowest-priority fallback; a consumer's project `.prototools`
  overrides any version in it.
- The global file is installed at build time with
  `proto install --config-mode global`, because proto's default `upwards` mode
  ignores the global file.
- The source file is `images/tack-dev/.prototools`, named to match Renovate's
  proto manager glob (`**/.prototools`). Any change to it triggers a rebuild.
- node and pnpm are excluded from the global file; they are project-level tools
  managed by consumer `.prototools` files.
- Consumers reference the image by digest, not tag. A follow-up ADR covers the
  `configs/devcontainer` package that renders the digest into `.devcontainer/devcontainer.json`.
- The target runtime is rootless Podman. One spec-only `devcontainer.json`
  serves VS Code (Dev Containers extension) and VSCodium (DevPod with
  vscodium-devpodcontainers). It has no `customizations` block; editor
  extensions and container runtime paths are host-side settings.
- CI builds and smoke-tests with Podman on ubuntu-24.04. amd64 only for now;
  arm64 deferred because QEMU emulation makes the Nix install layer slow.

## Consequences

- The host contract for tack consumers shrinks to: Git, rootless Podman, and
  one supported devcontainer client.
- Tack tool versions are tied to the image. Updating them means bumping
  `images/tack-dev/.prototools`, rebuilding the image, and bumping the digest
  in consumers via a submodule update.
- A consumer's project `.prototools` overrides global versions for any tool it
  pins, including tack tools if a different version is needed.
- Running moon tasks on the host outside the container is unsupported for
  version parity.
- The workspace source mount remains writable from inside the container.
  Isolation covers processes, packages, and environment, not the source tree.
- Image build and publish add an ongoing maintenance surface and a GHCR package.
