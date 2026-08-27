# ADR-0006: XTTS-v2 Documentation-Only (No Installer Wiring)

**Status**: Accepted  
**Date**: 2026-08-27  
**Context**: The deployment wizard supports three TTS backends: Piper (verified), Kokoro (experimental), and XTTS-v2 (deferred). Piper and Kokoro have installer integration. XTTS-v2 has no installer wiring.

## Decision

XTTS-v2 remains a catalog entry with documentation-only support in the deployment wizard. No installer function is wired for it.

### Rationale

1. **Complex dependencies**: XTTS-v2 requires Coqui TTS, which has a different dependency chain than Piper/Kokoro (PyTorch heavy, speaker-WAV preprocessing, larger model files).
2. **No verified artifact**: No successful XTTS audio artifact has been produced in any deployment run to date.
3. **Deferred by design**: The capability state is explicitly `deferred`. Installing wiring for a deferred capability would contradict the stated capability state.
4. **Manual install path**: Users who want XTTS-v2 can install it manually using the documented instructions (Coqui TTS + speaker_wav path in `config/dgx-spark-models.json`).

### What's in scope

- Catalog entry in `config/dgx-spark-models.json` documenting XTTS-v2 requirements.
- Documentation in SKILL.md explaining the manual install path.
- Voice catalog function includes XTTS-v2 in its `deferred` output.

### What's out of scope

- `install_xtts_tts()` function in the installer.
- Automated XTTS model acquisition.
- XTTS smoke test integration (current smoke test returns `1`/deferred for XTTS by design).

### Evidence

- XTTS smoke test (`smoke_test_xtts()`) returns `1` with a deferred message when invoked.
- The capability truth table in README.md documents XTTS-v2 as `deferred`.
- No deployment run has produced a verified XTTS artifact.
