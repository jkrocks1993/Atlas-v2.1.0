# Performance / Memory Changes

This revision keeps the existing UI, names, categories, comparison rules, thresholds, and file-operation behavior unchanged. The changes are internal resource-management changes only.

## Memory strategy

- Duplicate analysis is processed one category at a time.
- The previous full `AnalysisBundle` dictionary for the entire scan is no longer retained.
- The redundant copy `var working = files` was removed; classification mutates the existing store in place.
- Each individual analysis is wrapped in an autorelease pool so ImageIO, PDFKit and AVFoundation temporary native allocations are released promptly.
- Cross-format comparison retains only the compact signatures required by the existing cross-format rules.
- Final status assignment no longer re-opens/re-decodes every file a second time.
- Full-resolution ImageIO fallback decoding was removed. If a bounded thumbnail cannot be produced, the existing conservative Uncompared path is used instead of risking a huge allocation.
- ZIP extraction has a hard resource guard to prevent a single archive entry from allocating an uncontrolled amount of RAM.

## Completion behavior

The scanner still uses the same staged scan -> comparison workflow and the same progress UI. Category comparison now completes and releases its large temporary analysis state before the next category is processed, reducing long-lived memory pressure and avoiding the previous end-of-scan memory spike.

The Xcode project remains Intel/x86_64 and no network/cloud dependency was introduced.
