# Task 2 Report — Explicit Capability-State Primitives

## Result
Implemented and committed Task 2 on the authoritative DGX checkout. Provider selection is persisted separately from capability state and local-dependency applicability. Capability records use the stable states `verified`, `experimental`, `deferred`, `unavailable`, and `blocked`; non-dry-run deferred/unavailable/blocked selections fail explicitly.

## Verification
- Focused capability/deferred tests: `5 passed, 41 deselected`
- Relevant deployment tests: `67 passed`
- Full suite: `113 passed in 22.17s`
- `git diff --check`: passed
- Commit: `58617ae feat(dgx-spark): expose truthful capability states`

## Files changed
- `scripts/deploy-dgx-spark-lib.sh`
- `scripts/deploy-dgx-spark.sh`
- `tests/test_dgx_spark_ac_gaps.py`
- `SKILL.md`

Unrelated pre-existing untracked files were preserved and not staged.


## Fix Report — Capability-State Persistence Defects

### Changes
- `state_write` now writes the merged payload to both `state/deployment-state.json` and `deployment-manifest.json`, preserving existing fields and stable `capability_states`.
- The wizard persists `CAPABILITY_JSON` immediately after resolution, covering successful, remote, and dry-run paths.
- The failed capability-selection call continues to pass the capability mapping in argument 6, matching `state_write` selection payload semantics; regression coverage verifies failed mapping persistence.

### Verification
- RED: `.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py -q -k "state_write_persists_capability or state_success_preserves or failed_capability"` — `2 failed, 1 passed, 46 deselected` (before implementation; failures were the expected persistence defects).
- GREEN focused: same command — `3 passed, 46 deselected in 0.24s`.
- Acceptance suite: `.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py -q` — `49 passed in 7.96s`.
- Full suite: `.venv/bin/python -m pytest -q` — `116 passed in 23.16s`.
- Syntax/whitespace: `bash -n scripts/deploy-dgx-spark-lib.sh scripts/deploy-dgx-spark.sh && git diff --check` — passed.
- Commit: `d79d4ca fix(dgx-spark): persist capability states across deployment paths`.

### Files changed
- `scripts/deploy-dgx-spark-lib.sh`
- `scripts/deploy-dgx-spark.sh`
- `tests/test_dgx_spark_ac_gaps.py`
- `.superpowers/sdd/2026-08-22-dgx-spark-clawdess-roadmap/task-2-report.md`


## Fix Round 2 — `state_success` Capability-State Persistence

### Changes
- `state_success` now preserves `capability_states` while reconstructing `deployment-manifest.json`; the existing field-preservation list was missing this key.
- Strengthened `test_state_success_preserves_capability_states_in_manifest` to assert the complete capability mapping and preserved provider after `state_write` followed by `state_success`.

### Verification
- RED: temporarily removed `capability_states` from `state_success` preservation list; `.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py -q -k state_success_preserves_capability_states_in_manifest` — `1 failed, 48 deselected`; failure was `KeyError: 'capability_states'`.
- GREEN focused: `.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py -q -k "state_write_persists_capability or state_success_preserves or failed_capability"` — `3 passed, 46 deselected in 0.18s`.
- Acceptance suite: `.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py -q` — `49 passed in 8.00s`.
- Full suite: `.venv/bin/python -m pytest -q` — `116 passed in 23.09s`.
- Syntax: `bash -n scripts/deploy-dgx-spark-lib.sh scripts/deploy-dgx-spark.sh` — passed.
- Whitespace: `git diff --check` — passed.


## Fix Round 3 — Exact Capability-State Vocabulary Validation

- Regression test added for arbitrary catalog status `catalog-corruption`; RED observed (exit 0 before fix), then GREEN: `1 passed, 49 deselected in 0.02s`.
- `capability_manifest` now explicitly accepts only `verified`, `experimental`, `deferred`, `unavailable`, or `blocked`; unknown values fail explicitly.
- Capability-focused: `3 passed, 47 deselected in 0.11s`.
- Full suite: `117 passed in 23.14s`.
- Syntax/whitespace checks passed: `bash -n scripts/deploy-dgx-spark-lib.sh scripts/deploy-dgx-spark.sh && git diff --check`.
- Implementation commit: `dbc4a4c823977c1139afadfec6523b37d52f440a`.
- Files: `scripts/deploy-dgx-spark-lib.sh`, `tests/test_dgx_spark_ac_gaps.py`, this report.


Task 2 regression follow-up (remote non-dry-run capability rejection)
- Root cause: deploy-dgx-spark.sh gated capability_reject_non_dry_run behind `DRY_RUN != true && PROVIDER != remote`, allowing remote deferred/unavailable/blocked states to proceed.
- TDD RED: `.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py -q -k "remote_non_dry_run_capability_states or cli_rejects_remote"` — `1 failed, 3 passed, 50 deselected`; the CLI gate assertion failed against the old remote exception.
- GREEN: same focused command — `4 passed, 50 deselected in 0.10s`.
- Regression coverage: parameterized deferred, unavailable, and blocked remote capability rejection; static CLI gate assertion ensures remote is not exempt. Existing remote-success dry-run tests remain green.
- Full verification: `.venv/bin/python -m pytest tests -q` — `121 passed in 23.13s`; `bash -n scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh` passed.
- Modified intended files only: `scripts/deploy-dgx-spark.sh`, `tests/test_dgx_spark_ac_gaps.py`.
