# ADR 0002: Wan2GP video generation is fully implementable

**Date:** 2026-08-26
**Status:** accepted

## Context

Wan2GP video is currently deferred because ComfyUI runs but no video artifact has been produced. The question was whether to keep it at "document as future" or make it fully scriptable.

## Decision

Video generation will be fully implementable in the installer:
- Scripts for automatic Wan2GP installation and custom node wiring
- ComfyUI health check
- Smoke test that produces an actual video artifact
- Capability state progression: `deferred` → `experimental` → `verified` only when a real artifact exists

## Consequences

- The installer handles video the same way it handles photo: download, install, configure, verify
- The verification gate (producing an actual artifact) is the last step before marking `verified`
- No hand-waving: the code must actually produce an artifact on GB10
