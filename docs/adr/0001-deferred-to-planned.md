# ADR 0001: Deferred items become planned workstreams, not code

**Date:** 2026-08-26
**Status:** accepted

## Context

The DGX Spark deployment wizard has several features marked as `deferred`, `experimental`, or `blocked` in its capability catalog. These include Wan2GP video generation, Kokoro TTS, XTTS-v2, Piper executable installation, and interactive installer improvements. The user wants these moved from "deferred/blocked" to "planned for execution" without starting code yet.

## Decision

Deferred items will be elevated to the roadmap as **planned workstreams** with:
- Clear acceptance criteria
- Blocking edges (dependency order)
- Implementation scope documented
- No code written until user confirms execution start

## Consequences

- The roadmap will accurately reflect what's planned, not what's done
- Agent cycles won't be wasted on premature implementation
- User retains explicit control over when to start coding
