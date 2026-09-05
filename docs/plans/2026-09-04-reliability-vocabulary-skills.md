# VoxFlow execution plan

Approved for end-to-end execution by Zola's attached instructions, September 4, 2026. Work is proceeding on `feature/reliability-vocabulary-skills`.

**Outcome and scope**

Deliver a dependable local dictation update with fewer confirmed failures, measured performance improvements, portable vocabulary, and configurable spoken skill shortcuts. Complete implementation, regression checks, documentation, a signed local installation, and a reviewable source change.

Core reliability takes priority. Vocabulary and skill mappings are bounded features in this plan; if an unexpected dependency makes either substantially larger, present the specific scope change rather than silently expand the assignment or claim it complete. Translation, changes to AI providers, model replacement, and new LLM orchestration are deferred.

This is an English-dictation release using the existing speech model. The open-source distribution remains build from source.

**Established starting point**

- Repository: `voxflow-local`, branch `master`, observed HEAD `3cc226b`. Recheck before execution because other work may intervene.
- Production code is unchanged. Earlier investigation added an untracked opt-in WhisperKit integration test and three synthetic short-speech fixtures. Preserve and review those as part of the work.
- Three sub-second speech fixtures returned empty results through the actual local transcriber. The app accepts audio from 0.3 seconds, while the current decoder's one-second window padding skips those inputs entirely.
- Recent receipts show median transcription around 1.17 seconds, cleanup around 2 milliseconds, and recorded total around 1.64 seconds. These are an initial field baseline, not controlled performance claims. The insertion total includes waiting for clipboard restoration after the paste event.
- Dictionary corrections and recognition hints already exist. Corrections currently compile regular expressions for each entry on each application. Recognition hints already have limits of 24 terms and 100 tokens.
- Existing snippets and cockpit commands use single-word triggers. The skill feature must not broaden the cockpit's built-in command grammar.

**Product decisions proposed for this release**

| Area | Proposed behavior |
|---|---|
| Vocabulary | Settings supports adding, editing, removing, importing, and exporting preferred spellings and optional spoken forms. A plain UTF-8 term list supports easy initial loading; versioned JSON preserves corrections for sharing and round trips. |
| Import | Validate before changing saved state. Preview additions, duplicates, and conflicts. Default to merging, skipping identical entries and retaining existing values for conflicts unless the user explicitly chooses otherwise. A failed import or failed save leaves the previous usable configuration intact. |
| Recognition hints | Keep the existing bounded hint budget. Expose the distinction between the full correction dictionary and the smaller active recognition glossary. Give users a way to prioritize terms for that glossary. |
| Skill profiles | Users create or import a named profile containing skill names, spoken aliases, exact invocation text, and allowed applications. The active profile is visible and switchable from Settings and the menu. Shortcuts are off until configured and enabled. |
| Skill invocation | Recognize a complete configured phrase, including an alias such as “deep research,” or the explicit forms “use the [name] skill,” “use my [name] skill,” and an optional leading “hey.” Matching is case-insensitive and tolerates boundary punctuation and repeated whitespace. |
| Ordinary speech | Unknown names, ambiguous matches, phrases embedded inside longer prose, or invocations outside the selected profile's allowed applications continue as ordinary dictation. No fuzzy matching or model interpretation. |
| Command output | Insert the exact configured single-line command. Preserve slash or other client-specific syntax; bypass prose cleanup, punctuation addition, and smart spacing. Do not press Enter. Reject embedded newlines and control characters in command definitions. |
| Existing behavior | Existing dictionaries, snippets, per-app settings, and cockpit commands continue working. Skill expansion initially applies to quick dictation; cockpit recording and built-in review commands retain their existing behavior. |

Example: a user assigns spoken name `research` and alias `deep research` to command `/research` in a profile. “Hey, use the research skill” inserts `/research`. The command is an example chosen by that user, not a claim that every CLI supports it. The same profile can carry any supported exact invocation syntax.

A terminal or VS Code window can host different CLI clients. VoxFlow will use the explicitly selected profile rather than claim to detect the process inside every terminal pane. The user positions the cursor in the intended prompt. Skill definitions remain installed in the CLI; VoxFlow stores the vocabulary needed to invoke them. Automatic skill installation, directory scanning, and arbitrary command execution are outside this first version.

**1. Establish a reproducible baseline and working branch**

Recheck the working tree, preserve existing changes, and create a feature branch. Record the baseline revision, hardware/model configuration, test outcomes, and aggregate timing data. Use synthetic speech and noise fixtures; do not copy personal dictations or configuration into the repository.

Run the standard Swift and Python checks with runtime bootstrap disabled. Classify any pre-existing failure before attributing it to new work. Retain the already-reproduced short-capture failure as the regression to fix.

Prepare a repeatable measurement set covering short words, normal sentences, a longer passage, quiet speech, silence/noise, and dictionaries of 0, 100, and 1,000 entries. Measure dictionary processing separately from model inference. Keep cold model loading separate from warm transcription. Use repeated warm runs and record sample counts with median and p95; use the same conditions for the final comparison.

**Exit:** a known baseline, a focused regression matrix, and a working branch ready for implementation.

**2. Correct confirmed reliability defects**

Make the WhisperKit window padding depend on capture duration so accepted sub-second recordings reach the decoder. Preserve the longer-recording tail behavior and the existing confidence, silence, and hallucination gates. Cover the 0.3-second acceptance boundary and durations just below, at, and above one second. Validate actual speech through the model, not just the option-building helper.

Cover focus changes between capture and insertion. Code inspection shows the direct AX path consults the currently focused element before enforcing ownership by the frozen target. Ensure an AX read or write is directed to that target; otherwise use the existing target-aware recovery or paste path. Preserve the final cancellation gate and clipboard fallback.

Investigate the remaining empty-result retry case in a bounded pass. Some retained empty results contain a segment, whereas the retry currently only covers zero segments. Change retry behavior only if a synthetic or isolated reproduction demonstrates the benefit. Keep retries bounded and retain the current behavior if evidence does not support a change.

**Exit:** short-speech fixtures pass, noise controls remain rejected, longer dictation is preserved, and cancellation/focus regressions cannot insert stale text into another app.

**3. Complete vocabulary and reduce its repeated work**

Extend `DictionaryStore` and its existing Settings section. Preferred spelling is required; a spoken form is optional so users can load a name as a recognition hint without inventing a misspelling. Preserve legacy dictionary files and learned entries.

Implement a small import/export codec with a schema version, a plain-text term-list reader, validation, a merge preview, and atomic persistence. Export vocabulary data without private session history, machine-specific paths, or unnecessary internal metadata. Show actionable import/save errors in the UI. Keep invalid existing files available for recovery rather than overwrite them with defaults.

Prepare and cache correction matchers when the vocabulary changes instead of compiling every expression on every capture. Make phrase matching deterministic: prefer the longest matching spoken form, preserve literal replacement text, respect word boundaries, and avoid cascading one replacement into another. Document this precedence and test conflicting/overlapping forms against legacy examples.

Refresh the recognition prompt cache when the glossary changes. Retain its 24-term/100-token cap and expose term priority. Verify that a large dictionary remains usable without putting every imported term into the speech decoder prompt. Reuse the correction path across quick dictation and cockpit wherever it already applies; do not invent unsupported recognition-hint guarantees for other STT providers.

**Exit:** a fresh user can load a vocabulary, edit it, use it, export it, and restore it after restart. Existing users retain their data. Repeated dictionary-processing cost improves on the controlled large-dictionary case without changing expected corrections.

**4. Complete deterministic spoken skill shortcuts**

Add a small typed profile store and pure router using the existing local storage and insertion patterns. Keep ordinary snippets in their existing store and preserve `VoiceCommandRouter.parse` for cockpit commands. Centralize skill normalization and matching so imported and UI-created names behave identically.

Settings provides profile creation/editing, application selection, name/alias/command editing, import/export, and a text-only “Try phrase” preview. The preview shows the resolved command and context without inserting or executing it. The menu exposes the active profile and Off state.

Resolve shortcuts after the shared transcript acceptance gate, against the recognized utterance before vocabulary substitutions or prose cleanup can alter the skill name. Snapshot the selected profile and target context at capture start so a later settings/focus change cannot redirect that capture. Preserve onboarding and the app's existing command-lane precedence.

Thread an explicit verbatim insertion policy through the existing insertion interfaces for skill commands. Preserve the frozen target, cancellation, receipt timing, and copy-to-clipboard recovery. Matchers and import tests use injected stores and insertion fakes, never real Accessibility services.

Reject conflicting aliases within a profile unless the conflict is resolved before saving. An ambiguous runtime match does not select an arbitrary command. Imports use the same preview and persistence discipline as vocabulary. Verify locally available Claude Code/Codex invocation syntax when documenting concrete examples; users can always enter the exact command their client supports.

**Exit:** user-defined phrases work in the chosen context with exact output; unknown or out-of-context speech remains prose; profiles survive restart and round-trip export/import; disabling the feature restores ordinary dictation immediately.

**5. Integrate, verify, and document**

Run focused checks during each increment, then the complete standard suite once the integrated change is ready:

```bash
./scripts/test_all.sh --skip-runtime-checks
VOXFLOW_WHISPERKIT_GOLDEN=1 swift test --filter WhisperKitShortCaptureIntegrationTests
```

The opt-in model test uses already-installed local weights. The default runtime bootstrap helper downloads models and sets a cloud-STT fallback default; it is not the entry point for this local WhisperKit acceptance run. Any necessary Python runtime checks must explicitly use local-only routing and an isolated test service rather than interfere with the running app.

The acceptance matrix includes:

- Short, ordinary, long, and quiet speech; silence/noise; vocabulary loaded and empty.
- Cancelled or superseded captures, rapid successive captures, focus changes, and insertion fallback.
- Empty/malformed imports, duplicate and conflicting entries, unsupported schema versions, save failures, and legacy-file loading.
- Literal punctuation and symbols in terms, overlapping corrections, Unicode boundaries, and bounded recognition prompts.
- Skill phrase variants, reserved cockpit words, aliases, ambiguous mappings, wrong applications, inactive profiles, and multiword prose that must not expand.
- Exact command output, including its prefix, with no added punctuation, whitespace, newline, or Enter event.

Repeat the performance workload. Report transcription, deterministic processing, and insertion stages separately. Do not count removing bookkeeping waits as a demonstrated improvement in visible insertion time. Retain optimizations only when their measurements and regression results support them. If total latency is dominated by unchanged model inference, say so plainly.

Update README and a short user guide with import formats, generic sample files, glossary limits, conflict behavior, profile selection, and worked CLI examples. Record measured results, checks performed, and unresolved limitations. Avoid unrelated refactoring or dependency upgrades.

**Exit:** required checks pass, performance claims are supported, and another open-source user can follow the documented setup without access to Zola's files.

**6. Build, install, and finish the reviewable change**

Build the release bundle using the existing scripts and stable Apple Development signing identity. Preserve a rollback copy of the currently installed bundle and back up only the configuration files affected by the update. Check the app is idle before replacing/relaunching it; do not interrupt an active capture or unsaved review.

Use the established installation path at `~/Applications/VoxFlow.app` and launch the bundle through LaunchServices. Smoke-test Settings, imports/exports, profile switching, and controlled insertion into disposable targets, including a plain text field and available terminal/editor prompts. Keep live microphone validation distinct from the synthetic model tests; any check that requires user participation remains explicitly reported until performed.

Review the complete diff, remove accidental artifacts, and make logical commits on the feature branch. Prepare the PR description and a draft PR if the configured remote is accessible. This plan's endpoint is the tested local installation plus the reviewable source change; merging, tagging a public release, and changing the distribution model are separate actions.

**Exit:** a signed installed build, a documented rollback, validated user flows, and a reviewable branch/PR with an accurate validation record.

**Likely implementation locations**

| Area | Files/components |
|---|---|
| Decode and capture regressions | `Services/WhisperKitSTTService.swift`, existing STT/gate tests, short-speech fixtures |
| Target ownership and verbatim insertion | `Services/AccessibilityInsertService.swift`, `Services/TextInsertionCoordinator.swift`, their protocol seams and tests |
| Vocabulary | `Services/DictionaryStore.swift`, `Services/VocabularyBiasing.swift`, `Models/AppModels.swift`, a focused import/export codec |
| Skill mappings | New profile model/store and pure router under `Models/` and `Services/`; existing snippets/cockpit router remain compatible |
| App integration and controls | `AppCoordinator.swift`, `State/AppState.swift`, `Views/SettingsView.swift`, menu controls, existing design tokens |
| Proof and handoff | `Tests/VoxFlowAppTests/`, synthetic fixtures, applicable backend tests, README, examples, and a short validation record |

**Definition of done and execution boundary**

The plan is complete when the confirmed core regressions pass, both bounded configuration features work end to end, existing behavior passes the required checks, performance has been compared honestly, and the signed build and reviewable source are delivered. A failed check is resolved or reported as an explicit blocker; it is not replaced with a completion claim.

Proceed through these approved steps without routine permission requests. Surface only material scope changes or concrete blockers. Record completion evidence in the accompanying validation record.
