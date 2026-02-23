# Confidence Indicator UI — Design

## Summary

Display transcription confidence as a color-coded dot + percentage in the review card and Recent history. Data already flows through `TranscribeResponse.confidenceEstimate` from both WhisperKit and backend paths but is currently logged and discarded.

## Data Model

Add `confidence: Double` field to `TranscriptCandidate` (default `0.0`). Thread `transcription.confidenceEstimate` from `AppCoordinator.stopCaptureAndProcess()` through all `TranscriptCandidate(...)` construction sites.

## View Component

New `ConfidenceBadge` SwiftUI view:
- Small filled `Circle` (8pt) + percentage text in `VF.captionFont`
- Color thresholds: green >= 0.7, yellow 0.4–0.7, red < 0.4
- Hidden when confidence is 0.0 (hallucination-filtered empty results never reach review)

## Placement

**Review card** (`CommandPaletteView.dictationReview`): trailing edge of mode chip row.

```
[Raw] [Light] [Polish]   <Spacer>   🟢 85%
```

**Recent tab**: each history row gets the same badge after the mode label.

## Edge Cases

- Confidence 0.0 on filtered result: review card not shown (empty text → idle)
- Idle state: no candidate → badge hidden
- Retone: confidence preserved from original transcription (not recomputed)

## Testing

- Unit test `ConfidenceBadge` color thresholds (green/yellow/red boundaries)
- Unit test `TranscriptCandidate` stores confidence value
- Verify 211 existing Swift tests still pass

## Files to Modify

1. `Models/AppModels.swift` — add `confidence` to `TranscriptCandidate`
2. `AppCoordinator.swift` — thread confidence through ~6 construction sites
3. `Views/CommandPaletteView.swift` — add badge to review card + recent items
4. New: `Views/ConfidenceBadge.swift` — the badge component
5. New: `Tests/VoxFlowAppTests/ConfidenceBadgeTests.swift` — threshold tests
