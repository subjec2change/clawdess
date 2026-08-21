# Task 3 integration report

- Recomputed deploy-root-derived `STATE_ROOT`, `RUN_LOG`, and `LOG_FILE` after argument parsing without creating the default log directory early; explicit `CLAWDESS_MODEL_ROOT` remains preserved.
- Strengthened the real CLI failure regression with a secret-like environment value and assertions covering stdout/stderr, the run log, and deployment state.
- Made `persist_failed_state` propagate state-write failures without printing a false success message; `on_error` reports persistence failure and applies URL userinfo/query redaction in addition to environment redaction.
- Preserved nonzero CLI behavior, ERR-trap recursion safety, guarded state payload writes, and normalized secret-file detection.

Verification (fresh):

- Corrected model-state writes to use the canonical deploy root (`<deploy-root>/state/deployment-state.json`), while preserving explicit external model roots.
- Completed CLI reset safety: `--reset` requires `--yes`, rejects dry-run and symlink roots/parents, removes only the deployment root, and preserves external model roots.
- Kept host validation production-strict: the test seam bypasses architecture only; NVIDIA probe failures still return status 2 and persist discovery state.
- Added observable verbose/help and dry-run contract coverage without weakening runtime validation.

Verification (fresh):

- `pytest -q tests/test_deploy_dgx_spark.py`: **54 passed**.
- `pytest -q`: **54 passed**.
- `bash -n scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh`: passed.
- `git diff --check`: passed.
