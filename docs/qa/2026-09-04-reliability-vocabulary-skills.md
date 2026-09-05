# Reliability, vocabulary, and spoken skills — validation record

Dates: September 4–5, 2026 (Pacific). Baseline: `3cc226b` on `master`.
Working branch: `feature/reliability-vocabulary-skills`.

The original reliability/vocabulary/skill-profile build is installed with an
Apple Development signature and a verified rollback. Live Settings, TextEdit,
Terminal, focus-switch, cancellation, and acoustic vocabulary checks passed.
An isolated VS Code attempt posted a paste event but its test file stayed empty
when the user changed windows; that check is not counted as a verified insertion.

On September 5, Zola named the feature **Voice Action Prompts** and requested a
selectable Automatic Enter menu, followed by custom/built-in/all action modes
and direct computer commands. Those extensions and capture-time window/field
guards are implemented and pass automated checks. **The final expanded build's
installation and live submission checks remain pending while the Mac is locked.**
The operator-approved native Accessibility/keyboard harness resumes after unlock.
Temporary QA vocabulary/profiles still need restoration after live acceptance.

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
  verbatim insertion. Automatic Enter is Off by default; the September 5 extension
  adds separate prompt/dictation scopes. Existing cockpit words retain precedence.

The bounded empty-result retry investigation did not reproduce an additional
segmented-empty case with these fixtures. The existing single retry for zero
segments remains; it now checks cancellation before retrying. No broader retry
policy was introduced without evidence.

## Automated checks

The baseline standard suite reported 707 Swift tests (one opt-in skip) and
564 passing Python tests (26 model/live checks skipped). The initial final suite,
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
The live TextEdit command receipt recorded 1,081 ms STT, 0 ms cleanup, 11 ms
direct insertion, and 1,168 ms total. The Terminal alias receipt recorded 988 ms
STT, 0 ms cleanup, 362 ms simulated paste, and 1,416 ms total. These are individual
acoustic integration observations, not a comparative latency benchmark. The
Terminal insertion figure retains the clipboard restoration wait; neither receipt
includes the time spent speaking.

## Delivery and live acceptance

- [x] Release bundle built with `./scripts/build_app_bundle.sh --release`.
- [x] Stable Apple Development signature verified with `codesign --verify --strict`.
- [x] Installed predecessor cloned and signature verified; affected configuration
  backed up before any installation.
- [x] Confirm the running app has no capture or unsaved review before replacement.
- [x] Install at `~/Applications/VoxFlow.app`, launch through LaunchServices,
  and confirm permissions/readiness.
- [x] Settings: create/edit/pin vocabulary, import text/JSON, inspect and cancel
  conflicts, export and re-import; verify persisted values after restart.
- [x] Settings: create/edit a profile and application selection, try phrases,
  import/export, select and disable it from the menu; verify restart persistence.
- [x] Controlled TextEdit and Terminal insertion, exact command syntax, default no Enter.
- [ ] Finish the isolated VS Code editor check with retained window/field identities.
- [x] Live focus-switch/cancellation/fallback and speaker-to-microphone dictation
  on the installed menu-callback fix.
- [ ] Install the expanded Automatic Enter build and verify all four choices,
  actual submission, same-app window changes, cancellation, setting revocation,
  and restart persistence.
- [ ] Validate the action-mode menu, individual toggles, built-in actions, and
  action history in disposable targets; verify revocation and focus guards.
- [ ] Restore original vocabulary/profile configuration and leave Automatic Enter
  Off with built-in actions disabled.
- [x] [Draft PR #16](https://github.com/ZOLAtheCodeX/voxflow-local/pull/16)
  created with the current acceptance status.

Rollback is retained privately under
`~/Documents/Codex/voxflow-rollbacks/2026-09-05-before-install/`.
It contains the predecessor `VoxFlow.app`, a manifest of hashes, and only the
affected configuration files that existed before the update. Quit VoxFlow before
restoring the bundle or configuration, preserve any new configuration you want
to keep, and relaunch the restored app through `open ~/Applications/VoxFlow.app`.
No user dictations, model files, credentials, or private configuration are in
this source change.

## September 5 live observations before Automatic Enter

All test vocabulary, profiles, and target documents are disposable. The native
harness used the installed app's actual controls and ordinary Fn capture hotkey.
No production test backdoor or direct injection into the transcription service
was used. The operator disconnected Bluetooth headphones and resolved muted
playback before the successful acoustic checks.

- Vocabulary: added and edited a spoken form and preferred spelling, pinned it,
  cancelled a conflict import without changing the file, verified default
  retention and explicit replacement, imported UTF-8 terms, and exported/re-imported
  JSON with eight duplicates and no additions. Edits and priority survived restart.
- Profiles: created a research mapping and alias, selected Terminal with the
  application picker, and previewed both a matching complete invocation and a
  longer sentence that correctly remained prose. Export/re-import reported a
  duplicate. An application-list conflict retained the original by default and
  changed it only after explicit replacement. Imports left the active profile Off.
  Explicit selection appeared in Settings and the palette and survived restart.
- Acoustic command: macOS Samantha spoke “Hey, use the research skill.” through
  the Mac speakers into the microphone. TextEdit contained exactly `/research`
  (nine characters) after direct Accessibility insertion.
- Acoustic alias: “Deep research.” produced the same exact command through the
  Terminal paste path. A disposable Python input prompt received no Enter and
  recorded no submission; dictated text was never executed.
- Initial unsuccessful acoustic attempts produced device-change/silence rejection
  receipts and left the target empty. Speech thresholds were not lowered to pass
  the demonstration.

A release-app crash observed during this session pointed to the menu icon's
Combine sink, inside the Swift runtime's main-executor check after `RunLoop.main`
delivery. The callback now uses `DispatchQueue.main`, preserving deferred delivery
while avoiding that CF run-loop executor path. The complete Swift suite was rerun:
732 tests, three opt-in skips, no failures. The signed release was rebuilt and
installed. This is a targeted mitigation for the observed stack, not a claim that
all Swift runtime crashes or audio-device failures have been eliminated.

Additional checks on the signed menu-callback build:

- Focus switched from TextEdit to Terminal before capture release; the sentence
  arrived in TextEdit through the target-aware paste path, and Terminal stayed
  unchanged. The harness verified Terminal was actually frontmost before release.
- Clicking the actual recording pill cancelled a spoken command. TextEdit stayed
  empty, no insertion receipt appeared, and the palette showed Capture canceled / Idle.
- Switching the skill profile Off from the palette made the same research phrase
  insert as ordinary prose.
- An imported test correction `schedule → arrange` changed the acoustic sentence
  to “Please arrange the meeting for tomorrow.” in TextEdit.
- The rebuilt bundle took several minutes on its first load; a process sample
  showed Core ML preparation. It subsequently reported STT ready. This first-load
  observation is separate from the cached-model controlled measurements above.

## Automatic Enter extension: automated evidence and pending live checks

The selection has four choices: Off, Voice Action Prompts only, ordinary
dictation only, and both. It is local, defaults Off for absent/unknown settings,
and is not enabled by profile import. The capture retains its choice and AX
window/field identities. Changing the selection revokes pending Enter without
cancelling text insertion. Known changes of target window/field block insertion;
unavailable identities cannot authorize Enter. The paste path rechecks after
activation and before posting, then checks again before Return. Cancellation,
secure input, and failed insertion never authorize automatic Enter.

Receipts distinguish `enterPosted` and `skipped` while preserving the fact that
text may have been inserted successfully even if Enter was skipped. Review and
manual insertion paths do not inherit automatic submission.

The focused checks cover scope combinations, isolated preference persistence,
exact command formatting, wrong process/window/field, unavailable identities,
cancellation and secure input, raw/cleaned workflow propagation, explicit review,
and accurate success-versus-skipped receipts without duplicate insertion.
The complete post-review Swift suite passed: **741 tests, three opt-in skips,
zero failures**. The release bundle was rebuilt and its stable Apple Development
signature passed deep/strict verification. Installation and live submission
checks remain pending desktop unlock. The Python implementation is unchanged
by this extension; the existing 564-pass/26-skip result still applies.


## Selectable computer actions: September 5 extension

The first set includes twelve built-ins: opening Finder, Safari, Terminal, Notes,
and Calculator; copy, paste, select all, undo, redo, find, and new tab. Settings
and the palette expose Off / Custom prompts only / Built-in computer actions
only / All, with individual action checkboxes. Built-ins require opting in;
custom-profile defaults remain compatible. Updates do not automatically select
newly introduced actions. These controls are separate from Automatic Enter.

Python validates a versioned registry request and prepares a typed operation in
an isolated process. The signed native bridge applies the permitted operation.
There is no model/server load or arbitrary code execution in that path. The
service and bridge recheck revoked permissions, and shortcuts require unchanged
known Accessibility target identities. Recognized failures do not fall through
to text insertion. Receipts and the capture history distinguish application opens
from posted shortcuts without recording clipboard contents.

Final automated coverage: **749 Swift tests, three opt-in skips, zero failures**;
**582 Python tests passed, 26 skipped**, with the same seven dependency warnings.
Ruff passed on the new Python module and tests. The new tests cover complete
phrase matching, disabled modes/actions, preference persistence, conservative
upgrade selection, malformed/unknown operations, permission revocation during
preparation, bridge errors without retry, and the displayed action receipt.
Python subprocess checks only prepare JSON and verify that model/server modules
are absent; Swift execution tests inject fakes.

A run inside the restricted execution sandbox produced failures in existing
Core Audio and Keychain tests. Re-running with the authorized host access passed
the entire suite. This was an execution-environment issue; those production paths
were not changed to make the run pass.

Standalone preparation measurement: one excluded warm-up followed by 30 requests
for `copy_selection`, each starting `.venv/bin/python -I -S` and validating the
registry/JSON result. Median **25.490 ms**, nearest-rank p95 **31.572 ms**. This
includes process startup and preparation; it excludes speech recognition and any
OS action. No action was performed during measurement. Raw samples are retained
in [computer-action-preparation.json](reliability-vocabulary-skills-20260904/computer-action-preparation.json).

The final expanded release bundle is built with the stable Apple Development
identity. Installation, actual action/submission effects, UI persistence, and QA
configuration restoration are still pending the locked desktop. The successful
live observations earlier in this document apply to the original vocabulary and
skill-profile build, not the newer direct-action/Automatic Enter extension.
