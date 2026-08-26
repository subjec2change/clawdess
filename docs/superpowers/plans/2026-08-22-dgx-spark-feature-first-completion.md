# DGX Spark Feature-First Wizard Completion Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete and verify model acquisition, feature-first selection, catalog consistency, documentation alignment, and remote GitHub synchronization for the DGX Spark deployment wizard.

**Architecture:** Preserve the existing Bash entry point and shared library. First restore the model-record/acquisition seam for both legacy and nested catalogs. Then wire profile/provider/model resolution into Phase 5 while preserving explicit CLI overrides. Update tests and docs only after behavior is verified.

**Tech Stack:** Bash 5, Python 3 JSON helpers, pytest, SSH to DGX Spark, GitHub remote.

## Global Constraints

- Work on `repair/dgx-spark-deployment-wizard`.
- Preserve unrelated untracked files and do not commit `.venv/`, `typescript`, or unrelated deployment guides.
- Keep model downloads atomic and never expose credentials.
- Preserve legacy `--image-model` and `--tts-backend` compatibility.
- Minimal profile must not require Docker.
- Every workstream must pass its focused tests before commit/push.

---

### Task 1: Repair model-record and acquisition compatibility

**Files:**
- Modify: `scripts/deploy-dgx-spark-lib.sh`
- Modify: `config/dgx-spark-models.json`
- Test: `tests/test_deploy_dgx_spark.py`

- [ ] Remove shell-interpreted backticks from inline Python comments or convert the Python block to a single-quoted heredoc-safe invocation.
- [ ] Make `model_records()` resolve nested `models`, legacy flat entries, backend aliases, and subdir-to-list file entries.
- [ ] Make `acquire_models()` consume `subdir`, create destination directories, and persist failure state.
- [ ] Add/adjust focused regression tests for image + Piper records and dry-run planning.
- [ ] Run the focused acquisition tests and Bash syntax checks.
- [ ] Commit and push only the intended acquisition/config/test files; verify the remote SHA.

### Task 2: Complete feature-first catalog and CLI wiring

**Files:**
- Modify: `config/dgx-spark-models.json`
- Modify: `scripts/deploy-dgx-spark-lib.sh`
- Modify: `scripts/deploy-dgx-spark.sh`
- Test: `tests/test_dgx_spark_ac_gaps.py`

- [ ] Make feature metadata, profiles, model keys, and backend aliases internally consistent.
- [ ] Preserve explicit CLI overrides and resolve profile defaults.
- [ ] Wire feature/provider/model selection into Phase 5 without prompting in non-interactive mode.
- [ ] Add summary/confirmation behavior for interactive mode and honor `--yes`.
- [ ] Add regression tests for minimal/media/assistant/all profiles and unknown selections.
- [ ] Run focused selector and CLI tests.
- [ ] Commit and push the verified selector work; verify the remote SHA.

### Task 3: Align documentation and acceptance evidence

**Files:**
- Modify: `docs/superpowers/specs/2026-08-18-dgx-spark-deployment-design.md`
- Modify: `docs/plans/2026-08-19-dgx-spark-deployment-wizard-remediation.md`
- Create/modify: `docs/plans/2026-08-21-feature-first-model-selector.md`
- Modify: `scripts/deploy-dgx-spark.sh` usage/help text if required

- [ ] Document verified versus experimental profiles and feature-first behavior.
- [ ] Document catalog schema, aliases, multi-file model paths, and non-interactive requirements.
- [ ] Remove stale claims that contradict the current implementation.
- [ ] Verify documentation references exact current flags and paths.
- [ ] Commit and push documentation after code behavior is green.

### Task 4: Full verification and hardware dry run

**Files:** No source changes unless verification finds a regression.

- [ ] Run Bash syntax checks for changed scripts.
- [ ] Generate lifecycle artifacts and run `bash -n` on every generated shell script.
- [ ] Run the complete pytest suite in the DGX `.venv`.
- [ ] Run the minimal no-Docker DGX Spark dry run.
- [ ] Run profile-specific dry-run checks where prerequisites allow.
- [ ] Audit the diff for secrets and unrelated files.
- [ ] Commit any final verified fixes, push, and verify branch SHA/status against origin.
