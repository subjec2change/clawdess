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
