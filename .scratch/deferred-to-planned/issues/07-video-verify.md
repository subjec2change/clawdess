# 07 — Video smoke test execution and artifact verification

**What to build:** A real video artifact produced via Wan2GP, so video capability moves from `deferred` to `experimental`.

**Blocked by:** 06 — Add Wan2GP video smoke test function

**Status:** ready-for-agent

- [ ] Execute smoke test function against live ComfyUI instance
- [ ] Verify artifact exists, is non-empty, and has valid container format (check file header)
- [ ] Update capability status: video moves to `experimental` when artifact produced
- [ ] Add test in `tests/test_dgx_spark_ac_gaps.py` that verifies smoke test produces artifact
- [ ] If artifact production fails, record error and keep state as `deferred` (don't upgrade)
