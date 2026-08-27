# Task 5 Report: Formal voice backend gates

## Scope

Added `voice_backend_status CONFIG BACKEND`, a stable JSON capability-result seam. It canonicalizes aliases, reports the catalog state and reason, preserves `speaker_wav` metadata for XTTS-v2, and rejects unsupported vLLM without claiming runtime readiness.

## Verification

- Focused voice tests: `3 passed, 62 deselected in 0.13s`
- Full suite: `140 passed in 24.24s`
- Shell syntax: `bash -n scripts/deploy-dgx-spark-lib.sh scripts/deploy-dgx-spark.sh` passed
- `git diff --check`: passed
- Changed implementation files: `scripts/deploy-dgx-spark-lib.sh`, `tests/test_dgx_spark_ac_gaps.py`
- No native Kokoro/XTTS synthesis was claimed.

## Acceptance

- Piper status remains `verified` in the existing catalog path.
- Kokoro status remains `experimental`.
- XTTS-v2 status remains `deferred` and exposes `speaker_wav` metadata.
- vLLM remains rejected as unsupported.
- No dependency, checksum, download, or runtime-readiness claims were added.
