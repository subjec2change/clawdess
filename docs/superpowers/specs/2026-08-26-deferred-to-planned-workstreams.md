# Spec: Deferred → Planned Workstreams

## Problem Statement

The DGX Spark deployment wizard has five features marked as `deferred`, `experimental`, or `blocked` in its capability catalog: Wan2GP video generation (deferred), Kokoro TTS (experimental), Piper installer (blocked — missing binary), XTTS-v2 TTS (deferred), and interactive installer UX. These are documented but not planned as actionable workstreams. The roadmap lacks specific implementation scope, acceptance criteria, and blocking edges for these items, making it impossible to execute them with agent agents when the user decides to start.

## Solution

Add a new **Task 9** section to the roadmap plan document that elevates all deferred features to planned workstreams with:
- Clear implementation scope (files modified, functions added/changed)
- Acceptance criteria for each feature (what makes it "done")
- Blocking edges (dependency order between tickets)
- Testing strategy (how each feature is verified on GB10)
- Explicit capability state transitions

Publish each workstream as a GitHub issue child of the roadmap, with native blocking edges and triage labels (`ready-for-agent`, `dgx-spark`).

## User Stories

1. As a DGX Spark user, I want Wan2GP video generation to be a selectable installer feature so that I can produce image-to-video outputs with NSFW models on my GB10.
2. As a DGX Spark user, I want Kokoro TTS to be a selectable installer feature so that I can choose a higher-quality voice backend than Piper.
3. As a DGX Spark user, I want Piper to work out of the box so that voice output is available without manual binary installation.
4. As a DGX Spark user, I want the installer to show clear status indicators (verified, experimental, deferred) for each feature so that I understand what's ready and what's not.
5. As a DGX Spark user, I want XTTS-v2 to be documented as a manual setup step so that I know what's required if I want to use it later.
6. As a developer, I want each feature to have a smoke test that produces a real artifact (video file, audio file) so that capability claims are evidence-based, not theoretical.
7. As a developer, I want ticket granularity small enough that agent agents can work independently in parallel so that implementation is faster.

## Implementation Decisions

### ADR 0001: Deferred → Planned (not coded yet)
Deferred items become planned workstreams with scope and acceptance criteria but NO code until explicit user authorization to start.

### ADR 0002: Wan2GP Video — Fully Implementable
- **Files:** `scripts/deploy-dgx-spark-lib.sh` (video smoke test function), `tests/test_dgx_spark_ac_gaps.py` (video smoke test)
- **Scope:** Add `smoke_test_video()` function that calls ComfyUI API with a test image, waits for output, verifies artifact exists
- **Capability transition:** `deferred` → `experimental` (ComfyUI installed, no artifact) → `verified` (artifact produced)
- **Smoke test:** Generate one image-to-video using Wan2GP I2V 14B through ComfyUI's `/prompt` endpoint, check for `.webm`/`.mp4` output
- **No health gate before generation** — generation IS the health test

### ADR 0003: Kokoro TTS — Upgrade Path (experimental)
- **Files:** `scripts/deploy-dgx-spark-lib.sh` (kokoro install function), `config/dgx-spark-models.json` (kokoro catalog entry), `tests/test_dgx_spark_ac_gaps.py` (kokoro smoke test)
- **Scope:** `pip install kokoro-onnx`, verify package is importable, run synthesis smoke test producing a short audio file
- **No explicit model download** — first-use download handled by pip package
- **Capability state:** `experimental` (package installed + smoke test produces audio)

### ADR 0004: Piper Installer — Prerequisite Fix
- **Files:** `scripts/deploy-dgx-spark-lib.sh` (piper install + model download), `tests/test_dgx_spark_ac_gaps.py` (piper smoke test)
- **Scope:** `pip install piper-tts`, download `en_US-ljspeech` model (~50MB), run smoke test "Hello from Clawdess on DGX Spark."
- **Capability transition:** `blocked` → `verified` (binary installed + smoke test passes)
- **Model:** `en_US-ljspeech` on Linux ARM (aarch64)

### ADR 0005: Interactive Installer — UX + Deferred Intelligence
- **Files:** `scripts/deploy-dgx-spark.sh` (installer prompts), `SKILL.md` (documentation)
- **Scope:** Improve wizard UX (colored output, progress indicators, better error messages). When a deferred/experimental feature is selected, warn the user and continue installation where possible.
- **Not:** Complete wizard rewrite — incremental improvements only

### ADR 0006: XTTS-v2 — Documentation Only
- **Files:** `config/dgx-spark-models.json` (XTTS-v2 catalog entry), `SKILL.md` (documentation)
- **Scope:** Add catalog entry with correct `deferred` status. Document that speaker_wav must be provided by user. NO installer code — the installer should not attempt to install XTTS-v2.
- **Not:** Code changes, smoke tests, or installer integration

## Testing Decisions

Each feature follows the same verification pattern:
1. **Install test** — Does the installer function complete without error?
2. **Smoke test** — Does the feature produce a real artifact (video file, audio file)?
3. **State update** — Does `deployment-state.json` reflect the correct capability state?

Specific test coverage:
- `test_piper_install_and_smoke()` — pip install piper-tts + model download + synthesis
- `test_kokoro_install_and_smoke()` — pip install kokoro-onnx + synthesis + audio check
- `test_video_smoke_test()` — ComfyUI API call → wait → artifact check
- `test_capability_manifest_after_install()` — state file reflects verified/experimental
- `test_installer_deferred_warnings()` — wizard warns about deferred features

## Out of Scope

- No changes to the photo/image generation path (already verified)
- No remote provider integration (credentials unavailable)
- No Docker/container deployment changes (local-first only)
- No changes to the state machine core (planned/running/partial/failed/complete remain unchanged)
- No XTTS-v2 installer code (documentation only)
- No CI/CD changes (existing pytest/bash -n checks remain sufficient)
- No changes to existing feature profiles (minimal/media/assistant/llm/full — just update which features they include)

## Further Notes

- All new functions must follow existing shell coding conventions (set -euo pipefail, quoted variables, no unquoted word splitting)
- All new Python tests must use the existing `bash()` helper from `tests/test_deploy_dgx_spark.py`
- Git commits should be grouped: one commit for Piper (prerequisite), one for Kokoro, one for video smoke test, one for installer UX, one for XTTS docs
- Push to `repair/dgx-spark-deployment-wizard` requires explicit user authorization (same as all existing work)
