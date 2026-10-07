# Atlas — Tab Streaming / Progressive Results

This build keeps the existing scan, comparison, cross-format detection, and SQLite-paged UI architecture intact.

## New behavior

- Each main category tab fills from **red → yellow → green** as that category's comparison progresses.
- When a category reaches green, its current results are immediately persisted to the live SQLite result store.
- A completed category can be selected and browsed before the entire scan finishes.
- The large per-category `AnalysisBundle` graph is released before the next category begins.
- The global comparison architecture is preserved. Final exact/cross-format reconciliation is still performed before the scan is marked fully complete.
- While scanning/paused, Delete and Move are disabled so a later cross-category reconciliation cannot race with file mutations. Preview, navigation, search, sorting and browsing of completed results remain available.
- At final completion the live database is replaced with the final reconciled result database.

## Memory behavior

The change does NOT duplicate the entire 500k/1M-file result set into SwiftUI. Category snapshots are written to SQLite. A small category dictionary is temporarily copied for the snapshot, then released. The existing global `FileRecord` metadata dictionary remains part of the proven comparison architecture; the expensive analysis bundles are still category-scoped.

## Important semantic note

A green tab means that category's current category-level comparison is complete and available. Later categories may still discover an exact or cross-format relationship with an earlier category. The final database reconciles those relationships before the scan is marked Completed.


## Stop release behavior

Pressing Stop releases the partial result database instead of discarding it. Categories with released records become usable immediately after the stop finalization. Records still pending comparison are surfaced under Unique as **provisional unique**; they have not been proven duplicate-free. Files that failed decoding remain Uncompared. Delete/Trash is enabled after Stop so already-confirmed duplicate groups can be acted on immediately.
