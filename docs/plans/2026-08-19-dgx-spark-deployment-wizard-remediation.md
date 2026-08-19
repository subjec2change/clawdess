# DGX Spark Deployment Wizard Remediation Implementation Plan

> **For implementer:** Use TDD throughout. Write each failing test first, run it to verify RED, implement the smallest fix, run the focused test and full suite, then commit and push the checkpoint.

**Goal:** Make all currently failing DGX Spark wizard tests green, complete the deployment contract gaps, and preserve recoverable GitHub checkpoints throughout the work.

**Architecture:** Keep `scripts/deploy-dgx-spark.sh` as the orchestration/CLI/trap layer and `scripts/deploy-dgx-spark-lib.sh` as the reusable helper layer. Use injected probe functions in tests so x86_64 CI/development hosts can exercise compatible-path behavior without weakening production ARM64/GB10 validation. Persist state and manifests atomically under the deployment root and generate lifecycle scripts from absolute paths.

**Tech Stack:** Bash 5, Python 3, pytest, JSON, GitHub HTTPS remote.

**Authoritative branch:** `repair/dgx-spark-deployment-wizard`

**Checkpoint rule:** After each numbered workstream, run its focused tests plus syntax checks, commit, push to `origin/repair/dgx-spark-deployment-wizard`, and record the SHA. Use `/tmp/clawdess-gh` if the FUSE-mounted checkout cannot safely perform Git operations.

---

## Baseline

At planning time:

```text
pytest tests/test_deploy_dgx_spark.py -q
26 failed, 17 passed
```

Known failure classes are GPU capability whitespace, missing pytest fixtures, URL-redaction sed quoting, model acquisition error/state handling, probe seam overrides, JSON payload escaping, test helper environment injection, CLI validation ordering/exit codes, script-relative library loading, reset/verbose/model-root options, and architecture-dependent dry-run assumptions.

---

## Workstream 1: Stabilize tests and shell seams

### Task 1: Repair pytest fixtures and test runner helper

**Files:**
- Modify: `tests/test_deploy_dgx_spark.py`

**Step 1: Write/fix the failing tests**
- Add `tmp_path` to `test_model_validate_fails_undersized`.
- Add `tmp_path` to `test_acquisition_plans_three_models_dry_run`.
- Extend `bash(script, env=None)` to merge an optional environment mapping and pass it to `subprocess.run`.
- Keep the helper sourcing the library exactly once.

**Step 2: Run RED**

```bash
pytest tests/test_deploy_dgx_spark.py::test_model_validate_fails_undersized tests/test_deploy_dgx_spark.py::test_acquisition_plans_three_models_dry_run tests/test_deploy_dgx_spark.py::test_redaction_replaces_api_tokens_and_secret_file_values -q
```

Expected before the changes: fixture `NameError` and `bash() got an unexpected keyword argument 'env'`.

**Step 3: Implement the minimal test-harness correction.**

**Step 4: Run GREEN**

```bash
pytest tests/test_deploy_dgx_spark.py::test_model_validate_fails_undersized tests/test_deploy_dgx_spark.py::test_acquisition_plans_three_models_dry_run tests/test_deploy_dgx_spark.py::test_redaction_replaces_api_tokens_and_secret_file_values -q
```

**Step 5: Commit**

```bash
git add tests/test_deploy_dgx_spark.py
git commit -m "test(dgx-spark): repair fixtures and bash test environment seams"
```

### Task 2: Normalize GPU capability parsing and probe seams

**Files:**
- Modify: `scripts/deploy-dgx-spark-lib.sh`
- Test: `tests/test_deploy_dgx_spark.py`

**Step 1: Add/strengthen tests**
- Verify `check_gb10_gpu` accepts the CSV value `GB10, 64 GB, 12.1` with surrounding whitespace.
- Verify `[N/A]` memory remains accepted.
- Verify each `probe_*` wrapper calls its overridable `clawdess_*` seam rather than bypassing it.

**Step 2: Run RED**

```bash
pytest tests/test_deploy_dgx_spark.py::test_gpu_check_passes_gb10_output tests/test_deploy_dgx_spark.py::test_gpu_check_handles_na_memory tests/test_deploy_dgx_spark.py::test_probe_seams_are_overridable -q
```

Expected: capability mismatch caused by untrimmed CSV whitespace and probe wrapper output coming from host commands.

**Step 3: Implement**
- Trim name, memory, and compute-capability fields with Bash parameter expansion or an existing safe parser.
- Keep exact GB10 and `12.1` validation.
- Route `probe_command`, `probe_nvidia_smi`, `probe_python`, `probe_docker`, `probe_curl`, and `probe_df` through their corresponding `clawdess_*` functions.
- Correct `probe_curl` argument ordering so URL and output path are unambiguous.

**Step 4: Run GREEN**

```bash
pytest tests/test_deploy_dgx_spark.py::test_gpu_check_passes_gb10_output tests/test_deploy_dgx_spark.py::test_gpu_check_handles_na_memory tests/test_deploy_dgx_spark.py::test_probe_seams_are_overridable -q
```

**Step 5: Commit**

```bash
git add scripts/deploy-dgx-spark-lib.sh tests/test_deploy_dgx_spark.py
git commit -m "fix(dgx-spark): normalize hardware parsing and probe seams"
```

### Task 3: Fix redaction and atomic JSON writing

**Files:**
- Modify: `scripts/deploy-dgx-spark-lib.sh`
- Test: `tests/test_deploy_dgx_spark.py`

**Step 1: Add focused tests**
- Userinfo URLs redact credentials without sed delimiter errors.
- Query values for `token`, `access_token`, `api_key`, and `key` are redacted.
- `json_write_atomic` writes the exact payload followed by one newline and leaves no temporary files.
- Empty secret environments do not cause nested redaction errors.

**Step 2: Run RED**

```bash
pytest tests/test_deploy_dgx_spark.py::test_model_redact_url_covers_userinfo tests/test_deploy_dgx_spark.py::test_model_redact_url_covers_query_tokens tests/test_deploy_dgx_spark.py::test_json_write_is_atomic_and_complete tests/test_deploy_dgx_spark.py::test_empty_secret_environment_does_not_emit_nested_redaction_error -q
```

**Step 3: Implement**
- Replace the invalid sed replacement/backreference quoting with a delimiter-safe implementation; prefer Bash/Python parsing already available in the project over nested sed expressions.
- Make redaction tolerate unset/empty secret variables.
- Ensure `json_write_atomic` receives the literal payload, writes it with `printf '%s\\n'`, uses a same-directory temporary file, and cleans it on success/failure.

**Step 4: Run GREEN**

```bash
pytest tests/test_deploy_dgx_spark.py::test_model_redact_url_covers_userinfo tests/test_deploy_dgx_spark.py::test_model_redact_url_covers_query_tokens tests/test_deploy_dgx_spark.py::test_json_write_is_atomic_and_complete tests/test_deploy_dgx_spark.py::test_empty_secret_environment_does_not_emit_nested_redaction_error -q
```

**Step 5: Commit**

```bash
git add scripts/deploy-dgx-spark-lib.sh tests/test_deploy_dgx_spark.py
git commit -m "fix(dgx-spark): harden redaction and atomic state writes"
```

### Task 4: Workstream-1 checkpoint

Run:

```bash
bash -n scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh
pytest tests/test_deploy_dgx_spark.py -q
```

Commit and push:

```bash
git add scripts tests
git commit -m "checkpoint(dgx-spark): stabilize test and shell foundations"
git push origin repair/dgx-spark-deployment-wizard
git rev-parse HEAD
```

Record the SHA before proceeding.

---

## Workstream 2: Repair model acquisition and validation behavior

### Task 5: Correct model selection and empty-record failures

**Files:**
- Modify: `scripts/deploy-dgx-spark-lib.sh`
- Test: `tests/test_deploy_dgx_spark.py`

**Step 1: Add tests**
- `model_records` returns no selected records for unknown image/backend identifiers.
- `acquire_models` returns non-zero and persists failed state when the selection is empty.

**Step 2: Run RED**

```bash
pytest tests/test_deploy_dgx_spark.py::test_acquisition_fails_when_no_records -q
```

**Step 3: Implement**
- Count emitted records before acquisition.
- Treat zero selected records as a required models-phase failure.
- Persist redacted `deployment-state.json` under the canonical state root without adding a second `state/` component.

**Step 4: Run GREEN**

```bash
pytest tests/test_deploy_dgx_spark.py::test_acquisition_fails_when_no_records -q
```

**Step 5: Commit**

```bash
git add scripts/deploy-dgx-spark-lib.sh tests/test_deploy_dgx_spark.py
git commit -m "fix(dgx-spark): reject empty model selections"
```

### Task 6: Correct state-root conventions and failure propagation

**Files:**
- Modify: `scripts/deploy-dgx-spark-lib.sh`
- Test: `tests/test_deploy_dgx_spark.py`

**Step 1: Add/fix tests**
- Successful acquisition writes `state_root/deployment-state.json` when passed a state directory.
- Download failure returns non-zero and writes `state=failed`, `phase=models`.
- Insufficient disk returns non-zero and persists models failure.
- Checksum mismatch returns non-zero and persists models failure.

**Step 2: Run RED**

```bash
pytest tests/test_deploy_dgx_spark.py::test_successful_model_state_is_structured_json tests/test_deploy_dgx_spark.py::test_required_model_download_failure_is_persisted_in_state tests/test_deploy_dgx_spark.py::test_insufficient_disk_space_persists_state tests/test_deploy_dgx_spark.py::test_checksum_mismatch_persists_state -q
```

**Step 3: Implement**
- Establish one contract: callers pass `STATE_ROOT`, and the library writes directly to `$STATE_ROOT/deployment-state.json`; callers pass the deployment root only where the library explicitly documents that contract.
- Ensure every `probe_curl` failure is checked immediately.
- Validate downloaded size before accepting the record.
- Compute and compare declared checksums; write failure state before returning non-zero.
- Do not mask failures with `|| true` except for explicitly optional probes.

**Step 4: Run GREEN**

```bash
pytest tests/test_deploy_dgx_spark.py::test_successful_model_state_is_structured_json tests/test_deploy_dgx_spark.py::test_required_model_download_failure_is_persisted_in_state tests/test_deploy_dgx_spark.py::test_insufficient_disk_space_persists_state tests/test_deploy_dgx_spark.py::test_checksum_mismatch_persists_state -q
```

**Step 5: Commit**

```bash
git add scripts/deploy-dgx-spark-lib.sh tests/test_deploy_dgx_spark.py
git commit -m "fix(dgx-spark): propagate model acquisition failures"
```

### Task 7: Workstream-2 checkpoint

```bash
bash -n scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh
pytest tests/test_deploy_dgx_spark.py -q
git add scripts tests
git commit -m "checkpoint(dgx-spark): make model acquisition failures deterministic"
git push origin repair/dgx-spark-deployment-wizard
git rev-parse HEAD
```

Record the SHA before proceeding.

---

## Workstream 3: Complete CLI, traps, and platform-independent dry runs

### Task 8: Fix CLI validation order, exit codes, and script sourcing

**Files:**
- Modify: `scripts/deploy-dgx-spark.sh`
- Test: `tests/test_deploy_dgx_spark.py`

**Step 1: Add tests**
- `--non-interactive` without `--profile` fails with a profile-specific message before host probes.
- Required discovery probe failure returns status 2 and logs `phase=discovery`.
- Validation failure returns status 2 and logs `phase=validation`.
- Sourcing the entry point from any working directory resolves the library relative to the script, not `$PWD`.
- Error trap records phase, status, command, and redacted context.

**Step 2: Run RED**

```bash
pytest tests/test_deploy_dgx_spark.py::test_cli_contract_is_observable tests/test_deploy_dgx_spark.py::test_validation_failure_is_logged_before_exit tests/test_deploy_dgx_spark.py::test_required_discovery_probe_failure_is_logged tests/test_deploy_dgx_spark.py::test_err_trap_records_post_log_failure_metadata tests/test_deploy_dgx_spark.py::test_err_trap_redacts_secret_like_command_context -q
```

**Step 3: Implement**
- Parse and validate required CLI choices before host-dependent phases.
- Define stable exit status `2` for usage/required validation failures.
- Use `SCRIPT_DIR` for all library sourcing and derived paths.
- Install an ERR trap that does not recursively fail while logging.
- Redact command context before printing/writing logs.

**Step 4: Run GREEN**

```bash
pytest tests/test_deploy_dgx_spark.py::test_cli_contract_is_observable tests/test_deploy_dgx_spark.py::test_validation_failure_is_logged_before_exit tests/test_deploy_dgx_spark.py::test_required_discovery_probe_failure_is_logged tests/test_deploy_dgx_spark.py::test_err_trap_records_post_log_failure_metadata tests/test_deploy_dgx_spark.py::test_err_trap_redacts_secret_like_command_context -q
```

**Step 5: Commit**

```bash
git add scripts/deploy-dgx-spark.sh tests/test_deploy_dgx_spark.py
git commit -m "fix(dgx-spark): stabilize CLI validation and error logging"
```

### Task 9: Add explicit host-probe injection for tests

**Files:**
- Modify: `scripts/deploy-dgx-spark.sh`
- Test: `tests/test_deploy_dgx_spark.py`

**Step 1: Add tests**
- A dry run with an injected compatible ARM64/GB10 probe passes on x86_64.
- Production execution without injection still rejects x86_64.
- A fake failing `nvidia-smi` reaches the discovery failure gate instead of architecture mismatch.

**Step 2: Run RED**

```bash
pytest tests/test_deploy_dgx_spark.py::test_dry_run_is_observable_without_real_services tests/test_deploy_dgx_spark.py::test_required_discovery_probe_failure_is_logged -q
```

**Step 3: Implement**
- Add test-only/environment-controlled probe seams for `uname`, GPU query, Python, Docker, and CUDA checks, clearly named and disabled by default.
- Do not change the real default requirement for ARM64 and GB10.
- Ensure dry-run creates only the expected log/state observation artifacts; it does not create model files, services, or venvs.

**Step 4: Run GREEN**

```bash
pytest tests/test_deploy_dgx_spark.py::test_dry_run_is_observable_without_real_services tests/test_deploy_dgx_spark.py::test_required_discovery_probe_failure_is_logged -q
```

**Step 5: Commit**

```bash
git add scripts/deploy-dgx-spark.sh tests/test_deploy_dgx_spark.py
git commit -m "test(dgx-spark): inject compatible host probes for dry runs"
```

### Task 10: Implement `--model-root` and `--verbose`

**Files:**
- Modify: `scripts/deploy-dgx-spark.sh`
- Test: `tests/test_deploy_dgx_spark.py`

**Step 1: Add tests**
- `--model-root PATH` is accepted and appears in planned output/state.
- `--verbose` is accepted and emits verbose diagnostics.
- Both work in non-interactive dry-run mode.

**Step 2: Run RED**

```bash
pytest tests/test_deploy_dgx_spark.py::test_plan_cli_options_are_accepted -q
```

**Step 3: Implement**
- Add `VERBOSE=false` and parse `--verbose`.
- Emit verbose lines only when enabled.
- Ensure `MODEL_ROOT` is assigned after argument parsing and is used consistently by model acquisition.

**Step 4: Run GREEN**

```bash
pytest tests/test_deploy_dgx_spark.py::test_plan_cli_options_are_accepted -q
```

**Step 5: Commit**

```bash
git add scripts/deploy-dgx-spark.sh tests/test_deploy_dgx_spark.py
git commit -m "feat(dgx-spark): expose model-root and verbose CLI options"
```

### Task 11: Implement safe `--reset`

**Files:**
- Modify: `scripts/deploy-dgx-spark.sh`
- Test: `tests/test_deploy_dgx_spark.py`

**Step 1: Add tests**
- `--dry-run --reset` returns 2, reports incompatible options, and does not mutate.
- `--reset --yes` removes only a normal deployment root.
- Reset rejects a symlink root.
- Reset rejects a symlinked parent.
- Reset never removes the repository or separately configured model root.
- Interactive reset requires confirmation unless `--yes` is present.

**Step 2: Run RED**

```bash
pytest tests/test_deploy_dgx_spark.py::test_dry_run_reset_is_rejected_without_mutation tests/test_deploy_dgx_spark.py::test_reset_refuses_symlink_root_without_touching_target tests/test_deploy_dgx_spark.py::test_reset_refuses_symlink_parent_without_touching_target -q
```

**Step 3: Implement**
- Parse `--reset`.
- Validate option combinations before any host/layout phase.
- Resolve and inspect every existing path component with `test -L`.
- Require confirmation unless `AUTO_YES=true`.
- Remove only the selected deployment root with a bounded, non-following path operation.
- Exit 0 on successful reset and 2 on refusal/invalid combination.

**Step 4: Run GREEN**

```bash
pytest tests/test_deploy_dgx_spark.py::test_dry_run_reset_is_rejected_without_mutation tests/test_deploy_dgx_spark.py::test_reset_refuses_symlink_root_without_touching_target tests/test_deploy_dgx_spark.py::test_reset_refuses_symlink_parent_without_touching_target -q
```

**Step 5: Commit**

```bash
git add scripts/deploy-dgx-spark.sh tests/test_deploy_dgx_spark.py
git commit -m "feat(dgx-spark): add guarded deployment reset"
```

### Task 12: Workstream-3 checkpoint

```bash
bash -n scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh
pytest tests/test_deploy_dgx_spark.py -q
git add scripts tests
git commit -m "checkpoint(dgx-spark): complete CLI and test-host contract"
git push origin repair/dgx-spark-deployment-wizard
git rev-parse HEAD
```

Record the SHA before proceeding.

---

## Workstream 4: Manifest, lifecycle health, ordered startup, and cleanup

### Task 13: Add manifest data collection and atomic writer

**Files:**
- Modify: `scripts/deploy-dgx-spark-lib.sh`
- Modify: `scripts/deploy-dgx-spark.sh`
- Modify: `tests/test_deploy_dgx_spark.py`

**Step 1: Add tests**
- A complete run writes `state/deployment-manifest.json`.
- Manifest is valid JSON, has no known secret values, and includes profile, deployment root, host facts, revisions, model records, service ports, artifact paths, and test results.
- Every referenced artifact exists.
- Failed runs write state but do not claim a complete manifest.

**Step 2: Run RED**

```bash
pytest -q -k "manifest"
```

Expected: no manifest writer or missing manifest assertion.

**Step 3: Implement**
- Add a manifest builder using explicit JSON fields, not unsafe string concatenation.
- Reuse `json_write_atomic`.
- Capture only redacted command output and declared metadata.
- Call the writer after all required smoke tests and lifecycle generation pass.

**Step 4: Run GREEN**

```bash
pytest -q -k "manifest"
```

**Step 5: Commit**

```bash
git add scripts tests
git commit -m "feat(dgx-spark): write validated deployment manifest"
```

### Task 14: Generate and test `bin/health-check`

**Files:**
- Modify: `scripts/deploy-dgx-spark-lib.sh`
- Modify: `tests/test_deploy_dgx_spark.py`

**Step 1: Add tests**
- Lifecycle generation creates executable `bin/health-check`.
- It checks ComfyUI readiness and TTS availability using absolute paths/configuration.
- Generated script passes `bash -n` and reports non-zero when a required service is unavailable.

**Step 2: Run RED**

```bash
pytest -q -k "health_check or lifecycle"
```

**Step 3: Implement**
- Generate the script alongside `status` and start/stop scripts.
- Use deployment-root logs, PID files, and readiness endpoints.
- Never embed secrets.

**Step 4: Run GREEN**

```bash
pytest -q -k "health_check or lifecycle"
bash -n scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh
```

**Step 5: Commit**

```bash
git add scripts tests
git commit -m "feat(dgx-spark): generate lifecycle health check"
```

### Task 15: Implement ordered startup and bounded cleanup

**Files:**
- Modify: `scripts/deploy-dgx-spark-lib.sh`
- Modify: `scripts/deploy-dgx-spark.sh`
- Modify: `tests/test_deploy_dgx_spark.py`

**Step 1: Add tests**
- ComfyUI starts first and must become ready before TTS starts.
- PID files and per-service logs are written.
- A ComfyUI failure prevents TTS startup.
- A later failure stops only PIDs started by the current run.
- Existing unrelated service/PID files are not touched.

**Step 2: Run RED**

```bash
pytest -q -k "startup or cleanup or readiness"
```

**Step 3: Implement**
- Add explicit `started_pids` tracking.
- Start ComfyUI, call readiness, then start TTS and call TTS readiness.
- Add EXIT/ERR cleanup trap guarded against recursion.
- Preserve logs and failed state before cleanup.
- Update the main script to call the new signatures, including `deploy_root`.

**Step 4: Run GREEN**

```bash
pytest -q -k "startup or cleanup or readiness"
```

**Step 5: Commit**

```bash
git add scripts tests
git commit -m "feat(dgx-spark): order services and clean up current-run processes"
```

### Task 16: Workstream-4 checkpoint

```bash
bash -n scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh
pytest tests/test_deploy_dgx_spark.py -q
git add scripts tests
git commit -m "checkpoint(dgx-spark): complete manifest and lifecycle integration"
git push origin repair/dgx-spark-deployment-wizard
git rev-parse HEAD
```

Record the SHA before proceeding.

---

## Workstream 5: Hermes documentation and final acceptance

### Task 17: Update skill documentation and dry-run contract

**Files:**
- Locate and modify the DGX Spark deployment section in the repository `SKILL.md`.
- Modify: `tests/test_deploy_dgx_spark.py` if documentation checks are added.

**Step 1: Add tests/checks**
- Documented command contains exact profile/model/backend flags.
- Documentation names dry-run, logs, state, manifest, reset, health-check, and recovery behavior.
- No unresolved placeholders remain.

**Step 2: Run RED**

```bash
python3 - <<'PY'
from pathlib import Path
text = next(Path('.').rglob('SKILL.md')).read_text()
required = ['deploy-dgx-spark.sh', '--dry-run', 'deployment-manifest.json', 'health-check']
missing = [x for x in required if x not in text]
assert not missing, missing
PY
```

**Step 3: Implement**
- Document interactive and non-interactive invocation, prerequisites, paths, logs, reset safeguards, and Hermes terminal/SSH usage.
- Preserve existing media-generation/OpenClaw compatibility metadata unless intentionally changed.

**Step 4: Run GREEN**

```bash
python3 - <<'PY'
from pathlib import Path
text = next(Path('.').rglob('SKILL.md')).read_text()
required = ['deploy-dgx-spark.sh', '--dry-run', 'deployment-manifest.json', 'health-check']
assert not [x for x in required if x not in text]
PY
```

**Step 5: Commit and push checkpoint**

```bash
git add SKILL.md docs
git commit -m "docs(dgx-spark): document deployment and recovery contract"
git push origin repair/dgx-spark-deployment-wizard
git rev-parse HEAD
```

### Task 18: Full local verification

Run exactly:

```bash
bash -n scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh
python3 -m py_compile tests/test_deploy_dgx_spark.py
pytest tests/test_deploy_dgx_spark.py -q
```

Then verify generated scripts in a temporary deployment root and parse any produced JSON with `python3 -m json.tool`.

Expected: all tests pass, both Bash scripts parse, and generated scripts parse.

Commit/push the verification checkpoint:

```bash
git add scripts tests docs SKILL.md
git commit -m "checkpoint(dgx-spark): pass local remediation verification"
git push origin repair/dgx-spark-deployment-wizard
git rev-parse HEAD
```

### Task 19: DGX Spark integration validation

Run on the actual DGX Spark over the approved SSH path, without exposing credentials:

```bash
uname -m
nvidia-smi --query-gpu=name,memory.total,compute.cap,driver_version --format=csv,noheader
bash -n scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh
scripts/deploy-dgx-spark.sh \
  --profile minimal \
  --image-model juggernaut-xl-v10 \
  --tts-backend piper \
  --dry-run \
  --non-interactive \
  --yes
```

Then, only after the dry run passes and prerequisites are confirmed, run the minimal native deployment and verify:

```bash
$CLAWDESS_DEPLOY_ROOT/bin/health-check
$CLAWDESS_DEPLOY_ROOT/bin/status
python3 -m json.tool "$CLAWDESS_DEPLOY_ROOT/state/deployment-manifest.json"
test -s "$CLAWDESS_DEPLOY_ROOT/artifacts/smoke_test.wav"
find "$CLAWDESS_DEPLOY_ROOT/artifacts" -type f -name '*.png' -size +0c
```

Record exact command results, artifact paths, and manifest path without recording secrets.

### Task 20: Independent review and final GitHub checkpoint

Review the complete diff against the design and acceptance criteria. Confirm:

- no unrelated changes;
- no secrets in logs/manifests;
- no unsafe reset path handling;
- no production weakening of ARM64/GB10 validation;
- all checkpoint commits are present on the remote;
- final tests and DGX evidence are real and current.

Run:

```bash
git status --short --branch
git log --oneline --decorate -12
git diff origin/main...HEAD --stat
git push origin repair/dgx-spark-deployment-wizard
```

Create the final checkpoint only after all gates pass:

```bash
git commit --allow-empty -m "checkpoint(dgx-spark): complete deployment wizard remediation"
git push origin repair/dgx-spark-deployment-wizard
git rev-parse HEAD
```

## Execution order and recovery

Execute tasks serially. If a task fails, keep the failing evidence, correct the root cause, rerun the focused test, then rerun the relevant workstream suite before committing. If the session ends, resume from the latest pushed checkpoint SHA using:

```bash
git fetch origin repair/dgx-spark-deployment-wizard
git checkout repair/dgx-spark-deployment-wizard
git reset --hard origin/repair/dgx-spark-deployment-wizard
```

Do not claim completion from a local-only commit or from a test run that was not actually executed.
