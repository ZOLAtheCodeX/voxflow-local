## What and why

## How it was tested

- [ ] `swift test` green
- [ ] `./.venv/bin/python -m pytest backend/tests` green
- [ ] New behavior has tests (failing-test-first preferred)
- [ ] No test constructs a real system-touching service (use the
      `TextInserting` / `BackendProcessRunning` seams)
- [ ] Paired implementations updated together if touched (hallucination
      filter parity fixture, providers.json schema contract)
