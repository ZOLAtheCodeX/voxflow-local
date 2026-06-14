# Security policy

## Reporting a vulnerability

Please report security issues privately through
[GitHub Security Advisories](../../security/advisories/new) rather than a
public issue. You should receive a response within a week.

## Scope and posture

VoxFlow Local is a local-first dictation app. The security-relevant surfaces:

- **The backend binds 127.0.0.1 only** (port 8765) and is not designed to be
  exposed to a network. Reports that assume a remote attacker reaching the
  API are out of scope unless they show a path from a default configuration.
- **API keys live in the macOS Keychain** (`voxflow.provider.<id>`,
  private-API keys), never in config files or UserDefaults. Keys transit to
  the backend as process environment variables at launch. Anything that
  causes a key to be written to disk or logged is in scope and high severity.
- **Dictated text is sensitive by design.** Cloud providers are opt-in and
  off by default. Cloud-bound text payloads pass PII redaction first; the
  private-API mode adds an explicit per-request preview/consent step. Cloud
  STT fallback is off by default and gated by `VOXFLOW_STT_ALLOW_FALLBACK`
  (raw audio cannot be redacted, so it never leaves without opt-in). Bypasses
  of the opt-in requirement, the redaction pass, or the private-API consent
  flow are in scope.
- **Accessibility insertion** types into whatever app holds focus. Anything
  that lets untrusted input drive an insertion (or fire a voice-triggered
  protocol) without the documented gates is in scope.
- The experimental **assistant handoff** pipes transcripts to a
  user-configured CLI. It ships off by default, never auto-executes, and
  shows a payload preview; execution authority belongs entirely to the
  external tool's own permission model. Prompt-injection reports should
  target the gating, not the external tool.

## Supported versions

Pre-1.0: only the latest tagged release and `master` receive fixes.
