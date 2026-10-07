# Atlas v1.2.2 — Complete List, Stable Tab Switching & Folder Search

Baseline: Atlas v1.2.1.

## Fixed
- Result rows remain backed by their loaded FileRecord data while paging, so older rows do not turn blank or lose preview data after the list grows.
- A bottom sentinel automatically requests the next page when the user actually reaches the end; the explicit Load next batch control remains as a fallback.
- Changing Unique/Duplicates/Uncompared, category, kind, or sort clears the old list immediately and loads only the newly selected result set. Old Unique rows therefore cannot remain visible underneath a Duplicates loading state.
- Removed redundant tab reload calls that could race the state transition.
- Bare searches for common user folders are now true folder scopes. `desktop` means `/Users/<current-user>/Desktop/...`, not arbitrary paths containing the word Desktop. Documents, Downloads, Pictures, Music, Movies, and Public are handled similarly.
- General multi-token/name/path search continues to use the indexed FTS5 path search where available.
- Arrow-key navigation continues to use the existing move-command/local-key handling and can cross loaded page boundaries.

## Deliberately unchanged
- Scan engine and category streaming.
- Cross-format duplicate comparison.
- BEST-first duplicate grouping.
- Persistent SQLite result database.
- Delete-to-Trash and move confirmation.
- Video preview.
- Application/system asset exclusion rules.
- v1.2.1 search debounce and FTS infrastructure.

## Validation
This patch was inspected against the v1.2.1 source package. A full macOS Xcode build/live UI test must still be performed on the target Intel Mac.
