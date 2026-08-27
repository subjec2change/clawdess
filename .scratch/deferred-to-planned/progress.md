# Deferred-to-Planned Progress Tracker

**Branch:** `repair/dgx-spark-deployment-wizard`  
**Last Updated:** 2026-08-27  
**Status:** ✅ ALL COMPLETE

## Ticket Status

| ID | Title | Commit | Notes |
|----|-------|--------|-------|
| T-01 | Install Piper + en_US-ljspeech model | `82fa814` | `download_piper_model()` in lib.sh, downloads from HuggingFace |
| T-02 | Piper smoke test | `pre-existing` | `smoke_test_piper()` already implemented, generates .wav |
| T-03 | Kokoro pip install | `82fa814` | `install_kokoro_tts()` installs pip package, returns 1 (experimental) |
| T-04 | Kokoro smoke test | `137abbd` | `smoke_test_kokoro()` — returns 1/deferred, 2/partial, 0/verified |
| T-05 | Voice catalog/docs | `137abbd` | SKILL.md + README.md capability table updated |
| T-06 | Wan2GP video smoke test | `pre-existing` | `smoke_test_video()` — image gen → I2V workflow → artifact check |
| T-07 | Video artifact verification | `pre-existing` | smoke_test_video checks .webm/.mp4 output |
| T-08 | Video docs/state | `137abbd` | Video capability section in SKILL.md |
| T-09 | Installer UX improvements | `ca3aa98` | Colors, spinner, deferred banners |
| T-10 | Deferred/experimental warnings | `ca3aa98` | `feature_warning()`, `deferred_warning_banner()`, `capability_reject_non_dry_run()` |
| T-11 | XTTS-v2 catalog entry + docs | `137abbd` | Config + SKILL.md + README.md manual install instructions |

## Test Coverage

- **Total tests:** 75 passing
- **New tests added (137abbd):**
  - `test_smoke_test_kokoro_deferred_when_models_missing`
  - `test_smoke_test_kokoro_returns_deferred_when_package_missing`
  - `test_smoke_test_video_deferred_when_models_missing`
  - `test_smoke_test_video_returns_failure_on_comfyui_not_ready`
  - `test_video_state_manifest_includes_capability_status`

## Smoke Test Contracts

### Piper (`smoke_test_piper`)
- Returns: `0` on success, `1` on failure
- Generates `.wav` file from text prompt

### Kokoro (`smoke_test_kokoro`)
- Returns: `0` on success, `1` on deferred (package/models absent), `2` on partial (models present but no executable)

### Video (`smoke_test_video`)
- Returns: `0` on success, `1` on deferred (Wan2GP model absent), `2` on failure (ComfyUI not ready, workflow failed, no artifact)

## Deployment Capabilities Summary

| Feature | State | Smoke Test | Evidence Level |
|---------|-------|------------|----------------|
| Photo / ComfyUI | `verified` | Runs on deployment | `artifact` (image) |
| Piper TTS | `verified` | Runs on deployment | `artifact` (.wav) |
| Kokoro | `experimental` | Returns early if models missing | No artifact yet |
| Video / Wan2GP | `deferred` | Returns early if model absent | No artifact yet |
| XTTS-v2 | `deferred` | Catalog entry only | Manual install required |
