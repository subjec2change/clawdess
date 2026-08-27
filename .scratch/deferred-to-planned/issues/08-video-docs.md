# 08 — Video documentation and capability state

**What to build:** Documentation reflects the video capability status so users understand what's ready and what's not.

**Blocked by:** 07 — Video smoke test execution and artifact verification

**Status:** ready-for-agent

- [ ] Update `SKILL.md` to describe video capability status (deferred/experimental/verified)
- [ ] Update `README.md` video section with accurate capability state
- [ ] Update `deployment-state.json` to include video capability metadata
- [ ] Document that video is verified only when real artifact is produced
- [ ] Add pytest test confirming capability manifest includes video status
