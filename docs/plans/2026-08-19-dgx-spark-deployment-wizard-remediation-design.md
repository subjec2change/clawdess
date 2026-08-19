# DGX Spark Deployment Wizard Remediation Design

**Date:** 2026-08-19
**Branch:** `repair/dgx-spark-deployment-wizard`
**Status:** Approved

## Goal

Make the DGX Spark deployment wizard test suite fully green, implement the remaining deployment-contract gaps, and preserve recoverable progress through frequent local commits and GitHub checkpoint pushes.

## Scope

This remediation covers:

1. All 26 currently failing tests, including genuine implementation defects, test-fixture defects, shell-test harness defects, and platform-dependent assumptions.
2. Remaining wizard contract gaps: manifest generation, health-check lifecycle script, reset safety, verbose/model-root CLI options, ordered startup, cleanup, and complete state handling.
3. Testable Hermes documentation and dry-run behavior.
4. Final validation on the actual ARM64 DGX Spark.

The x86_64 development host will not be treated as a DGX Spark. Tests will inject compatible host probes where needed; production host validation will continue enforcing ARM64/GB10 requirements.

## Architecture

The existing Bash entry point remains responsible for CLI parsing, phase ordering, traps, logging, and exit codes. Shared behavior remains in `scripts/deploy-dgx-spark-lib.sh`. Python tests continue to execute isolated Bash snippets through overridable probe seams.

State is written atomically beneath the selected deployment root. A complete manifest is generated only after required gates pass; failed and partial runs retain redacted state and recovery information. Generated lifecycle scripts use absolute deployment-root paths and service-specific logs.

## Workstreams

### 1. Test and harness stabilization

Repair test fixtures and helper APIs first, then fix low-level shell behavior exposed by the tests: capability normalization, URL redaction, JSON atomic writes, probe seams, state-root conventions, and script-relative library loading.

### 2. Core implementation correctness

Fix model acquisition selection, disk thresholds, download/checksum failure propagation, structured state persistence, and deterministic validation exit codes. Preserve secret redaction and avoid weakening production checks.

### 3. Deployment contract completion

Implement `--model-root`, `--verbose`, safe `--reset`, manifest generation, `bin/health-check`, ordered ComfyUI/TTS startup, service PID tracking, cleanup traps, and complete dry-run semantics.

### 4. Acceptance and platform verification

Run syntax checks, the complete Python suite, generated-script checks, and the canonical dry-run with injected compatible probes. Then run the real minimal-profile readiness and smoke tests on the DGX Spark, review the diff independently, and push the final verified state.

## Checkpoint policy

Every workstream ends with:

1. focused tests and syntax checks;
2. a descriptive commit;
3. verification that the commit exists locally;
4. push to `origin/repair/dgx-spark-deployment-wizard`;
5. recording the pushed commit SHA in the task log.

If the FUSE-mounted remote is unavailable, the clean local clone at `/tmp/clawdess-gh` is the authoritative GitHub checkout for commits and pushes. No completion claim will rely on an unverified push.

## Error handling and safety

- Reset must require explicit confirmation unless `--yes` is supplied, reject deployment-root symlinks and symlinked parents, and never touch the repository or separately configured model root.
- Cleanup stops only services started by the current invocation.
- Secrets remain in environment or user-managed files and are never copied to manifests, logs, or command output.
- Required failures exit non-zero and persist redacted failed state.
- Optional profile failures remain explicit and cannot be reported as successful.

## Testing strategy

Use TDD for every behavior: add one focused failing test, run it to verify the expected failure, implement the smallest change, run the focused test and full suite, then commit. Unit tests use temporary directories and injected command seams. DGX-specific checks are separate integration gates and are not faked by changing production host validation.

## Acceptance criteria

- All tests in `tests/test_deploy_dgx_spark.py` pass.
- Both deployment scripts pass `bash -n`.
- CLI supports documented `--profile`, `--image-model`, `--tts-backend`, `--model-root`, `--verbose`, `--dry-run`, `--non-interactive`, `--yes`, and safe `--reset` behavior.
- Complete runs produce a secret-free, parseable manifest referencing existing artifacts.
- Generated lifecycle scripts include `health-check` and pass syntax checks.
- Required service startup is ordered and cleanup is bounded to current-run services.
- The canonical dry run works under injected compatible probes without model/service mutation.
- Actual minimal-profile readiness and smoke tests pass on the DGX Spark.
- Each workstream has a pushed GitHub checkpoint.
