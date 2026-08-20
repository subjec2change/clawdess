# Task 3 integration report

- Recomputed deploy-root-derived `STATE_ROOT`, `RUN_LOG`, and `LOG_FILE` after argument parsing without creating the default log directory early; explicit `CLAWDESS_MODEL_ROOT` remains preserved.
- Strengthened the real CLI failure regression with a secret-like environment value and assertions covering stdout/stderr, the run log, and deployment state.
- Made `persist_failed_state` propagate state-write failures without printing a false success message; `on_error` reports persistence failure and applies URL userinfo/query redaction in addition to environment redaction.
- Preserved nonzero CLI behavior, ERR-trap recursion safety, guarded state payload writes, and normalized secret-file detection.

Verification (fresh):

- Focused Task 3 regression selection (`pytest -q tests/test_deploy_dgx_spark.py -k 'cli_real_command_failure or deploy_root_routes or persist_failed_state_reports or on_error_redacts_url or state_write_invalid_payload'`): **5 passed, 49 deselected**.
- Full `pytest -q`: **46 passed, 8 failed**. The failures are broader pre-existing model-fixture and CLI-contract/reset expectations outside these final Task 3 corrections; full-suite success is not claimed.
- `bash -n scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh`: passed.
- `git diff --check`: passed.
