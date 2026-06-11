# Donna Method

Use this operating method for fast, safe agentic development.

## Core Cadence

Build in bold, meaningful product strides. Prefer a major-session train over tiny disconnected tasks when an end-to-end corridor is available.

Default cadence:

1. Builder session with 2-4 connected phases.
2. Use subagents/swarms for parallel discovery, design, testing, and review.
3. Commit at phase boundaries.
4. Run one consolidated audit + fix loop at the end.
5. Auditor may apply small non-forbidden fixes and commit them.
6. Do not start the next feature wave inside the audit.

## Principles

- Build runnable systems, not slideware.
- Make evals and smoke commands first-class product surfaces.
- Prefer deterministic local proofs before live integrations.
- Use boring, inspectable artifacts: JSON + static HTML under ignored `out/`.
- Reuse existing seams; do not create a second framework if composition works.
- Treat autonomy as earned.
- Keep irreversible or external actions behind explicit human authorization.
- Bigger sessions are good; hidden autonomy is not.

## Prompt Style

Always provide operator prompts in Markdown code blocks for clean copying. Paste only the contents, not the triple backticks.

In an IDE already rooted to the repo, omit explicit `Work in ...` lines. The agent must still verify location before git commands.

Target roughly 4000 chars per goal prompt. Split into multiple prompts only when needed.

## Direct Builder Prompt Template

```text
/superpowers:subagent-driven-development

/goal <SHORT_GOAL_NAME>

Start <project/version> <feature title>.

Intent: <bounded product slice and explicit non-scope>.

Base:
- Branch: <branch>
- Start from HEAD: <sha> <subject>
- Relevant prior commits/docs

Read first:
- AGENTS.md
- progress.txt
- relevant docs/source/tests

Use subagents:
- Context Scout: map current code/docs/patterns.
- Product/Runtime Scout: define the corridor and reuse seams.
- Test Designer: specify tests before/during implementation.
- Boundary Reviewer: check forbidden paths, live adapters, send/network/package drift.
- Adversarial Reviewer: review final diff before commit; findings first.

Create/update:
- exact intended files

Requirements:
- behavior requirements
- artifact requirements
- non-scope boundaries
- safety boundaries

Validation:
- focused tests
- operator command(s)
- lint/type checks as appropriate
- git ls-files out/

Commit:
- stage only listed files
- commit message: `<type(scope): subject>`
- preserve unrelated dirty/untracked files
- no push unless explicitly requested

Final report:
1. Executive summary
2. Subagents used
3. Files changed
4. Behavior built
5. Safety boundaries
6. Validation matrix
7. Residual risks
8. Repo state

Completion text:
<GOAL_COMPLETE_TOKEN>
```

## Multi-Agent / Swarm Roles

Use swarms when parallel work reduces cycle time or improves coverage.

Recommended roles:

- Lead Builder: owns final decisions, edits, staging, validation, commits.
- Context Scout: maps code, docs, commits, and local patterns.
- Product Architect: defines the end-to-end user/operator corridor.
- Runtime Scout: identifies reuse seams and prevents duplicate framework wiring.
- Eval Harness Scout: maps eval/report surfaces and proposes minimum eval additions.
- Artifact Designer: defines JSON/HTML artifacts, escaping, banned UI surfaces.
- CLI/Operator Designer: matches existing script/package command patterns.
- Test Designer: writes/proposes tests.
- Boundary Reviewer: scans forbidden paths, live adapters, send paths, package/lockfile drift, tracked artifacts.
- Adversarial Reviewer: reviews final diffs before commits.
- Audit/Fix Agent: independently verifies the session and applies small non-forbidden fixes.

Rules:

- Subagents are bounded specialists, not autonomous owners.
- Lead Builder stages and commits during builder sessions.
- Audit/Fix Agent stages and commits during audit sessions.
- If agents disagree, prefer the stricter safety boundary.
- Stop if any agent finds an unauthorized forbidden-path, live-send, live-mailbox, dependency, lockfile, or credential blocker.

## Consolidated Audit Prompt Template

```text
/superpowers:subagent-driven-development

/goal POST_SESSION_AUDIT_AND_FIX

Start <project/version> Post-Session Audit + Fix.

Intent: independently verify the full builder session end-to-end. Treat builder output as untrusted until verified against code, tests, docs, artifacts, package scripts, and git history. This is not new feature work.

Base:
- Branch: <branch>
- Start from HEAD: <sha> <subject>
- Builder commits: <list>

Read first:
- AGENTS.md
- progress.txt
- all phase docs
- changed source/tests/scripts/configs

Audit mandate:
1. Verify repo location.
2. Reconstruct commit train and changed files.
3. Verify each phase behavior.
4. Verify tests and artifacts.
5. Verify docs do not overclaim.
6. Verify no forbidden-path edits.
7. Verify no unauthorized live network/OAuth/mailbox/send/dependency/lockfile drift.
8. Verify unrelated dirty/untracked files preserved.

Fix mandate:
- Fix confirmed defects in non-forbidden files with smallest patch.
- Correct docs overclaims.
- Harden weak tests if needed.
- Stop and report if fix requires forbidden paths, credentials, live services, dependencies, schema/persistence churn, or send execution.

Validation:
- focused tests
- operator smoke command(s)
- lint/type checks
- full test suite if feasible
- git ls-files out/
- package/lockfile diff checks
- forbidden-path diff checks

Commit:
- commit fixes first
- commit audit report last
- stage specific files only
- no push unless explicitly requested

Required final report:
1. Executive summary
2. Findings first with file/line evidence
3. Fixes implemented with commit SHAs
4. Commit train audited
5. Behavior verified
6. Safety boundaries verified
7. Validation matrix
8. Residual risks
9. Repo state
10. Recommended next move

Completion text:
POST_SESSION_AUDIT_AND_FIX_COMPLETE
```

## Ralph / Ruflo Notes

If using Ralph/Ruflo loops, use explicit completion promises. If the loop is blocked by permissions or keeps refiring after verified completion, do not fight it. Convert to a direct `/superpowers:subagent-driven-development` prompt or close the session.

Use Ralph/Ruflo for larger autonomous loops only when permission setup supports it. Use direct subagent-driven prompts for small waves.
