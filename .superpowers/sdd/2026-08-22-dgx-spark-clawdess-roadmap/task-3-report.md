# Task 3 report: explicit remote-provider semantics

- Authoritative checkout: `repair/dgx-spark-deployment-wizard` at Task 3 implementation commit.
- Remote provider is recorded independently from local dependency applicability.
- Remote photo inference skips local photo model acquisition only.
- Video local dependency applicability remains explicit and deferred; remote mode does not claim local-free operation.
- Piper installation is gated on explicit `voice` feature selection.
- Capability rejection remains before all non-dry-run provider paths.
- Added tests covering remote/local capability state, voice gating, and documentation contract.

Fix round 1 evidence:
- Changed `capability_manifest` so `local_dependencies` follows feature dependency applicability, not `provider != 'remote'`; remote video now reports `local_dependencies: true`, `local_dependency_applicability: true`, and `local_dependency_state: deferred`.
- Added deployment-path tests proving remote photo acquisition is skipped, remote video calls the gate without invoking `provision_local_video`, and Phase 6 installs voice backend only when `voice` is explicitly selected.
- Focused deployment tests: `.venv/bin/pytest -q tests/test_deploy_dgx_spark.py -k "remote_video_manifest_keeps or remote_photo_deployment_gate or remote_video_provisioning_gate or phase_six_installs"` -> 4 passed.
- Full suite: `.venv/bin/pytest -q tests/test_deploy_dgx_spark.py` -> 75 passed.
- Syntax/diff checks: `bash -n scripts/deploy-dgx-spark.sh scripts/deploy-dgx-spark-lib.sh` and `git diff --check` passed.
