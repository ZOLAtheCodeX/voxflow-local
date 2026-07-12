# Pipeline viewer: persistent capture provenance (design)

Date: 2026-07-12
Status: approved by user (design sections 1 and 2), pending spec review

## Why

Field report (2026-07-12): the pipeline stage card in `CommandPaletteView` disappears
too quickly to read, so the user cannot tell which path served a capture (rules vs
Gemma polish) or why a capture was rejected. The forensic investigation that
preceded this design showed the data needed already exists, durably, in
`~/Library/Logs/VoxFlow/insertions.jsonl` (written by `InsertionAuditLog` for every
insert and reject), but no UI surfaces it. The same investigation corrected a
misattribution: recent capture misses happened in rules mode under environmental
memory pressure, not under Gemma polish; a permanent provenance view makes that
class of question self-serve in the future.

## Goals

- Show what just happened: a persistent "last capture" row in the palette that
  stays until the next capture replaces it.
- Show recent history: a "Recent captures" section in the Dashboard listing the
  newest ~50 receipts, rejects included, with rejection reasons.
- Zero changes to any capture, insert, or audit write path.

## Non-goals (explicitly out of scope)

- Track 2 of the session plan (rules-first hardening: "local rules only" polish
  setting, receipt-mined cleanup rules). Separate design.
- Changing the receipt schema or the `source` label format.
- Live file watching (FSEvents); refresh is view-event driven.

## Architecture

Read model over the existing event log. Two new units, two touched views.

### CaptureReceipt (new model)

Typed struct decoded leniently from one JSONL line:

- `event` ("insert" | "reject"), `ts` (ISO8601 date): required.
- Optional: `text`, `chars`, `source` (raw label), `target`, `confidence`,
  `audio_seconds`, `rms`, `peak_amplitude`, `reason`, `audio_file`, plus parsed
  source parts (see parser below).
- All fields beyond event/ts optional because the schema grew over time; old
  lines lack newer fields. A line that fails to decode yields nil and is
  skipped, never thrown.
- The writer sanitizes non-finite doubles to the string `"non-finite"`; the
  decoder maps that sentinel to nil for the affected field only.

### InsertionReceiptStore (new service)

`@MainActor final class InsertionReceiptStore: ObservableObject`

- `@Published private(set) var receipts: [CaptureReceipt]` — newest first,
  capped at 50.
- `func refresh()` — re-reads the file tail; no-op when file size and mtime are
  unchanged since the last read.
- Reads only the last ~256 KB of `insertions.jsonl`; if the main file holds
  fewer than the cap, spills into the `.1.jsonl` rotation backup.
- `init(fileURL: URL = InsertionAuditLog.defaultFileURL)` — tests inject a
  temp-dir fixture path.
- Read-only: the store never writes, so it has no failure mode that can touch
  dictation data.
- Owned by `AppCoordinator`, same pattern as its other services.

### Source-label parser

Labels look like `Inserted (light · rules — app)` or
`Inserted (polish · friendly · gemma4:e2b-mlx — Terminal)` (built in
`DictationWorkflowCoordinator`). The parser:

- strips the `Inserted (` / `)` wrapper when present;
- splits the app-profile label off the final ` — ` separator;
- keeps the ` · ` tokens as an ordered list (no guessing which token is tone
  vs provider). Views render tokens as chips, so unknown tokens display fine.
- Reject sources (`quick_dictation`, `capture_error`) pass through as a single
  token.

A format-pinning test builds a label via the same code path
`DictationWorkflowCoordinator` uses and asserts the parser round-trips it, so
label drift fails loudly.

## Data flow and refresh

- Both surfaces call `store.refresh()` on `onAppear` and on `.onChange` of
  `AppState.captureCount` and `AppState.lastInsertResult`.
- Capture/insert code is untouched. If a trigger fires a beat before the
  receipt lands on disk, the next trigger self-corrects.

## UI

### Palette: persistent last-capture row

One-line row in `CommandPaletteView` between the content area and the footer
bar, visible whenever at least one receipt exists, replaced only by the next
capture. Content: relative time, outcome icon, mode/served-by chips, target
app, duration, confidence, truncated snippet (~60 chars). Rejects render with
the warning tint plus the reason and refined status when present. All styling
through `VF.*` tokens (repo rule: no raw fonts/colors in `Views/`).

### Dashboard: "Recent captures" section

New section after `modeUsageSection`: compact table of the newest 50 receipts,
one row per line, same fields as the palette row. Reject rows tinted; where a
reject carries `audio_file`, a button reveals the retained WAV in Finder.
Empty state: "No captures recorded yet".

## Error handling

- Missing/unreadable file: empty state, never an error dialog.
- Malformed JSON lines: skipped; partial fields render what parsed.
- `"non-finite"` sentinels: field-level nil.
- Rotation racing a read: show whatever parses; next refresh corrects.

## Testing (all Swift, TDD)

- Parser: every label shape the codebase emits today (raw, light · rules,
  polish · provider, tone variants, per-app profiles, reject sources).
- Store: temp-file fixtures for tail-limit, rotation spillover into
  `.1.jsonl`, malformed-line skipping, mtime/size no-op refresh, missing file.
- Format pinning: label built by the production label-building path must
  round-trip through the parser.
- No real system-touching services (repo seam rule); file IO confined to temp
  fixtures.

## Decisions made during brainstorming

- Surface: both palette row and dashboard section (user choice).
- Text visibility: truncated snippet in rows (user choice).
- Data flow: file-backed reader, Option A over in-memory ring / hybrid
  (user choice; survives restarts, includes rejects and pre-feature history,
  zero write-path changes).
- Refresh, row cap (50), reject inclusion: defaults chosen by Claude with
  user's blanket approval of the design sections.
