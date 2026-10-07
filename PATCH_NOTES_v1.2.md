# Atlas v1.2 — Persistent Results, Faster Paging & Clean Tabs

Baseline: Atlas v1.1 — Responsive Search & Navigation

## Changed
- Added an always-visible `v1.2` badge in the Atlas header so the installed patch is immediately identifiable.
- Restored saved result-list loading as an explicit startup phase: existing `Results.sqlite` remains the durable source of truth and the first 300 rows are loaded asynchronously.
- Moved startup statistics calculation off the main UI thread so a very large database does not block the interface before rows can appear.
- Added SQLite indexes for category/status + path, size, modified date, and created date to accelerate the common first-page sorts on large scans.
- Application/package internals are skipped for both entire-Mac and selected-folder scans. This excludes implementation assets such as `.app` icons, bundled sounds, frameworks, plugins, etc., rather than treating them as user files.
- Category tabs are now uniformly 154 px wide and horizontally scrollable; full category names are not intentionally compressed/truncated.

## Deliberately unchanged
- Cross-format comparison/deduplication engine.
- Scan architecture, Pause/Resume/Stop, tab streaming and Stop/release behavior.
- SQLite result storage model and deletion logic.
- Debounced search and arrow-key navigation from v1.1.
- Source files remain untouched by scanning.

## Version identity
- Marketing version: 1.2
- Build: 3
- App header: `v1.2`
- Narrow system-asset exclusions also cover macOS system sound/audio asset directories, so default system tones do not clutter the inventory. User-selected audio elsewhere is unaffected.
