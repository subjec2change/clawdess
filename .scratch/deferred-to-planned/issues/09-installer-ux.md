# 09 — Improve wizard UX (colors, progress, error messages)

**What to build:** Better interactive experience with colored output, progress indicators, and clearer error messages in the deployment wizard.

**Blocked by:** None — can start immediately.

**Status:** ✅ COMPLETED

- All checklist items implemented and committed
- [ ] Add colored output for key wizard states (info=blue, success=green, warning=yellow, error=red)
- [ ] Add progress indicator during long operations (model download, pip install, generation)
- [ ] Improve error messages: instead of "error: command failed", say "Installation failed — expected X but got Y"
- [ ] Do NOT rewrite the wizard — only add UX improvements to existing code
- [ ] Verify existing `--non-interactive` mode still works (colored output should be suppressed when non-interactive)
- [ ] Run `bash -n scripts/deploy-dgx-spark.sh` to confirm no syntax errors
