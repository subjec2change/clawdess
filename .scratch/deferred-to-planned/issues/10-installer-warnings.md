# 10 — Add deferred/experimental warnings to wizard

**What to build:** When a deferred or experimental feature is selected, the wizard warns the user but continues installation where possible.

**Blocked by:** 09 — Improve wizard UX (colors, progress, error messages)

**Status:** ✅ COMPLETED

- capability_status_summary() extracts states
- deferred_warning_banner() shows batched warnings
- feature_warning() per-feature warnings before install
- All tests passing (70/70)
- [ ] Add capability status lookup function that reads from `dgx-spark-models.json` or capability manifest
- [ ] When a feature is selected, check its capability status
- [ ] If status is `deferred`: show yellow warning ("This feature is deferred — installation attempted but not verified on hardware")
- [ ] If status is `experimental`: show yellow warning ("This feature is experimental — installation attempted, partial verification expected")
- [ ] If status is `verified`: no warning needed
- [ ] If status is `blocked`: show red error ("This feature is blocked — cannot proceed without resolving: <reason>")
- [ ] For deferred/experimental: continue installation, do NOT abort
- [ ] For blocked: abort that feature's installation only, continue with other features
- [ ] Add pytest test confirming wizard warns about deferred features and continues
