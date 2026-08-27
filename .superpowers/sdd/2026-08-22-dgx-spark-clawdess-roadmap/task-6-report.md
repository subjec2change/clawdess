# Task 6 Report: Local reference-image validation

## Scope

Added `validate_image_reference()` in `scripts/common.py` and applied it at the photo/video orchestration boundary before API-key checks and provider calls.

Accepted inputs:

- HTTPS URLs, preserved as opaque provider references.
- Local PNG, JPEG, and WebP regular files under 25 MiB by default.

Rejected inputs:

- Empty references.
- Non-HTTPS URL schemes, including `file://` and `ftp://`.
- Missing paths, directories, unsupported extensions, mismatched file signatures, and oversized files.

## Verification

- Focused Task 6 suite: `8 passed in 0.02s`
- Full suite: `148 passed in 23.84s`
- Python compilation: passed for changed Python modules and tests
- CLI help: `clawdess.py`, `photo`, and `video` help commands passed
- `git diff --check`: passed
- No provider uploads or identity-persistence behavior was added.

## Boundary evidence

The orchestration regression confirms an invalid local reference exits with an actionable error before API-key validation or provider invocation. The unrelated pre-existing untracked local provider import issue was not modified.
