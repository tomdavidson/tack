---
number: 4
title: Delayed Merge and Unstructured Concat
date: 2026-04-24
status: proposed
---

# 4. Delayed Merge and Unstructured Concat

Date: 2026-04-24

## Status

Proposed

## Context

tack.sh needs to contribute content to files the consumer repo already owns (e.g., Cargo.toml). Two naive options were rejected: full file replacement via link/copy clobbers consumer-authored content, and structured merge at apply time (parse TOML/YAML/JSON, deep-merge, re-serialize) requires a format-aware merger per file type, loses comments and key order, and couples tack to every format its packages touch. We want tack to remain a POSIX shell script with a small tool surface (lnko, tera, yq, standard coreutils) and no format-specific parsers beyond yq for its own manifest.

## Decision

Two complementary primitives, neither of which parses the destination file's structure.

1. Delayed merge (deferred to the consumer's toolchain). tack does not perform semantic merges itself. Packages that need structured contribution emit a sibling file (e.g., clippy-lints.toml) and rely on the destination format's own include/import mechanism, or on a post-apply step the consumer runs (cargo, make, etc.). The 'merge' happens when the consumer's tool loads the destination, not when tack runs. tack's job ends at placing the file.

2. Unstructured concat. Files marked _.concat._ are appended to a manifest-declared target verbatim. tack treats the destination as an opaque byte stream with no parsing. It detects prior application by matching the first two non-comment, non-blank lines of the source (the 'signature') against consecutive lines in the destination; if present, skip. Otherwise it appends a newline then cats the source onto the destination.

Manifest shape:

    files:
      clippy-cargo.concat.toml:
        target: Cargo.toml
        enforced:
          - workspace.lints.clippy.unwrap_used

The enforced list is advisory metadata for humans and future linters; tack does not act on it.

## Consequences

Positive:

- No format parser dependency beyond yq for tack's own manifest.
- Comments, key order, and consumer edits above the appended block are preserved.
- Idempotent via signature detection; safe to re-run.
- Works for any append-friendly format (TOML tables, multi-doc YAML, shell rc files, gitignore, editorconfig sections).

Negative:

- Concat assumes the destination format tolerates appended content at EOF. TOML tables and multi-doc YAML work; JSON does not, and arbitrary mid-file insertion is unsupported.
- Signature detection is line-based and brittle to reformatting. A consumer who reflows the appended block will trigger a duplicate append on next run.
- Delayed merge pushes responsibility onto the consumer's toolchain; packages must choose formats and destinations whose loaders support include/compose semantics, or accept that their contribution is literal append.
- No conflict detection against competing concat sources targeting the same destination; last-writer-wins in apply order.

Alternatives considered:

- Structured merge via a pluggable merger registry keyed by extension. Rejected: scope creep, loses fidelity, couples tack to N format libraries.
- Patch/diff application. Rejected: requires the consumer's file to match an expected base, defeating contribution to consumer-owned files.
- Template the destination. Rejected: tack would own the full file, contradicting consumer ownership.

Implementation reference: concat_file in tack.sh extracts the first two non-comment lines as signature (grep -v -E '^[[:space:]]*(#|$)' | head -n 2), scans destination with awk for two consecutive lines matching the signature and skips if found, otherwise appends \n plus the source. Delayed merge has no code; it is a convention whereby package authors place files whose contents are composed by the consumer's toolchain, not by tack.
