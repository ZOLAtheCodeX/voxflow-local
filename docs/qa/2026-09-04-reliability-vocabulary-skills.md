# Reliability, vocabulary, and spoken skills — validation record

Date: September 4, 2026 (Pacific). Baseline: `3cc226b` on `master`.
Working branch: `feature/reliability-vocabulary-skills`.

Implementation and automated validation are complete. The signed release bundle
has been built and a verified rollback retained. **Installation and live UI
acceptance remain pending** because the available computer-use runtime cannot
initialize (`Computer Use requires nodeRepl.createElicitation`). An alternative
local UI harness has been proposed to the operator. These checks are not replaced
by the passing unit tests.

## Confirmed changes

- Accepted captures no longer disappear solely because their duration is at or
  below WhisperKit's one-second window padding. Longer recordings keep the old
  tail guard. Decoder confidence and silence thresholds remain unchanged.
- Above-floor synthetic ambient noise exposed a `[BLANK_AUDIO]` marker after
  enabling short decoding. Both Swift and Python now reject that whole marker;
  ordinary speech mentioning blank audio remains allowed.
- AX reads and direct writes require ownership by the frozen target process.
  Paste checks cancellation and successful target activation immediately before
  posting Cmd+V. A failed/cancelled activation cannot paste into the other app.
- Vocabulary supports preferred terms, optional spoken forms, priority,
  editing, previewed imports, export, legacy loading, and atomic saves.
  A cached matcher applies longest forms first without cascading replacements.
- Explicit skill profiles support names, aliases, application restrictions,
  portable import/export, and a phrase preview. Quick Dictation freezes the
  matcher with the target. Accepted commands bypass prose processing and use
  verbatim insertion without Enter. Existing cockpit words retain precedence.

The bounded empty-result retry investigation did not reproduce an additional
segmented-empty case with these fixtures. The existing single retry for zero
segments remains; it now checks cancellation before retrying. No broader retry
policy was introduced without evidence.

## Automated checks

The baseline standard suite reported 707 Swift tests (one opt-in skip) and
564 passing Python tests (26 model/live checks skipped). The final suite,
including published example-file validation, reported **732 Swift tests with
three opt-in skips and no failures**, and **564 passing Python tests with
26 skips**. Seven existing Python dependency deprecation warnings remain.

```bash
./scripts/test_all.sh --skip-runtime-checks
VOXFLOW_WHISPERKIT_GOLDEN=1 swift test --filter WhisperKitShortCaptureIntegrationTests
VOXFLOW_DICTIONARY_BENCHMARK=1 VOXFLOW_STT_BENCHMARK=1 \
  VOXFLOW_BENCHMARK_LABEL=after swift test \
  --filter 'DictionaryPerformanceTests|WhisperKitPerformanceTests'
```

The opt-in actual-model regression passed: `tomorrow` and `approved` were
decoded and accepted; `yes` was decoded but still rejected by the existing
short-greeting filter. Silence was rejected upstream, above-floor noise was
rejected by the transcript gate, and the longer control retained its transcript.
The before/after workload also checked ordinary, quiet, and longer speech with
recognition vocabulary both empty and populated.

Focused coverage includes import conflicts/default retention/explicit
replacement; malformed files and versions; file/entry limits; failed atomic
saves; legacy vocabulary; priority and hint caps; literal punctuation/Unicode
boundaries/overlap; inactive/wrong-app/ambiguous skills; capture snapshots;
reserved cockpit words; exact slash, dollar, and namespaced output; cancellation;
target ownership; and insertion timing receipts. Published examples are loaded
through the same codecs and stores used by the app. Insertion tests use fakes;
they do not type into the operator's applications or start backend processes.

## Controlled measurements

Host: Apple Silicon MacBookPro18,1, 16 GB RAM; Swift 6.3.3, Python 3.11.4;
WhisperKit 0.15.0, local `whisper-small.en` Core ML weights. Dependencies and
model weights did not change. Swift test builds were used for both measurements.
The synthetic fixtures and their provenance are in
[short_dictation](../../Tests/Fixtures/short_dictation/README.md).

Raw synthetic-only measurement rows are retained as
[before.json](reliability-vocabulary-skills-20260904/before.json) and
[after.json](reliability-vocabulary-skills-20260904/after.json).

Dictionary matching: one untimed warm-up, then 30 repeated corrections of the
same eight-sentence input at each dictionary size. Matcher construction and
configuration persistence are excluded from this hot-path measurement.

| Entries | Before median / p95 (ms) | After median / p95 (ms) |
|---|---:|---:|
| 0 | 0.000458 / 0.000583 | 0.000083 / 0.000084 |
| 100 | 1.087 / 1.225 | 0.114 / 0.118 |
| 1,000 | 9.981 / 10.292 | 0.886 / 0.910 |

For reproducibility, the original dictionary harness reports the upper middle
sample as median and sample index `floor((n-1)*0.95)` as p95, both zero-based.
Both runs use that same convention. The 1,000-entry median improved about 11×,
or 9.1 ms per correction of this input. This is not an 11× end-to-end speedup.

Warm STT: one sentence warm-up excluded, then three repetitions per fixture with
no glossary and three with the glossary `meeting`, `schedule`, `review`.
The table pools those six observations per fixture; p95 uses nearest rank and
therefore equals the maximum with this small sample. Cold loading is separate:
1,556 ms before and 1,501 ms after (one observation each).

| Fixture | Before median / p95 (ms) | After median / p95 (ms) | Transcript result |
|---|---:|---:|---|
| yes, 0.48 s | 14.4 / 19.0 | 291.4 / 375.9 | Empty → correct decode; existing greeting rejection retained |
| tomorrow, 0.58 s | 15.0 / 15.4 | 280.2 / 371.5 | Empty → correct decode |
| approved, 0.61 s | 15.5 / 15.8 | 278.9 / 390.4 | Empty → correct decode |
| sentence, 2.31 s | 420.8 / 503.7 | 402.5 / 504.2 | Exact in all runs |
| quiet sentence, 2.31 s | 414.8 / 509.5 | 404.7 / 489.6 | Exact in all runs |
| passage, 11.53 s | 1,111.5 / 1,195.9 | 1,065.3 / 1,219.9 | Exact in all runs |

Short captures now spend time decoding instead of being skipped. Their extra
time is a reliability correction. Ordinary/longer inference remains within
run-to-run variation; the passage p95 is slightly higher. No statistically
supported general STT speedup is claimed. This workload is synthetic and small;
it does not establish a field failure rate or speaker/accent coverage.

Deterministic skill resolution uses a cached phrase lookup and bypasses cleanup.
No isolated latency improvement is claimed for that new path. Existing paste
activation/restoration waits remain, including the 300 ms clipboard restore wait.
Visible insertion and end-to-end timing need the pending live checks; bookkeeping
waits have not been subtracted to manufacture an improvement.

## Delivery and live acceptance

- [x] Release bundle built with `./scripts/build_app_bundle.sh --release`.
- [x] Stable Apple Development signature verified with `codesign --verify --strict`.
- [x] Installed predecessor cloned and signature verified; affected configuration
  backed up before any installation.
- [ ] Confirm the running app has no capture or unsaved review before replacement.
- [ ] Install at `~/Applications/VoxFlow.app`, launch through LaunchServices,
  and confirm permissions/readiness.
- [ ] Settings: create/edit/pin vocabulary, import text/JSON, inspect and cancel
  conflicts, export and re-import; verify persisted values after restart.
- [ ] Settings: create/edit a profile and application selection, try phrases,
  import/export, select and disable it from the menu; verify restart persistence.
- [ ] Controlled insertion into a disposable plain text field and available
  terminal/editor prompts, including exact command syntax and no Enter.
- [ ] Live focus-switch/cancellation/fallback checks and microphone dictation.
- [x] [Draft PR #16](https://github.com/ZOLAtheCodeX/voxflow-local/pull/16)
  created with the current acceptance status.

Rollback is retained privately under
`~/Documents/Codex/voxflow-rollbacks/2026-09-04-reliability-vocabulary-skills/`.
It contains the predecessor `VoxFlow.app`, a manifest of hashes, and only the
affected configuration files that existed before the update. Quit VoxFlow before
restoring the bundle or configuration, preserve any new configuration you want
to keep, and relaunch the restored app through `open ~/Applications/VoxFlow.app`.
No user dictations, model files, credentials, or private configuration are in
this source change.
