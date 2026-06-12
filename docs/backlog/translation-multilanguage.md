# Backlog: multi-language translation (post-launch)

**Status:** deferred at R5.5 (2026-06-12) per the product plan — v0.1 ships
EN->DE only.

**Today:** the language pair is hard-locked in four places:
`TranslateEngine.translate(text)` (single-pair signature),
`ProviderRouter.translate` (400 on any other pair),
`PrivateAPIClient.translate_en_de` (name + prompt), and the
`TranslateRequest` schema defaults.

**The refactor:** `translate(text, source_lang, target_lang)` through all
four layers; profile selection per pair (TranslateGemma supports many
pairs; Marian needs per-pair checkpoints); Settings UI for pair choice;
benchmark per pair. BYOM (R3) makes an LLM-translate chain a natural
alternative backend for long-tail pairs.

**Acceptance when picked up:** EN->DE behavior unchanged; at least one
additional pair (EN->ES) end to end with golden cases.
