# Task 4 report

## TDD evidence

RED (before implementation): `KeyError: 'VIDEO_PREFLIGHT_LEVEL'` (1 failed in 0.06s).

GREEN (after implementation): `1 passed in 0.08s`.

The acceptance test uses `CLAWDESS_TEST_DOCKER=missing` to make the missing-Docker case deterministic.

## Contract

The script emits stable machine-readable `VIDEO_*=` lines, never downloads credentials, and only advances from preflight to health or artifact when real evidence is present.
