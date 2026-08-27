# ADR 0005: Interactive installer combines UX improvements with deferred-feature intelligence

**Date:** 2026-08-26
**Status:** accepted

## Context

The user wants both better UX for the wizard and intelligent handling of deferred/experimental features. The existing wizard has `--non-interactive` flag for scripted installs.

## Decision

The installer will:
1. Improve UX: colored output, progress indicators, better error messages
2. Handle deferred/experimental features intelligently: warn about status, continue installation where possible, clearly label capabilities as "deferred until verified"

## Consequences

- Users get a polished interactive experience
- Deferred features are still offered as selectable options, just with clear warnings
- The wizard doesn't block on deferred features — it installs what it can and documents gaps
