# Atlas v1.2.1 — Search, Complete Paging & Keyboard Navigation

Baseline: Atlas v1.2 — Persistent Results, Faster Paging & Clean Tabs. This is an incremental patch to the existing project.

## Changes
- Search uses SQLite FTS5 path-token prefix indexing when available, with a LIKE fallback. It searches the current category/status result set and matches folder/path components as well as filenames.
- A search or sort reload no longer clears the current rows while the replacement query is running. A progress indicator appears, and the new page replaces the old list only when ready.
- Scrolling has a larger near-end prefetch threshold, a loading footer, and an explicit Load next batch fallback.
- Down-arrow navigation can cross page boundaries by requesting the next page instead of stopping at the last loaded row. Clicking a result clears stale search-field first-responder focus so arrows work again in the results pane.
- The UI displays the version badge `v1.2.1`; bundle version is 1.2.1/build 4.
- Path-aware exclusions skip generated thumbnail trees in Library/application-support contexts, application-support image/audio assets, standalone `.icns` resources, package internals, and the existing cache/system paths. Application Support is not skipped wholesale; user media folders are not excluded.

## Deliberately unchanged
- Duplicate detection algorithms, cross-format comparison, BEST-first grouping, SQLite result storage, category streaming/release, scan/pause/resume/stop flow, delete-to-Trash, move confirmation, video preview, uniform category tabs, and existing result database location.
- Existing `~/Library/Application Support/Atlas/Results.sqlite` is not removed by the installer. FTS5 path index is added/migrated in-place if supported by the system SQLite build.

## Validation limitation
This package was statically reviewed in a Linux environment. `xcodebuild` and a live macOS UI test cannot be run here. Build and test on the target Intel Mac before relying on it for a long scan.

## Regression checklist on the Intel Mac
1. Open Atlas and confirm the header shows `v1.2.1`; run `./verify_installed_v1.2.1.sh` and confirm `1.2.1` / build `4`.
2. Reopen the app after a completed scan: confirm the saved list loads without starting another scan.
3. In Images, search `desktop`: results should include image paths under Desktop even when filenames do not contain the word. Clear Search and confirm the unfiltered tab returns.
4. While searching, confirm the old list stays visible until replacement results arrive; the UI should show a loading/search status.
5. In a tab with more than 300 unique results, scroll down through several pages and confirm the loaded/total count advances until it reaches the total; use `Load next batch` if needed.
6. In Duplicates with tens of thousands of files, scroll through the whole result set; confirm BEST-first groups and separators remain intact.
7. Select the first row, press Down repeatedly past the first page boundary, then Up; preview must update and the selected row must remain visible. Repeat after clicking Search and then clicking a result row.
8. Scan with Images completing before Videos; confirm completed tab rows remain available while the next category runs.
9. Confirm app bundle internals, Application Support image/audio assets, system sounds, and generated thumbnail trees are absent, while ordinary user files in Desktop, Documents, Downloads, Pictures, and Music remain included.
10. Confirm delete still sends files to macOS Trash, Move still confirms and avoids overwrites, video preview still plays, and cross-format duplicate grouping remains unchanged.
