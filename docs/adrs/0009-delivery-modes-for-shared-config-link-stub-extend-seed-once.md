---
number: 9
title: Delivery modes for shared config: link, stub-extend, seed-once
date: 2026-10-16
status: proposed
---

# 9. Delivery modes for shared config: link, stub-extend, seed-once

Date: 2026-10-16

## Status

Proposed

## Context

tack's theory of use is to share configuration, not static copies: a consumer edits a linked file in place, the change lands in the `.tack` working tree, and the consumer commits it there and opens a pull request; other consumers receive it on a submodule bump (ADR-0008). That works for files a tool reads verbatim. Three situations break it.

1. The consumer needs local overrides as well as the shared rules. A link offers no place for them that is not also an upstream edit; a copy keeps overrides but freezes the shared rules at seed time.
2. The tool refuses to read the file through a symlink. Git ignores `.gitignore`, `.gitattributes`, and `.mailmap` when they are symbolic links (Git 2.32 release notes), because it must also read them from the object store.
3. The file executes a program on the host (`.envrc`, `devenv.nix`), or is otherwise something the consumer must control. A shared link would let an upstream change alter what runs on every consumer's machine without a local review step.

The current manifests are inconsistent. `configs/python/ruff.toml` was delivered as a plain link while its header and the README said "seeded once"; the root `moon.yml` and `.envrc` were plain copies overwritten on every apply, destroying consumer edits; `.gitignore`/`.gitattributes` were plain copies with the same problem, while `configs/common/lfs` already used `concat` for `.gitattributes`. A `files.<src>.target` override forces copy mode, a restriction left over from the lnko directory-link implementation that per-file `ln -sfn` no longer needs; it makes it impossible to link a file from a `path_prefix` package to the consumer root.

Ruff supports `extend` (settings from the extended file merged under the current file); devenv supports `imports`; moon shares tasks through `.moon/tasks/*.yml` selected by tag and treats root-project tasks as non-standard; git supports neither extension nor symlinks for its dotfiles.

## Decision

Every shared file is delivered in exactly one of three modes, chosen by what the consuming tool supports, in this order of preference.

1. **Link** when the tool reads the file through the filesystem and consumers need no local additions. The file is identical in every consumer; edits are upstream edits by definition. Examples: `.editorconfig`, `.moon/tasks/*.yml`, `.moon/toolchains-*.yml`, `oxlintrc.json`, `tsconfig.options.json`, and the root `moon.yml`. The root `moon.yml` is linked, not copied: root-project tasks are non-standard in moon and are to be avoided; shared tasks reach projects through tagged `.moon/tasks/*.yml`, so there is nothing to customise at the root. Its header comment states this.

2. **Stub + extend** when the tool has an extension mechanism and consumers need overrides. The shared rules stay in `.tack` and are never materialised (`ignore:` in the manifest). The consumer root receives a small seed-once stub (`<name>.copy.<ext>` with `overwrite: false`) whose required content is the extend/import line pointing into `.tack`; consumer overrides go below it. Submodule bumps update the shared rules without touching the stub; changing a shared rule is still an edit in `.tack` plus a PR. Examples: `ruff.toml` (`extend = ".tack/configs/python/ruff.toml"`), `devenv.nix` (`imports = [ ./.tack/configs/<area>/<module>.nix ]`), and future lint configs with `extends` support.

3. **Seed-once copy or concat** when the tool supports neither linking nor extension, or when the file executes a program on the host and the consumer must control it. `copy` with `overwrite: false` for whole files the consumer owns (`.envrc`, `devenv.yaml`); `concat` for list-shaped files the consumer must also append to and that git refuses to read through a symlink (`.gitignore`, `.gitattributes`). Shared concat blocks are fenced with `# >>> tack:<pkg> >>>` / `# <<< tack:<pkg> <<<` markers so a reader can tell the shared block from consumer lines and a future `tack.sh` can replace rather than append. Updates in this mode do not propagate automatically; a submodule bump is accompanied by reading the template diff, and `tack.sh --overwrite <pkg>` re-seeds deliberately.

4. `tack.sh` lifts the rule that a `files.<src>.target` override forces copy mode. Mode rules (`mode:`, `.copy.` marker, default link) apply to overridden targets as to any other file; link mode places the symlink at the overridden path. `overwrite: false` continues to force copy, since a link cannot be "seeded". The protected-target guard (ADR-0008) applies to overridden targets in every mode.

5. Each package manifest states the mode for anything that is not a plain link, and the README's per-pack tables name the mode per file. `tests/` gain cases asserting the mode of each root file delivered by `configs/common`, `configs/devenv`, `configs/python`, and `.moon`.

## Consequences

- Consumers stop losing edits on re-apply: `.envrc`, `.gitignore`, and `.gitattributes` are no longer overwritten; `ruff.toml` overrides live in a file tack never rewrites.
- Shared rule changes keep propagating where the tool allows it (ruff via `extend`, devenv via `imports`, moon via linked task files). The only files whose updates need a human diff are the seed-once set, which is deliberately small: `.envrc`, `devenv.yaml`, `devenv.nix` body, the shared blocks of `.gitignore`/`.gitattributes`.
- The root `moon.yml` becomes identical across consumers. A consumer that needs a root task has to argue for it upstream or add a tagged task file, which is the intended pressure.
- Lifting the target-override-forces-copy rule changes `tack.sh` behaviour for any existing manifest that relied on an override to get a copy. Audit: `.moon/tack.yml` (`moon.yml`, now intended as a link) and any `files.<src>.target` without `overwrite: false`. Add `mode: - copy: <file>` where a copy was intended.
- Concat accumulation: a changed shared block appends once rather than replacing until the fence-aware replace lands; for `.gitattributes` the newest block is last and therefore wins on conflicting patterns.
- The `.copy.` stub files add one small source file per extendable tool; their headers carry the override instructions so the pattern is discoverable from the consumer's own file.
- Supplements ADR-0008 (what is writable) with how each file is delivered; neither supersedes the other.