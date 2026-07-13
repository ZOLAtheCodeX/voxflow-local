# Rules-first hardening: rules-only polish + corpus-backed cleanup rules (design)

Date: 2026-07-13
Status: approved by user (design parts 1 and 2), pending spec review

## Why

Two motivations from the 2026-07-12 forensic session:

1. On a 16 GB machine, the resident ~7 GB Gemma model starves live capture
   (documented R2-retune mechanism; the one Ollama load event in the retained
   log window landed on 2.8 GiB free with zero free swap). Today, switching
   the insert behavior to polish silently loads that model. The user wants an
   explicit "local rules only" polish choice that can never load a local LLM.
2. A mining pass over the user's 1,003 real inserted dictations (receipts are
   post-cleanup text, so every artifact is by definition a rule gap) found one
   dominant gap and a small cluster:
   - ~3%: punctuation orphans after phrase-filler removal ("pretty, , in your
     face", "what it looks .", "model,.")
   - fillers with attached punctuation survive exact-token matching ("Uh...")
   - stutter hyphens ("G-G-Gamma")
   - mid-text ellipsis forcing recapitalization ("was pretty... Good.")
   Non-gaps confirmed by the same pass: zero double spaces, zero lowercase
   sentence starts, zero "gonna"-class survivors; "like" (88 hits) is almost
   all legitimate usage, so POS-free removal stays out. Trailing ellipsis
   (28 hits) is the decoder tail-loss signature, not a text-rule problem.

## Goals

- Part (a): a "Local rules only" polish setting; with it active, dictation
  polish never probes, loads, or keeps alive any local LLM.
- Part (b): close the four corpus-backed rule gaps in BOTH cleanup
  implementations (Python `nlp/cleanup.py`, Swift `TextCleanupService`),
  keeping the shared-constants discipline.

## Non-goals

- Smart actions stay on their own chain (user decision: a cockpit chip tap is
  an explicit, visible action; rules cannot summarize). The smart-action
  picker does NOT get a rules-only row.
- No POS-aware "like" removal in Python (accepted gap, re-confirmed by corpus).
- No repair of trailing-ellipsis tail loss (capture-side concern).
- No providers.json schema change.

## Part (a): rules-only polish via a reserved chain id

### Representation

`"rules"` is a reserved chain entry id. Rules-only polish is persisted as:

```json
"chains": { "polish": ["rules"], "smart_action": ["ollama"] }
```

- A real provider may never use the id `rules`: `ProviderConfigStore` (Swift)
  and `load_provider_config` (Python) reject/skip such a provider entry with
  a logged warning.
- Both self-healers treat the sentinel as always-known:
  - Swift `ProviderConfigStore` chain pruning keeps `"rules"` (it references
    no provider), so it survives provider add/remove cycles.
  - Python `load_provider_config` chain pruning likewise keeps `"rules"`.
  - The existing empty-chain repairs stay untouched — a sentinel chain is
    never empty, so their semantics do not change.

### Engine behavior

- `PolishEngine.run()` stops the provider walk at the sentinel and serves the
  unconditional regex floor with `served_by="rules"`.
- `served_by="regex"` keeps its current meaning: providers were configured
  but all failed (degraded). Chosen is not degraded: with the sentinel,
  `degraded_reason` stays empty and the memory guard has nothing to skip.
- Chain entries after `"rules"` are unreachable; the loader truncates the
  chain at the first sentinel occurrence.
- No Ollama probing for polish when the polish chain is the sentinel;
  `/v1/ready` continues probing providers referenced by the smart-action
  chain.

### Settings UI and readiness surface

- The polish-provider picker in Settings gains one row: "Local rules only",
  writing the sentinel chain. Smart-action picker unchanged.
- `/v1/ready` reports `active_polish_provider: "rules"`,
  `active_polish_model: ""`. `polish_chain` includes the sentinel as-is.
- Indicator semantics (palette footer, cockpit pill, pipeline-viewer chips):
  provider `rules` renders as a neutral chosen state ("rules · local");
  empty provider keeps the orange degraded "regex fallback" rendering.
- `PolishProvenance.label` already maps `rules` → "rules"; audit receipts
  read `Inserted (polish · rules — app)`.

## Part (b): four corpus-backed cleanup rules

All rule data lives in `backend/app/text_cleanup_rules.py` and its Swift
mirror (`TextCleanupRules.swift`), same discipline as today. Pipeline changes
apply to BOTH `light_cleanup()` and Swift `cleanup(.light)`.

1. **Punctuation-orphan repair (new step, after filler removal, before final
   normalization).** Ordered pattern list `PUNCT_ORPHAN_REPAIRS`:
   - collapse `", ,"` / `",,"` → `","`
   - resolve doubles to the terminal mark: `",."` → `"."`, `".,"` → `"."`,
     `"?."` → `"?"`, `"!."` → `"!"`
   - remove space before punctuation: `"word ."` → `"word."`
   Guards: patterns match spaces/tabs only, never newlines (protects the
   `\n\n` written by "new paragraph"); ellipsis `...` is explicitly excluded
   from double-resolution so it never collapses to `"."`.
2. **Punctuation-aware filler matching.** The single-word filler step strips
   leading/trailing punctuation from each token before the `ALWAYS_FILLERS`
   membership check; on a hit the whole token (punctuation included) is
   removed, and orphan repair heals the seam.
   `"the... Uh... G-G-Gamma model"` → (fillers) `"the... G-G-Gamma model"`.
3. **Stutter dedup.** One shared regex collapsing single-letter stutter
   prefixes onto the word: `"G-G-Gamma"` → `"Gamma"` (case-insensitive
   backreference), applied alongside the repeated-word step.
4. **Ellipsis recase exclusion.** The sentence splitter no longer treats
   `"..."` as a sentence boundary, so hesitation ellipses stop forcing a
   capital on the next word (`"was pretty... good"` stays lowercase).

### Parity and testing

- New input→expected cases live in ONE shared JSON fixture consumed by both
  test suites (pytest and XCTest) — the same cross-language pinning idea as
  the existing hallucination parity test; the implementation plan confirms
  the exact fixture-location mechanism by reading that test.
- All fixture cases are SYNTHETIC, modeled on the corpus patterns. None of
  the user's verbatim dictations enter the repository (it is public).
- Acceptance check: re-running the mining script over the receipts log after
  the feature ships must show the four artifact classes at or near zero for
  newly inserted texts.
- Part (a) tests: config round-trip (sentinel survives save/load/pruning on
  both sides), engine short-circuit (`served_by="rules"`, no provider
  called), readiness fields, reserved-id rejection.

## Docs

- CLAUDE.md: providers.json paragraph gains the sentinel; polish env-var
  table row for `VOXFLOW_POLISH_BACKEND` unchanged (the sentinel is a chain
  concept, not an env concept).
- CHANGELOG: both features under Unreleased / Added.

## Decisions made during brainstorming

- Scope: polish only; smart actions keep Ollama (user choice).
- All four rule classes ship (user multi-select: all).
- Representation: sentinel chain id, Option A over empty-chain semantics or
  a new schema field (user choice).
- Synthetic-only fixture cases: constraint stated by Claude (public repo),
  not user-optional.
