# Profile revocation: independent review and fix

Reviewed baseline: c871045 (PR #16). This follow-up supersedes broad revocation
claims in the original delivery record; the original live checks covered the
master action mode, built-in switches, prefix setting, and Automatic Enter—not
Skills → Off or active-profile edits during a capture.

## Findings verified independently

1. Skills → Off, active-profile deletion/switching, and edits/import replacement
   changed SkillProfileStore without revoking AppCoordinator’s captured matcher
   permission. The old command could still insert and, with the captured Enter
   setting enabled and unchanged target focus, submit. This is a fix-before-merge
   defect. Clearing the captured matcher would be incorrect because it permits
   ordinary-dictation fallback instead of cancellation.
2. Temporary paste preserves only a string, losing other clipboard representations
   and failing to restore an empty clipboard. The same code exists on master.
   Track it separately in [issue #17](https://github.com/ZOLAtheCodeX/voxflow-local/issues/17).
3. Related cancellation gap: if permissions are withdrawn while the insertion
   service is waiting to paste, that service can refuse the effect but the text
   coordinator would still make a recovery clipboard copy. The new guard covers
   that consequence of revocation; it does not rewrite pasteboard preservation.

Installed preferences were read independently before any change: Automatic Enter
Off, action mode All, prefix optional. The prefix preference controls built-in
computer actions only; custom skill names already support bare phrases. The
installed setup therefore limits automatic submission, but does not cure finding 1.

The previous nine observed computer-action effects were not re-tested as part of
this focused fix. Notes recognition, Safari foreground, Terminal New tab, and the
short-command [Pop] annotation retain their earlier verification limits.

## Implementation

AppCoordinator installs one synchronous subscription to the store’s profiles and
active-profile ID. It derives the effective active profile, removes duplicate
values, and ignores the initial emission. A changed active profile revokes the
current capture’s voice-action permission and pending Enter when that capture
permits custom prompts. It retains the original matcher to classify old audio as
a canceled command. Store notifications occur after successful persistence, so
failed saves do not withdraw valid permissions. Inactive-profile changes and
no-op saves do not revoke. Built-in-only captures are unaffected. In All mode,
the shared permission also cancels a pending built-in action. Enabling a profile
from Off during capture revokes that permission too; it never grants the old
audio access to the newly enabled mappings.

The text coordinator rejects already revoked commands before entering insertion,
and avoids the failure clipboard fallback when permission is revoked during an
await. Already posted text keeps its receipt; the insertion service independently
withholds Enter. A narrow injected failure-copy closure allows regression tests
to prove the absence of clipboard side effects without rewriting the pasteboard.

## Verification

Eight regression tests call AppCoordinator's subscription helper directly, using
real temporary profile-store commits, the real TextInsertionCoordinator, and fake
insertion/clipboard boundaries. They do not execute the initializer that installs
and retains the production subscription. They also do not instantiate the
AppCoordinator singleton or operate the microphone, keyboard, Accessibility
insertion, or system clipboard. Coverage includes:

- Off, removal, switching, command/alias/application edits, removing a mapping,
  and replacing the active profile through import;
- retained old-command classification and no insertion under all four Enter modes;
- initial emission, no-op updates, inactive-profile edits, conflict keep behavior,
  invalid changes, and failed persistence;
- revocation during insertion wait without a recovery copy;
- already-posted text retaining its skipped-Enter receipt without retry;
- ordinary insertion failures retaining their intentional recovery copy;
- new settings not granting authority to old audio and fresh captures remaining
  usable; profile changes leaving built-in-only captures alone.

The initial eight tests and the combined 36 focused tests passed. A first controlled
mutation check was blocked by the nested Swift manifest sandbox and is not counted
as a test result. The production sources were restored afterward. Two host-access
mutation checks failed as intended: removing the helper's revocation calls, and
removing the post-insertion permission guard. Restored sources passed the full
Swift suite: **759 tests, 3 skipped, 0 failures**. These checks establish coverage
of the helper behavior and stale recovery-copy guard, not the initializer binding.
Signed installation and CI results are recorded in the delivery continuation below.


## Delivery continuation

Functional source commit: `0ca7e0e`. GitHub CI passed Swift build/tests, Python
checks, and Ruff ([run](https://github.com/ZOLAtheCodeX/voxflow-local/actions/runs/34041841898)).
The repository release and install scripts built and installed the update at
`~/Applications/VoxFlow.app`, launched through LaunchServices. Voxflow was not
running before replacement, so no active capture was interrupted.

Deep/strict signature verification passed. Installed and staged code-directory
hashes match: `746831c41b2c16fa97278609271cb00a2799f7b9`, team `7J4FA23ZCN`.
The relaunched installed app was observed at **STT ready** through its Accessibility
UI snapshot, not the unified log. This is a signed
startup smoke check, not a claim that the new revocation scenarios were repeated
through live acoustic input; those scenarios were verified through the real
subscription helper/store and fake effect boundaries described above.

The current app and configuration were retained privately under
`~/Documents/Codex/voxflow-rollbacks/2026-09-06-before-profile-revocation/`.
Vocabulary and profile files matched the pre-install backup byte-for-byte (including
an absent profile file remaining absent). All four affected preferences matched
the backup: Automatic Enter Off, voice actions All, prefix optional, and unchanged
individual action IDs. No test vocabulary or skill profiles were added to the
installed app during this follow-up.

PR #16’s description now separates the previously tested live controls from the
new profile-revocation regression tests. It explicitly distinguishes private QA
clipboard restoration from the app limitation in issue #17. The PR remains a
draft; no merge or public release was performed.

## Closeout review

The review of `3a9dcc1` correctly identified an overstatement in the earlier QA
record and PR body: the tests do not protect the four initializer lines that
install and retain the subscription. An independent mutation removed only those
lines and all eight focused tests still passed. The source was restored
byte-for-byte afterward, and the restored eight-test run also passed with no
failures. The restored initializer binding is present by source
inspection; its removal is not caught by the current tests. The earlier two
mutation results remain valid within their narrower helper/guard scope.

CI passed on both `0ca7e0e` and the documentation commit `3a9dcc1`
([latter run](https://github.com/ZOLAtheCodeX/voxflow-local/actions/runs/34042300575)).
This closeout changes documentation and explanatory comments only. It does not
change runtime behavior, replace the installed app, or repeat live voice capture.
The installed app's deep/strict signature was reverified; its code-directory hash
still matches the delivery record above.

Non-blocking follow-ups remain explicit:

- Add an isolated coordinator-initialization harness. Its regression test must
  fail when only the initializer subscription installation is removed; directly
  calling the helper is insufficient. Avoid mutating the installed profile store
  or starting native capture/insertion services for this test.
- Revocation during the paste wait withholds insertion and the recovery clipboard
  copy, but currently returns to idle without the earlier-path “Voice action
  canceled” status. This is a feedback limitation, not an effect being dispatched.
- Full temporary clipboard preservation remains in issue #17.
