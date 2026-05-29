# Post-Session Audit — 2026-05-28

**Audit base:** `1b8cc53` (feat(snippets): wire SnippetStore to live dictation path)
**Audited tip at start:** `4a09010`; master advanced to `ed7b60c` (`.cursorrules` chore) **during** the audit — the concurrent session is actively committing.
**Method:** independent verification (builder output treated as untrusted), confirmed by reading code, executing the filter against inputs, and running the full suite.

## Commit train audited (`1b8cc53..ed7b60c`)
| SHA | Subject | Source | Verdict |
|-----|---------|--------|---------|
| `1776d15` | fix(ui): menu bar panel dismisses on local/global clicks | concurrent | ✅ sound, leak-free |
| `578ceed` | feat(chains): Phase E workflow chains | this builder | ✅ intact post-merge, invariants hold |
| `2eef320` | Merge phase-e → master | concurrent | ✅ clean (Phase E byte-identical to branch tip) |
| `0e66f2f` | fix(dictation): aggressive HallucinationFilter rewrite | concurrent | ❌ Critical false positive (F1) + over-filtering (F2–F6) |
| `4a09010` | fix(dictation): filter patch + test rewrite | concurrent | ❌ regression-locked the defects via deleted/flipped tests |
| `ed7b60c` | chore: add .cursorrules | concurrent | ✅ inert (config only) |

## Findings (evidence-first)

### F1 — Critical — Single-word dictation universally discarded *(FIXED)*
`HallucinationFilter.swift:42` `if Set(words).count == 1 { return true }`. A one-element array always has set cardinality 1, so **every lone word** ("Approved", "Cancel", "Done", a name, a number) was classified as a hallucination and dropped (both call sites turn `true` into an empty transcript). The comment shows the intent was to catch *repeats*. Confirmed by executing the source. No test exercised a lone non-greeting word — that gap let it reach master.
**Fix:** `words.count >= 2 && Set(words).count == 1` + `testLegitSingleWordPasses`. Commit `febc4f1`.

### F2 — High — `shortAudio` parameter is dead *(reported, not changed)*
The rewrite never reads `shortAudio`; the signature misleads callers (both pass `shortAudio: isShortAudio`). Words previously short-audio-only (`you`, `thanks`, `bye`, `goodbye`, plus new `yeah/yes/okay/ok/everyone/everybody/guys/there`) now filter at **all** durations — a long dictation ending "…okay" can be dropped. Appears to be the concurrent session's deliberate "filter globally" choice (cf. `183a53b`), so left for the owner: either re-gate by duration or drop the unused parameter.

### F3 — High — Trigger-word substring over-filters legit phrases *(reported)*
`HallucinationFilter.swift:48` filters any ≤8-word phrase containing `watching`/`channel`/`subscribe`. Real speech eaten: "I'm watching the kids", "change the channel", "subscribe me to the newsletter". Recommend requiring a co-occurring YouTube marker or explicit phrase templates (like the existing `thank you for …` checks).

### F4 — Medium — Bracket/paren/star + keyword over-filters *(reported)*
Text starting with `[`/`(`/`*` that merely *contains* `noise`/`silence`/`typing`/`keyboard`/`clack` is dropped: "[note] there was background noise", "(turn off the keyboard backlight)". Recommend matching the whole bracketed content against the cue set, not `contains`.

### F5 — Medium — Two-word/emphatic repeats dropped *(reported)*
"no no no", "go go go", and two-word both-in-set pairs ("yes okay", "okay there") filter. The protective test `testTwoRepeatedWordsNotFiltered` was deleted.

### F6 — High — Coverage regression masks the above *(reported)*
Tests 21 → 16. Protective `XCTAssertFalse` tests **deleted** (`testShortOnlyPassedOnLongAudio`, `testRepeatedWordPassedOnLongAudio`, `testTwoRepeatedWordsNotFiltered`) or **flipped** to `XCTAssertTrue` (`Thanks!` long-audio; `Hi there.`). CI stayed green while real speech vanished. No false *negatives* found — every true hallucination (empty, "thank you for watching", "subscribe…", repeats, greetings, ♫, …) is still filtered; the rewrite is purely over-aggressive.

### Non-defect nits (no action taken)
- `progress.txt` stale (session 13, 2026-03-01); silent on Phase E — not an overclaim.
- Phase E commit body says "9 executor tests" / "374"; actual 10 / 375 — prose undercount only.
- Design doc lists a `POST /v1/chain/run` endpoint; chains were built client-side (`ChainExecutor`) — design aspiration, not an overclaim.

## Behavior verified
- **Phase E (`578ceed`)** intact on master: `ChainExecutor` @MainActor sequential stop-on-error; separate `chainActionService` (undo-stack isolation); `frozenTarget` from cockpit session; `runChain` single-flight + status surfacing; `ChainStep` unknown-kind throws; `ChainStore` multi-word `normalizedName` + dup-name reject; palette additive + reactive. All 28 chain tests pass.
- **Merge `2eef320`** clean: `git diff 578ceed..ed7b60c` over the 8 Phase E files is empty; no conflict markers anywhere.
- **Menu-bar `1776d15`**: monitors removed in `close()` + `deinit`, `[weak self]`, local monitor returns the event — no leak, no retain cycle.

## Safety boundaries verified
- No `Package.swift`/`Package.resolved` drift. No tracked `out/` artifacts. Train touched only `Sources/`+`Tests/`. No forbidden/generated paths. No live network/OAuth/mailbox/send/dependency changes. `AGENTS.md` preserved untracked.

## Validation matrix
| Check | Result |
|-------|--------|
| `swift build` (with fix) | ✅ clean |
| HallucinationFilter suite | ✅ 17/17 (16 + new guard) |
| Full suite (with fix) | ✅ 371/0 |
| Full suite (master pre-fix) | ✅ 370/0 (green — but blessing the defects) |
| `git ls-files out/` | ✅ empty |
| Package/lockfile diff | ✅ empty |
| Forbidden-path diff | ✅ none |

## Residual risks
- **F2–F6 remain on master** (reported, not fixed): the filter still over-discards legit speech containing trigger words, bracketed cues, trailing "okay/yeah", and emphatic repeats. The filter's owner (the concurrent session) should tune these; this audit fixed only the unambiguous Critical logic bug (F1) to avoid reverting deliberate heuristics on an actively-edited file.
- The F1 fix lives on branch `worktree-audit-hallucination-fix` (`febc4f1`), **not merged, not pushed** — the concurrent session owns `HallucinationFilter.swift` and committed to master mid-audit, so the merge is a coordinated human decision.

## Repo state
- master = origin/master = `ed7b60c` (untouched by this audit).
- Fix branch `worktree-audit-hallucination-fix` @ `febc4f1` (fix) → audit-report commit.
- No push, no merge.

## Recommended next move
1. Review + merge `worktree-audit-hallucination-fix` (F1 fix) into master, coordinating with the concurrent session that owns the filter.
2. Have the filter owner address F2–F6 (re-gate `shortAudio` or drop it; tighten the trigger-word and bracket heuristics; restore the deleted protective tests).
3. Refresh `progress.txt` (stale since session 13).
