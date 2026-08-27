# Clawdess DGX Spark — Context

## Project Overview

Clawdess is a local-first companion media generator (photos, video, voice) designed to run on an NVIDIA GB10 DGX Spark. The deployment wizard (`scripts/deploy-dgx-spark.sh`) provides an interactive installer with profiles (`minimal`, `media`, `assistant`, `llm`, `full`) that let users select which features to install locally or delegate to remote providers.

## Current State

### Verified (runtime-tested on GB10)
- GB10 detection, PyTorch nightly cu128 for sm_121 support
- Photo model acquisition (Juggernaut-X NSFW from HuggingFace)
- ComfyUI installation with custom nodes (Wan2GP, Flux, LTX, etc.)
- Deployment state machine (`planned` → `running` → `installed`/`failed`)
- Provider selection: `local` vs `remote` modes
- Feature-first CLI with profiles
- All tests passing (146/146 pytest + bash -n clean)
- Piper voice backend catalog definition (status: `verified` in catalog)

### Deferred/Experimental (not yet tested on hardware)
- **Wan2GP video generation** — ComfyUI runs but video artifact generation untested; no real output artifact exists
- **Kokoro TTS** — catalog defined, pip install stub present, status: `experimental`
- **XTTS-v2** — catalog defined, status: `deferred`; requires speaker_wav configuration
- **Piper executable on DGX** — blocked; no `piper` binary found on remote host during acceptance test
- **Remote provider generation** — credential-unavailable, status: `blocked`

### Design Principles
- Truthful capability claims: never claim `verified` without evidence
- State values: `verified`, `experimental`, `deferred`, `unavailable`, `blocked`
- No fabricated checksums, model sources, or runtime readiness
- Every acceptance claim requires command output, real artifact, or passing test

## Open Questions
- What should the interactive installer look like for deferred/experimental features?
- How should Kokoro/XTTS installation be structured?
- What's the target source and method for Piper model files on DGX?
- Should video generation be gated on ComfyUI health check or produce actual artifacts?
