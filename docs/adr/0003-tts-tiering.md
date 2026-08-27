# ADR 0003: Kokoro TTS is an upgrade path, XTTS-v2 is deferred

**Date:** 2026-08-26
**Status:** accepted

## Context

Both Kokoro and XTTS-v2 are TTS backends with different readiness levels. Kokoro has a published release (ONNX format on GitHub). XTTS-v2 requires a speaker_wav file from the user and has no simple pip-installable release.

## Decision

- **Kokoro**: Implement as a higher-quality alternative to Piper. Has a release at `nazdridoy/kokoro-onnx` with pip-installable Python package. Installer should support it as a selectable backend.
- **XTTS-v2**: Keep as deferred. Requires manual speaker_wav configuration that is user-specific and not scriptable. Document it as a manual setup step, not an installer feature.

## Consequences

- Kokoro gets first-class installer support (catalog entry, pip install, smoke test)
- XTTS-v2 gets catalog documentation but no automated install path
- Piper remains the default verified backend
- Three-tier TTS capability: verified (Piper), experimental (Kokoro), deferred (XTTS-v2)
