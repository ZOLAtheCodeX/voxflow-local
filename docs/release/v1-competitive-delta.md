# VoxFlow v1 Competitive Delta (vs FlowClone)

Date: 2026-02-14

This document records intentional differences from FlowClone for VoxFlow v1.

## 1) Privacy Gate Is Non-Negotiable

- VoxFlow keeps explicit privacy preview + consent token flow before private API operations.
- Rationale: private/local-first trust boundary is a core product constraint.

## 2) Multi-Provider Speech Routing Is Preserved

- VoxFlow supports local STT, private API, and OpenAI STT/TTS as advanced options.
- Rationale: operational flexibility and migration safety for different environments.

## 3) Python Sidecar Remains in v1

- VoxFlow keeps the Python backend in v1 and hardens packaging/readiness around it.
- Rationale: fastest path to signed release while maintaining existing local model support.

## 4) Dictation Core Is Release Scope; Other Modes Are Experimental

- Dictation remains always-enabled and release-quality.
- Translation and meeting modes are feature-gated as experimental.
- Rationale: ship reliability-first without deleting differentiators.

## 5) Release Path Targets Signed + Notarized Direct App

- VoxFlow adds release scripting for hardened runtime signing and notarized DMG.
- Rationale: practical trusted-distribution path without App Store constraints.

## 6) Source-of-Truth Build System Stays Stable

- VoxFlow remains SPM-driven for code ownership and test runs.
- Rationale: avoid disruptive tooling migration during release hardening.

## Review Cadence

Update this file before each release candidate cut.  
If any delta is removed or inverted, add rationale and migration impact.
