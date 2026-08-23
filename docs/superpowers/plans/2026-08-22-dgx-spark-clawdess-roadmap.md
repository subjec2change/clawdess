# DGX Spark / Clawdess Full Roadmap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement and validate the staged DGX Spark/Clawdess roadmap without overstating runtime, provider, or identity capabilities.

**Architecture:** Keep the existing shell deployment wizard and Python media CLI boundaries. Add explicit capability metadata/state, provider-mode semantics, provider-independent input validation, and native DGX validation scripts/tests without claiming external generation success. Work proceeds as small TDD slices with a spec review and quality review after each task.

**Tech Stack:** Bash 5+, Python 3.11+, pytest, JSON manifests, Docker/ComfyUI/Piper/Wan2GP where available on the DGX.

## Global Constraints

- The verified local MVP is GB10 detection, deployment state/layout, local image seams, Piper, lifecycle/cleanup, dry-run, and provider-independent tests.
- Video runtime, Kokoro, XTTS-v2, truly remote-only deployment, external provider generation, identity consistency, uncensored behavior, and production readiness remain unverified until explicit gates pass.
- Capability states are `verified`, `experimental`, `deferred`, `unavailable`, and `blocked`.
- No fabricated checksums, dependency versions, provider responses, or runtime readiness.
- Preserve unrelated modified and untracked files; stage only explicit task files.
- Every behavior follows RED → GREEN → REFACTOR; run the focused test before the broader suite.
- Do not create, print, or commit secrets.

---

## Task 1: Reconcile baseline and establish evidence

**Files:**
- Modify only files required to reconcile the authoritative branch; do not reset or discard existing work.
- Test: existing `tests/test_deploy_dgx_spark.py` and `tests/test_dgx_spark_ac_gaps.py`

**Interfaces:**
- Consumes: current local branch, `origin/repair/dgx-spark-deployment-wizard`, current working tree.
- Produces: verified baseline report and an intentional checkpoint only if reconciliation changes are required.

- [ ] **Step 1: Capture branch and working-tree evidence**

Run:

```bash
git status --short
git branch --show-current
git log --oneline -8
git rev-parse HEAD
git ls-remote origin refs/heads/repair/dgx-spark-deployment-wizard
```

Do not stage `.venv/`, `typescript`, existing docs/plans, or any unrelated file.

- [ ] **Step 2: Run the baseline tests and shell checks**

Run:

```bash
.venv/bin/python -m pytest -q
bash -n scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh
git diff --check
```

Expected: record exact pass/fail output; do not convert a failure into a claim of success.

- [ ] **Step 3: Reconcile only intentional branch divergence**

If local commits are ahead of remote and contain approved work, preserve them. If remote has commits absent locally, inspect with `git log HEAD..origin/repair/dgx-spark-deployment-wizard --oneline` and stop for conflict resolution rather than resetting. Create no merge commit unless explicitly required by the live graph.

- [ ] **Step 4: Commit only an approved reconciliation**

If no reconciliation is needed, do not create an empty commit. If a required change is made, stage explicit paths and commit with a message describing that change.

---

## Task 2: Add explicit capability-state primitives

**Files:**
- Modify: `scripts/deploy-dgx-spark-lib.sh` in state/manifest and feature-resolution functions
- Modify: `scripts/deploy-dgx-spark.sh` in phase/status reporting
- Test: `tests/test_dgx_spark_ac_gaps.py`
- Test: `tests/test_deploy_dgx_spark.py`
- Modify: `SKILL.md` only for the verified/experimental/deferred user-facing contract

**Interfaces:**
- Consumes: existing `state_write`, feature selection, provider/model resolution, deployment manifest generation.
- Produces: a stable capability-state mapping in persisted state/manifest data; existing callers remain valid when no new state is supplied.

- [ ] **Step 1: Write a failing test for capability-state persistence**

Add a test that invokes the existing state/manifest seam with one verified feature and one deferred feature, then asserts the serialized result contains the exact status strings and selected provider separately.

- [ ] **Step 2: Run the focused test**

```bash
.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py -k capability -q
```

Expected: FAIL because capability states are not yet emitted by the target seam.

- [ ] **Step 3: Implement the smallest state/manifest extension**

Use the existing JSON atomic-write path. Preserve old fields and add only the capability mapping and provider/local-dependency separation required by the test. Do not change unrelated lifecycle behavior.

- [ ] **Step 4: Add failure-state coverage**

Write a failing test for selecting a deferred/unavailable feature in non-dry-run mode. Assert nonzero exit, persisted `failed` or `partial` state as appropriate, and an explicit message containing the capability and status.

- [ ] **Step 5: Implement and run focused tests**

```bash
.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py -k 'capability or deferred' -q
.venv/bin/python -m pytest tests/test_deploy_dgx_spark.py -q
```

- [ ] **Step 6: Commit**

```bash
git add scripts/deploy-dgx-spark-lib.sh scripts/deploy-dgx-spark.sh tests/test_dgx_spark_ac_gaps.py tests/test_deploy_dgx_spark.py SKILL.md
git commit -m "feat(dgx-spark): expose truthful capability states"
```

---

## Task 3: Make remote-provider semantics explicit

**Files:**
- Modify: `scripts/deploy-dgx-spark.sh` provider/feature gating
- Modify: `scripts/deploy-dgx-spark-lib.sh` acquisition/service dependency metadata
- Test: `tests/test_deploy_dgx_spark.py`
- Test: `tests/test_dgx_spark_ac_gaps.py`
- Modify: `SKILL.md`

**Interfaces:**
- Consumes: Task 2 capability mapping and existing provider selection.
- Produces: remote mode that records provider mode independently from local dependencies and skips only the local work delegated remotely.

- [ ] **Step 1: Write failing remote/local matrix tests**

Cover at least:

```text
remote + photo: skip local image acquisition, record remote provider
remote + voice: retain Piper only if explicitly selected
remote + video: do not claim local-free operation; report unsupported/deferred local dependency
local + photo/video/voice: preserve existing local behavior
```

Assert calls/state rather than implementation details.

- [ ] **Step 2: Run the focused tests and confirm expected failure**

```bash
.venv/bin/python -m pytest tests/test_deploy_dgx_spark.py -k remote -q
```

- [ ] **Step 3: Implement minimal explicit gating**

Gate model acquisition and local service setup using the selected feature/provider matrix. Keep a manifest field for local dependencies. Do not silently skip required local support services.

- [ ] **Step 4: Add documentation test/contract assertions**

Assert the skill documentation says remote inference is not automatically local-free and that local dependencies are reported separately.

- [ ] **Step 5: Verify and commit**

```bash
.venv/bin/python -m pytest tests/test_deploy_dgx_spark.py tests/test_dgx_spark_ac_gaps.py -q
git diff --check
git add scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh tests/test_deploy_dgx_spark.py tests/test_dgx_spark_ac_gaps.py SKILL.md
git commit -m "feat(dgx-spark): clarify remote provider semantics"
```

---

## Task 4: Add native GB10 video preflight and evidence capture

**Files:**
- Create: `scripts/check-dgx-video-runtime.sh`
- Modify: `scripts/deploy-dgx-spark-lib.sh` only where existing video preflight seams are reused
- Test: `tests/test_dgx_spark_ac_gaps.py`
- Test: `tests/test_deploy_dgx_spark.py`
- Documentation: `SKILL.md`

**Interfaces:**
- Consumes: existing video catalog/provisioning and deployment-root/state conventions.
- Produces: provider-independent preflight output with explicit level/status and blocker text; no fake successful artifact.

- [ ] **Step 1: Write failing seam tests**

Test missing Docker, missing model/dependency paths, unavailable service, passing health check, and state/artifact evidence. Assert each result reports the highest reached validation level only.

- [ ] **Step 2: Run focused tests and confirm failure**

```bash
.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py -k 'video and preflight' -q
```

- [ ] **Step 3: Implement the preflight script**

The script must:

- use `set -euo pipefail`,
- accept an optional deployment root,
- inspect architecture, GPU command availability, CUDA evidence, Docker/socket availability, disk, and memory,
- emit stable machine-readable lines,
- return nonzero when required checks fail,
- never download credentials or fabricate runtime evidence.

- [ ] **Step 4: Add generated-script syntax checks**

Generate lifecycle scripts under a temporary root and run `bash -n` on every generated executable shell file.

- [ ] **Step 5: Verify and commit**

```bash
bash -n scripts/check-dgx-video-runtime.sh scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh
.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py tests/test_deploy_dgx_spark.py -q
git add scripts/check-dgx-video-runtime.sh scripts/deploy-dgx-spark-lib.sh tests/test_dgx_spark_ac_gaps.py tests/test_deploy_dgx_spark.py SKILL.md
git commit -m "feat(dgx-spark): add truthful video runtime preflight"
```

---

## Task 5: Formalize voice backend gates

**Files:**
- Modify: `scripts/deploy-dgx-spark-lib.sh` voice catalog/runtime seams
- Modify: `config/dgx-spark-models.json`
- Test: `tests/test_dgx_spark_ac_gaps.py`
- Modify: `SKILL.md`

**Interfaces:**
- Consumes: existing Piper/Kokoro/XTTS metadata and resolver functions.
- Produces: backend status, preflight outcome, and explicit failure behavior through one stable seam.

- [ ] **Step 1: Write failing tests for backend status and failure**

Assert Piper is `verified` only on the existing supported path, Kokoro returns `experimental` with nonzero unavailable behavior, and XTTS-v2 returns `deferred` with a clear nonzero result. Assert unsupported vLLM remains rejected.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py -k 'voice or kokoro or xtts' -q
```

- [ ] **Step 3: Implement the common backend result contract**

Return structured status/reason fields from existing seams. Preserve Piper behavior and aliases. Do not add unverified download sources or checksums.

- [ ] **Step 4: Add native Piper evidence hook**

On the DGX, run only the existing Piper smoke path and capture command output/artifact location. Do not mark Kokoro/XTTS verified without a real synthesis result.

- [ ] **Step 5: Verify and commit**

```bash
.venv/bin/python -m pytest tests/test_dgx_spark_ac_gaps.py tests/test_deploy_dgx_spark.py -q
git add scripts/deploy-dgx-spark-lib.sh config/dgx-spark-models.json tests/test_dgx_spark_ac_gaps.py SKILL.md
git commit -m "feat(dgx-spark): formalize voice backend capability gates"
```

---

## Task 6: Add safe local reference-image validation

**Files:**
- Modify: `scripts/clawdess.py`
- Modify: `scripts/common.py` if validation is shared by providers
- Test: create `tests/test_clawdess.py` for CLI/reference validation
- Modify: `SKILL.md`

**Interfaces:**
- Consumes: `photo` and `video` CLI `--image` argument; existing URL provider payloads.
- Produces: validated image reference object preserving URL strings or safe local paths; provider code receives the same semantic input without implicit upload claims.

- [ ] **Step 1: Locate existing media tests and provider image consumers**

Use `search_files` for `run_photo`, `run_video`, `args.image`, and provider payload construction. Do not invent a test module or provider interface before locating it.

- [ ] **Step 2: Write failing validation tests**

Cover:

- valid `https://` URL,
- valid local PNG/JPEG/WebP path,
- missing path,
- directory path,
- unsupported scheme such as `file://` if not explicitly supported,
- unsupported extension/content,
- configured maximum size.

- [ ] **Step 3: Run focused tests and confirm failure**

Run the exact newly added test node with pytest and confirm the failure is due to missing validation.

- [ ] **Step 4: Implement validation at the CLI/provider boundary**

Keep it small and dependency-light. Do not upload files, persist identity images, or change remote API payloads without a provider-specific adapter and tests. Return clear argparse/runtime errors before provider calls.

- [ ] **Step 5: Update CLI help and skill contract**

Document URL and local-path inputs, distinguish photo reference images from video source images, and state that provider credentials are still required for external generation.

- [ ] **Step 6: Verify and commit**

```bash
.venv/bin/python -m pytest tests/test_clawdess.py -q
python3 scripts/clawdess.py --help
python3 scripts/clawdess.py photo --help
python3 scripts/clawdess.py video --help
git add scripts/clawdess.py scripts/common.py tests/test_clawdess.py SKILL.md
git commit -m "feat(clawdess): validate local reference images"
```

---

## Task 7: Run native DGX acceptance and classify evidence

**Files:**
- Create only temporary evidence under a deployment temp root; do not add generated model/media artifacts to git.
- Modify documentation only for confirmed command results.

**Interfaces:**
- Consumes: Tasks 2–6 scripts, manifests, and test suites.
- Produces: exact acceptance record classified as verified, dry-run verified, experimental, deferred, or blocked.

- [ ] **Step 1: Run native preflight**

On the DGX, run the provider-independent checks and save output outside the repository. Capture architecture, GPU, CUDA, Docker/socket, disk, memory, and runtime dependency evidence.

- [ ] **Step 2: Run the minimal local MVP smoke test**

Use a temporary deployment root and the existing minimal profile. Verify actual state files, lifecycle scripts, health behavior, and Piper output where dependencies are installed.

- [ ] **Step 3: Attempt video only if preflight passes**

Do not download or start the video runtime if the prerequisite contract fails. If it passes, run the smallest supported image-to-video test and require a real output artifact before claiming level 5.

- [ ] **Step 4: Verify every generated shell script**

```bash
while IFS= read -r script; do bash -n "$script"; done < <(find "$TEMP_DEPLOY_ROOT/bin" -type f -perm -u+x -print)
```

- [ ] **Step 5: Record blockers without upgrading status**

A missing provider key, missing runtime package, unavailable model, or failed health check is recorded as blocked/deferred with the exact command/error, not as a passing smoke test.

---

## Task 8: Final review, GitHub checkpoint, and durable memory

**Files:**
- Only explicitly intended implementation/docs/tests from Tasks 2–7.

- [ ] **Step 1: Dispatch spec review**

Review the live diff against `docs/superpowers/specs/2026-08-22-dgx-spark-clawdess-roadmap-design.md`. Reject missing capability boundaries, unsupported claims, missing tests, and unrelated changes.

- [ ] **Step 2: Dispatch quality review**

Review for error handling, state safety, shell quoting, test isolation, dead code, YAGNI, secret leakage, and generated-script syntax coverage.

- [ ] **Step 3: Run final verification**

```bash
bash -n scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh
.venv/bin/python -m pytest -q
git diff --check
git status --short
```

- [ ] **Step 4: Stage explicit files and commit**

Do not stage `.venv/`, `typescript`, unrelated docs/plans, or generated artifacts. Use a commit message describing the completed workstream.

- [ ] **Step 5: Push and verify remote SHA only after explicit user authorization**

```bash
git rev-parse HEAD
git ls-remote origin refs/heads/repair/dgx-spark-deployment-wizard
```

Push only the intentional checkpoint commits and confirm exact local/remote SHA equality.

- [ ] **Step 6: Save durable knowledge**

Record only stable facts: capability boundary, acceptance commands, hardware/provider assumptions, and any reusable workflow pitfalls. Do not record temporary test counts, commit IDs, or task progress as memory.
