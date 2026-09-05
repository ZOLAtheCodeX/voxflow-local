# Vocabulary and spoken skills

Open **VoxFlow Settings → Dictation Tools**. Vocabulary and skill profiles are
local configuration. They require no language-model call or additional service.

## Vocabulary

Use **Add term** to save a preferred spelling. Add an optional spoken or
misrecognized form to correct it in transcripts. For example, `ack me` can become
`Acme`. Edit existing entries with the pencil button and remove them with the
trash button. Search finds either the spelling or the spoken form.

**Import** accepts:

- A UTF-8 `.txt` file with one preferred spelling per line. Blank lines are ignored.
- A `.json` file containing `schema_version: 1` and an `entries` array. Each entry
  has a required `written` spelling, an optional `spoken` form, and an optional
  `prioritized` boolean.

Start with [the term list](../examples/vocabulary.txt) or
[the correction example](../examples/vocabulary.json). The import preview shows
incoming values, existing spellings, and counts of additions, duplicates, and
conflicts. Identical entries are skipped. Existing values win conflicts unless
you select **Replace conflicting existing entries**. Cancelling the preview
changes nothing.

**Export** produces portable JSON without session history, learning timestamps,
or local paths. Exported files can be imported into another installation. Files
are limited to 1 MB, dictionaries to 5,000 entries, and each spelling/spoken field
to 256 characters. A transaction that would exceed these limits is rejected
before changing the active vocabulary.

Pin the spellings you want prioritized for recognition. WhisperKit receives a
shortlist of up to 24 unique spellings, with at most 100 prompt tokens; long names
can exhaust the token limit before all 24 fit. Pinned spellings come first, with
dictionary order breaking ties. Expand **Recognition shortlist** to see the
ordered candidates. If too many terms are pinned, unpin less important ones.
Recognition hints influence the existing model; they do not guarantee a spelling.
Other STT providers do not gain this WhisperKit-specific recognition hint.

Corrections use the complete dictionary. They match whole spoken forms,
case-insensitively, allowing repeated whitespace between words. Longer forms win
over shorter overlapping ones. A replacement is literal and is never passed
through another replacement in the same correction pass. For example, with
`alpha → beta` and `beta → gamma`, input `alpha beta` becomes `beta gamma`.
This makes imported rules predictable, unlike the previous sequential cascading
behavior. Duplicate spoken forms in legacy files keep their first match.

## Spoken skill profiles

A profile describes the CLI you are using, its allowed applications, and the
exact command for each spoken skill. It does not install the skill into that CLI.

1. Choose **New profile**, name it, and **Add application** to select the terminal
   or editor that contains your CLI prompt.
2. Choose **Add skill**. Set its spoken name, exact command, and optional aliases
   (one per line). Save the skill.
3. Use **Try a phrase** and select an application to preview the result. This
   preview does not type or execute anything.
4. Save the profile and select it from **Skills: Off** in Settings or the VoxFlow
   menu. Put the cursor in the CLI's input before using normal quick dictation.

For a skill named `research` with alias `deep research`, these complete utterances
match:

- `research`
- `deep research`
- `use research skill`
- `use the research skill`
- `hey, use my research skill`

Capitalization, repeated whitespace, and boundary punctuation are tolerated.
“Please use the research skill when reviewing this” is longer prose and does not
match. Unknown or ambiguous names, disabled profiles, and other applications
remain ordinary dictation. The existing transcript rejection gates still apply.

The command is inserted verbatim, including its prefix, with no extra spacing or
punctuation and **no Enter key**. Commands must be one line, with no control
characters and no more than 1,000 characters. Skill names/aliases allow 128
characters, with up to 20 aliases per skill and 1,000 skills per profile.

CLI syntax differs. Claude Code exposes user-invocable skills through
`/skill-name`; plugin skills may use `/plugin-name:skill-name`.
([Claude Code documentation](https://code.claude.com/docs/en/skills))
Codex CLI and its IDE extension support `$skill-name` mentions and the `/skills`
selector. ([Codex documentation](https://learn.chatgpt.com/docs/build-skills))
Use the exact name and prefix supported by your installed client. The
[example profiles](../examples/skill-profiles.json) illustrate a hypothetical
installed `research` skill; they do not create it.

Explicitly switch profiles when changing CLI clients. VoxFlow cannot infer
whether a VS Code window is showing an editor, Claude Code, or Codex. Application
restrictions constrain which app receives shortcuts; the selected input within
that app remains your responsibility. A capture snapshots its profile and target
at the start, so changing settings during transcription affects the next capture.
Choose **Off** to disable skill shortcuts for subsequent captures.

Profiles support JSON import/export with `schema_version: 1` and a `profiles`
array. Each profile has `name`, `applications` (macOS bundle identifiers), and
`skills`. Each skill has `name`, optional `aliases`, and `command`. IDs are
optional in hand-written files. Imports match profiles by name. Existing
profiles win conflicts unless replacement is explicitly selected, and importing
does not enable shortcuts. Files allow at most 1 MB and 50 profiles, with at
most 50 allowed applications per profile.

Skill expansion applies to quick **Dictation**. The command lane, onboarding,
translation, meeting, prompt mode, and cockpit recording keep their existing
behavior. Cockpit review commands such as `undo`, `memo`, and `copy` are unchanged.
Existing ordinary voice snippets remain in their own section.

## Persistence and recovery

Configuration lives under `~/Library/Application Support/VoxFlow/`:

- `dictionary.json`: existing vocabulary plus optional recognition priority.
- `skill-profiles.json`: profiles and the selected profile, initially Off.
- `snippets.json`: existing snippets, unchanged by this update.

Writes are atomic. A save/import failure leaves the prior in-memory state and
file intact and displays an error. An unreadable existing file is preserved;
VoxFlow does not overwrite it with defaults. To recover, quit VoxFlow, restore
that file from your backup (or move the damaged file aside), and reopen the app.
Keep the damaged copy if you need to recover entries from it.

## Short recordings and measured performance

Accepted captures between 0.3 and 1 second now reach the WhisperKit decoder.
Longer recordings retain the previous tail suppression. Silence remains gated
before inference, and the decoder's `[BLANK_AUDIO]` marker is rejected by both
the Swift and Python filters. Existing short-greeting filters, including `yes`,
remain in force; the short-capture fix does not relax those filters.

Vocabulary matching is compiled when the dictionary changes, so each capture
uses the cached matcher. See the [validation record](qa/2026-09-04-reliability-vocabulary-skills.md)
for measured timings, coverage, and remaining verification work.
