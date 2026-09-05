# Voice Action Prompts: selectable computer actions

Product direction from Zola, September 5, 2026. The implemented increment contains
custom CLI command insertion, optional Automatic Enter, selectable action modes,
and twelve deterministic built-in computer actions. The expanded build still
needs signed installation and live acceptance after desktop unlock.

## User controls

- Voice actions: Off, Custom prompts only (default), Built-in computer actions
  only, or All. The palette and Settings expose the same choice.
- A checklist enables or disables each built-in action. All honors that checklist;
  a later software update does not silently select new actions.
- Custom skill profiles retain their existing portable version-1 format and
  explicit application restrictions. Profile import never changes local action
  permissions or Automatic Enter preferences.
- Automatic Enter has independent Off / Voice Action Prompts only / Ordinary
  dictation only / Both scopes. It only follows successful automatic text or
  custom-command insertion. Direct computer actions never inherit Enter.

## Implemented first set

Open Finder, Safari, Terminal, Notes, and Calculator; copy selection; paste
clipboard; select all; undo; redo; find; and new tab. Each has a complete explicit
phrase, such as “Voxflow, open Finder” or “Voxflow, copy that”. The alternative
transcription “Vox flow” is accepted. Partial phrases, longer prose, and unprefixed
built-in names do not trigger a computer action. An explicitly configured custom
skill wins if both match. Existing transcript gates remain in force.

The Python registry, `backend/app/computer_actions.py` and its versioned JSON
catalogue, validates a registered action ID and prepares a typed operation. Its
isolated process uses only the standard library; it does not start the backend
server, load a model, interpret generated code, or perform an OS effect. The
signed macOS bridge owns LaunchServices and keyboard effects, preserving the
application’s identity for macOS permissions. Both sides validate the operation
and arguments against defined application/shortcut sets.

The first set is fixed and shipped with the app. It does not yet provide arbitrary
custom direct actions, user-selected URLs/files, or a direct-action import format.
Users can already supply their own vocabulary and custom CLI skill profiles.

## Execution contract

Quick Dictation freezes action mode, enabled IDs, custom matcher, target process,
and available Accessibility window/input identities at capture start. It matches
the original accepted transcript before vocabulary corrections or prose cleanup.
Changing action controls revokes pending commands; enabling controls cannot
retroactively authorize earlier audio. The execution service checks permissions
both before and after the cancellable Python preparation step.

The native bridge checks cancellation, screen lock, secure input, and supported
arguments. App opens address the named destination through LaunchServices.
Shortcuts require the original target to remain active with the same known
window/input identities; there is no activation of a later input or retry after
an uncertain effect. Failed recognized actions do not fall through to dictation.

Receipts record action ID, destination, preparation-plus-dispatch time, and
`applicationOpened`, `keyPosted`, `canceled`, or `failed`. Capture history renders
those outcomes. No clipboard content is logged. Posting a key does not prove the
receiving application completed its work. Python preparation has a two-second
limit and cannot itself change the computer.

## Validation and delivery

Tests use fake preparation/execution boundaries and disposable configuration.
Coverage includes exact phrase routing, disabled modes/actions, preference
persistence, conservative upgrade selection, unknown/malformed operations,
revocation during preparation, failures without retries, and honest receipts.
Python protocol tests also confirm isolated startup without model/server imports.
See [the validation record](../qa/2026-09-04-reliability-vocabulary-skills.md) for
measured preparation costs, final suite results, and pending live checks.

Remaining acceptance: install the signed expanded bundle, exercise all settings
and submission scopes, run controlled direct actions in disposable apps/documents,
verify same-app window-change rejection and cancellation, restore QA configuration,
and leave automatic submission and built-in actions disabled for ordinary use.

## Later model-assisted actions

A provider-neutral planner can propose calls to this same registry. Claude Code,
Codex, and local/open-source model adapters require separate interface verification
and implementation. No planner adapter or external model invocation is included
in this increment.

Profiles should define which actions a planner may propose and which need review.
Show multi-step plans with destinations and effects; validate every step again
at execution; stop on failure/cancellation and retain completed-step receipts.
Never retry an ambiguous effect automatically or expose generated shell/Python
execution as an alternative path around the registry.

Future extensions can add user-selected applications, URLs and files, literal
clipboard text, richer accessibility operations, and a versioned custom-action
configuration format through the same contract. Each should ship with its own
input validation, target handling, meaningful tests, and observed live acceptance.
