# Task 7 Report: Native DGX acceptance and evidence classification

## Native host evidence

Host: `thx1138@10.112.67.178` (GB10 DGX Spark)

- Architecture: `aarch64`
- GPU: `NVIDIA GB10`
- Compute capability: `12.1`
- Docker: available
- Docker socket: available
- Native preflight command reached the real host and emitted stable `VIDEO_*` output.

## Fixes required by native evidence

The native host exposed two compatibility issues not covered by the previous mock shape:

1. The deployment library queried invalid `nvidia-smi` field `compute.cap`; it now queries `compute_cap`.
2. Native output names the GPU `NVIDIA GB10`; the checker now accepts the vendor-prefixed name while retaining strict GB10 matching.

The failure-handler regression was also made deterministic by using a temporary failing `nvidia-smi` shim instead of assuming `/usr/bin` lacks the command.

## Acceptance result

- Minimal dry-run: passed through host detection, layout skip, Python dry-run, ComfyUI dry-run, and photo model planning; no downloads or runtime claims were made.
- Generated lifecycle scripts: 6 executable scripts generated and each passed `bash -n`.
- Video preflight: **blocked/deferred**, not runtime-verified. With an empty temporary deployment root it reported:
  - `VIDEO_MODEL_PATH=absent`
  - `VIDEO_DEPENDENCY_PATH=absent`
  - `VIDEO_STATE_EVIDENCE=absent`
  - `VIDEO_SERVICE_HEALTH=failed`
  - `VIDEO_ARTIFACT_EVIDENCE=absent`
  - `VIDEO_PREFLIGHT_LEVEL=preflight`
  - `VIDEO_PREFLIGHT_STATUS=failed`
- No model download, video runtime startup, provider credential use, or fabricated artifact was performed.

## Verification

- Full pytest: `150 passed in 23.64s`
- Shell syntax checks: passed
- Python compilation checks: passed
- `git diff --check`: passed
