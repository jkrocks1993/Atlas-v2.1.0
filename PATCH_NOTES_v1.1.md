# Atlas v1.1 — Responsive Search & Navigation

Baseline: **Atlas v1.0 — Interactive Tab Streaming**

## Changed
- Debounced search input (320 ms) so typing does not query SQLite for every keystroke.
- Category/result counts are cached asynchronously; SwiftUI rendering never performs the old synchronous SQLite COUNT calls during an active scan.
- Restored/strengthened Up/Down selection using SwiftUI move commands while retaining the existing AppKit arrow-key monitor.
- Arrow navigation now uses minimal-scroll behavior: the selected row stays where it is while visible and the viewport moves only when the row leaves the visible area.

## Deliberately unchanged
- Scan engine
- Cross-format duplicate detection
- Category streaming/release architecture
- Stop/pause/resume behavior
- SQLite result schema
- Deletion logic
- Tab colors and availability behavior
