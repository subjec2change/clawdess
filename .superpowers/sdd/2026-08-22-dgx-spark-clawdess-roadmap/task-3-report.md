# Task 3 report: explicit remote-provider semantics

- Authoritative checkout: `repair/dgx-spark-deployment-wizard` at Task 3 implementation commit.
- Remote provider is recorded independently from local dependency applicability.
- Remote photo inference skips local photo model acquisition only.
- Video local dependency applicability remains explicit and deferred; remote mode does not claim local-free operation.
- Piper installation is gated on explicit `voice` feature selection.
- Capability rejection remains before all non-dry-run provider paths.
- Added tests covering remote/local capability state, voice gating, and documentation contract.

Verification: `.venv/bin/python -m pytest tests/test_deploy_dgx_spark.py tests/test_dgx_spark_ac_gaps.py -q` -> 125 passed; `bash -n` and `git diff --check` passed.
