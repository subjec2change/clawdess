# DGX Spark / Clawdess Full Roadmap Design

**Date:** 2026-08-22  
**Branch:** `repair/dgx-spark-deployment-wizard`  
**Status:** Design approved for specification review; implementation not started

## Goal

Complete the DGX Spark deployment and Clawdess media roadmap while keeping capability claims truthful, validating locally on the native GB10 where possible, and treating external-provider generation as blocked unless credentials and runtime access are explicitly available.

The roadmap uses staged vertical slices. Each slice has focused tests, independent review, a checkpoint commit, and an acceptance status that distinguishes verified behavior from dry-run, experimental, deferred, or blocked behavior.

## Capability boundary

The verified local MVP consists of:

- GB10 host detection and deployment prerequisites
- deployment layout and persisted state
- local image model selection/acquisition seams
- local Piper voice support
- lifecycle scripts and cleanup
- dry-run behavior
- provider-independent automated tests

The following remain non-verified until their acceptance gates pass:

- local Wan2GP or other video runtime generation
- Kokoro runtime
- XTTS-v2 runtime
- truly remote-only deployment
- external provider image/video generation
- identity consistency across providers
- uncensored or production-readiness claims

Capability state values are explicit: `verified`, `experimental`, `deferred`, `unavailable`, and `blocked`.

## Workstreams

### WS0 — Baseline reconciliation

Before feature work:

1. Compare the authoritative local branch, remote branch, working tree, and recent commits.
2. Preserve all existing user modifications and pre-existing untracked files.
3. Identify divergence between local and remote without resetting or discarding work.
4. Run the existing focused and full test baselines plus shell syntax checks.
5. Create a checkpoint only for intentional reconciliation or approved feature work.

Only explicitly scoped tracked files may be staged. Unrelated untracked files must remain untouched.

### WS1 — Truthful capability model

Make capability and provider state explicit in deployment manifests, state transitions, CLI output, and documentation.

Requirements:

- Separate provider mode from local dependencies.
- Record selected features and their capability state.
- Keep failures nonzero and stateful when a requested experimental/deferred feature cannot run.
- Prevent a dry-run or generated artifact from being described as a successful runtime deployment.
- Document the verified MVP and all deferred boundaries.

Acceptance:

- Focused tests cover each status and relevant state transition.
- Existing minimal photo/Piper behavior remains compatible.
- Remote mode behavior is observable and unambiguous.

### WS2 — Native GB10 video preflight and runtime validation

Use a temporary deployment root and provider-independent checks first.

Validation levels:

1. Video provisioning seam exists.
2. Required runtime dependencies are present or installable through the existing contract.
3. Service starts successfully.
4. Health check passes.
5. A minimal image-to-video job produces a real output artifact.

Only the highest completed level may be reported. If prerequisites are absent, report the exact blocker and retain a deferred/blocked state rather than fabricating success.

Acceptance:

- Automated tests cover preflight, lifecycle, health failure, and state persistence.
- Native DGX checks record architecture, GPU, CUDA, Docker/socket, disk, and memory evidence where available.
- A real video artifact is required before claiming video runtime verification.

### WS3 — Remote-provider semantics

Define remote mode as remote inference/model acquisition behavior, not automatically local-free behavior.

Requirements:

- Skip local model acquisition when the selected capability is delegated remotely.
- Install/start local support services only when explicitly selected or required.
- Record local dependencies separately from provider selection.
- Fail early for unsupported remote capabilities where possible.
- Never describe remote mode as local-free unless the manifest proves no local dependency was selected.

Acceptance:

- Tests cover remote/local feature combinations, skipped acquisition, state, and failure behavior.
- Documentation gives one canonical interpretation of `remote`.

### WS4 — Voice backend contract

Use a common catalog/runtime contract for Piper, Kokoro, and XTTS-v2:

- metadata and dependency groups,
- preflight/install seam,
- synthesis/runtime seam,
- health check,
- capability state,
- explicit failure behavior.

Piper remains verified. Kokoro may become verified only after a real local synthesis smoke test. XTTS-v2 remains deferred unless a complete, evidence-backed installation and runtime path is available. No model source, checksum, or readiness claim may be invented.

Acceptance:

- Tests cover catalog resolution, unsupported/deferred behavior, and failure propagation.
- Real local synthesis is required for any backend status change to verified.

### WS5 — Hermes reference-image workflow

Preserve URL support and add safe local-path handling at the CLI/provider boundary without claiming external upload success.

Requirements:

- Accept `http(s)` URLs.
- Validate local image paths before use.
- Reject missing paths, directories, unsupported schemes, unsupported image types, and oversized files.
- Keep local references local unless an explicit provider adapter requires upload.
- Define temporary upload/cleanup boundaries for future adapters.
- Never persist identity references unintentionally.
- Distinguish local Hermes attachments, hosted reference URLs, and generated photo URLs used as video inputs.

Acceptance:

- Unit tests cover validation and path/URL routing.
- CLI help and Clawdess skill instructions document the two supported input forms.
- Provider-dependent generation remains clearly blocked when credentials are absent.

### WS6 — Final integration and acceptance

Run the full Python suite, focused regressions, shell syntax checks, generated-script syntax assertions, `git diff --check`, CLI discovery, and native DGX preflight. Run runtime smoke tests only when prerequisites are present.

Review gates:

1. Implementer verifies TDD red-green behavior.
2. Independent spec reviewer checks exact roadmap compliance.
3. Independent quality reviewer checks scope, error handling, dead code, and truthfulness.
4. Final parent-agent verification reconciles all reports against the live checkout.

The final report must separate verified, dry-run verified, experimentally exercised, deferred, and blocked results.

## Data flow

```text
CLI selection
  -> feature/provider/model resolution
  -> capability preflight
  -> deployment state: planned/running/partial/failed/complete
  -> acquisition and service lifecycle
  -> health/smoke evidence
  -> manifest with provider, local dependencies, capability states
```

For media references:

```text
Hermes attachment or URL
  -> input validation
  -> local-path preservation or explicit provider adapter
  -> photo output URL/artifact
  -> optional video input
  -> result and evidence state
```

## Error handling

- Invalid input fails before side effects.
- Missing external credentials produces a clear blocked result, not a fake provider response.
- Deferred/experimental runtimes fail explicitly when selected but unavailable.
- Partial deployments persist `partial` state and retain cleanup metadata.
- Cleanup is idempotent and must not terminate the test runner or unrelated processes.
- Invalid state payloads preserve the prior valid destination.
- Every acceptance claim must be backed by command output, a real artifact, or a passing focused test.

## Testing strategy

Each behavior follows strict TDD:

1. Write one focused failing test.
2. Run it and confirm the expected failure.
3. Implement the smallest behavior.
4. Run the focused test and then the relevant suite.
5. Refactor only while green.

Required verification commands at final integration:

```bash
bash -n scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh
.venv/bin/python -m pytest -q
git diff --check
```

Generated executable shell scripts must also be checked with `bash -n`.

## Non-goals

- No fabricated checksums, dependency versions, provider responses, or runtime readiness.
- No claim that a model is uncensored.
- No claim of production reliability or cross-provider identity preservation.
- No reset, force-push, history rewrite, or staging of unrelated files.
- No provider credential creation or secret handling by the agent.
