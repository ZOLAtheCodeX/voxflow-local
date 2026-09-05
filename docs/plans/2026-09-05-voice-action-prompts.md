# Voice Action Prompts: direct computer actions

Product direction from Zola, September 5, 2026. This records the next extension;
the current implementation inserts configured commands and optionally sends Enter.
Direct Python actions and model-assisted action planning are not implemented yet.

## Current increment

The user names a phrase, its exact command, and the applications where it applies.
Automatic Enter has independent scopes for Voice Action Prompts and ordinary
dictation, with Off as the default. The app retains capture-time target identities,
records insertion and submission separately, and withdraws pending Enter when
the user changes its setting. This increment needs to pass its installed-app
acceptance checks before direct actions are layered onto it.

## First direct-action increment

Add a versioned action registry implemented in Python, with typed arguments and
a signed macOS bridge for Accessibility operations. Each configured phrase chooses
one action explicitly. Matching stays deterministic and complete-phrase based.
Keep command insertion as an existing action type so saved profiles still work.

The first candidate batch is deliberately concrete:

| Action | Configuration | Observable result |
|---|---|---|
| Open application | Selected bundle ID | The selected application launches |
| Focus application | Selected running application | That application becomes active |
| Open web address | Configured HTTP(S) address | Default browser opens that address |
| Reveal file or folder | Path selected by the user | Finder reveals the configured item |
| Copy text | Configured literal text | Clipboard contains the exact text |
| Paste clipboard | Frozen editable target | Clipboard text is pasted into that target |
| Select all | Frozen editable target | Text in that input is selected |
| Undo | Frozen editable target | The receiving app handles its ordinary Undo command |

This is a proposed initial batch, not a claim that these actions already ship.
File deletion, sending email, purchases, and unrestricted shell execution are
outside this batch. A profile should expose each action's effect and let the user
choose automatic execution or review. Existing Automatic Enter modes apply to
dictation/command insertion; they must not implicitly submit a separate clipboard
action or add a keystroke after a non-text action.

## Implementation contract

- Define an action ID, argument schema, handler, and result schema for each entry.
  Reject unknown IDs, extra arguments, control characters where inappropriate,
  oversized payloads, and unsupported schema versions before dispatch.
- Python dispatches registered functions with validated arguments. Use fixed
  executable argument arrays for OS helpers; do not interpolate a spoken phrase
  into a shell command or execute generated Python.
- Keep basic actions independent of model loading. The lightweight dispatcher
  must not import Torch or start an LLM to open an application or copy text.
- The signed macOS app owns focus-sensitive key/clipboard operations. Pass the
  retained target and cancellation identity to that bridge and verify them
  immediately before an effect. Do not infer a destination from the later
  frontmost window.
- Extend profile import/export with an explicit version migration. Imported
  actions stay inactive until selected, and imports do not enable submission or
  change local execution preferences.
- Record action ID, execution status, timing, target, and whether the effect was
  merely dispatched or actually observed. Avoid claiming an application finished
  its work just because a process or key event was launched.

## Model-assisted actions afterward

Add a provider-neutral planner that can propose calls to the same registry.
Claude Code, Codex, or a local model can be separate adapters after their actual
interfaces are verified. The planner returns a structured plan of registered
action IDs and arguments. It does not receive an unrestricted execution channel.

Profiles define which actions the planner may propose and which can run without
review. Show multi-step plans with their destinations and effects, validate each
step again at execution, stop on failure/cancellation, and preserve completed-step
receipts. Do not retry an effect automatically when its completion is unknown.

## Acceptance for the next increment

Use mocked OS bridges for unit tests and disposable targets for live checks.
Verify each action's normal result, invalid inputs, unavailable targets,
cancellation, changes of window/field, and failed helpers. Confirm no model is
loaded for deterministic actions. Test profile migrations and imported defaults.
For a planner, test unknown tool names, malformed arguments, disallowed actions,
interrupted plans, and ambiguous completion before enabling real effects.

Deliver the registry, the chosen first batch, configuration UI, examples, measured
dispatch costs, a signed installation, and an accurate live validation record as
one bounded follow-up. Add further actions only through that same contract.
