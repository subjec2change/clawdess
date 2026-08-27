# ADR 0004: Piper installation is the installer's responsibility

**Date:** 2026-08-26
**Status:** accepted

## Context

The acceptance test failed because no `piper` binary exists on the DGX host. This is a missing dependency, not a capability gap — but it blocks voice entirely.

## Decision

The installer must handle Piper installation as part of the voice profile:
- `pip install piper-tts` to get the binary
- Download a model from the Piper release
- Run the smoke test to verify

This is a prerequisite for voice capability, not a separate task.

## Consequences

- Voice becomes a complete feature: install → configure → verify
- No more "piper not found" blocking tests
- The installer handles all Piper dependencies automatically
