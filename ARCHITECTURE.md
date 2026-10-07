# Mac File Inventory & Duplicate Manager — Architecture

## Design goals

1. Content-based, conservative duplicate detection (false positives → Uncompared).
2. Safe file operations (Trash only, collision-safe moves, confirmations).
3. Entire internal disk + arbitrary folder / mounted volume.
4. Hierarchical Unique / Duplicates UI with real checkboxes and keyboard navigation.
5. Image, video (with playback), and PDF preview.
6. Large-disk scanning that stays pause/stop capable and reasonably responsive.
7. Optional local enhancement (Core ML when a model is present; honest Core Image pipeline otherwise).
8. Single self-contained macOS app, Intel x86_64, no network for core work.

## Module map

```
App            Window, AppState (source of truth), theme
Models         FileRecord, categories, scan location, list rows, statistics
Scanning       UTI + magic-byte type detection, volume-aware walker, scan session
Detection      Staged hashing + media/document/archive analyzers + grouping
Operations     Trash, move, collision names, confirmation summaries
Enhancement    Local image/video upscale pipeline
UI             Stable custom tabs, progress, list, preview, sheets
```

## Scan session model

`AppState` holds:

- `displayedSession` — what the UI shows
- `activeEngine` — running walker / classifiers
- Scan phase: idle | scanning | paused | completed | stopped

A new Scan does **not** wipe `displayedSession` on button press. The engine starts in the background; the first committed inventory batch replaces the displayed session. That avoids the “everything flashed to zero” bug.

Pause is cooperative: workers check `ScanControl` between files. Stop cancels the task and keeps partial results.

Entire Mac uses the root volume identifier of `/` and refuses to cross into other volumes (external drives). `/dev`, VM swap, Spotlight, fsevents, and (on Entire Mac only) bundled packages are skipped. Select Folder follows the chosen URL, including `/Volumes/...`.

## Duplicate pipeline (staged, never filename-based)

Filename, path, and extension are never evidence of duplication.

```
enumerate + categorize
        │
        ▼
cheap identity: size + prefix/suffix digest   (candidate buckets only)
        │
        ▼
exact SHA-256 when size matches               (binary-identical groups)
        │
        ▼
category analyzers (decode / extract)
        │
        ▼
conservative grouping on strong signatures
        │
        ▼
Unique | Duplicate-group | Uncompared
```

Uncompared is a **result status**, not a scan checkbox.

### Images

Decode via ImageIO. Signatures:

- dimensions + aspect
- 64-bit DCT pHash (32×32 luminance DCT, 8×8 low-frequency bits)
- 64-bit dHash
- 16×16 mean-normalized luminance grid (used only as a confirming signal)

Two images are duplicates only when **all** hold:

- aspect ratio within 3%
- pHash Hamming ≤ 3
- dHash Hamming ≤ 3
- 16×16 mean absolute difference ≤ 6 (of 255)

A crude 32×32 average-grey fingerprint is never the final decision. Cross-extension comparison is natural because decoding happens before hashing.

### Image-only PDFs

PDFKit page count + extracted text length. If text is negligible and there is one page (or every page is image-dominated), each page is rendered and given the same image signature. Those PDFs may join image groups when the visual evidence is strong. Text PDFs never enter the image path.

### Videos

AVFoundation metadata + seven sampled frames at 0, 10, 25, 50, 75, 90, 100%. Each frame gets a pHash. Duplicates require:

- duration within 0.25 s or 0.5%
- at least 6 of 7 frames with pHash Hamming ≤ 4

One-frame comparison is never enough. Failed decode → Uncompared.

### PDFs (PDF-to-PDF)

- page count must match
- if normalized text is long: exact SHA-256 of normalized text
- else: per-page render pHash with the same conservative Hamming rule

### Office (Word / PowerPoint / Excel)

Never `String(contentsOf:)` on the binary. OOXML files are ZIP-parsed; `word/document.xml`, `ppt/slides/slide*.xml`, `xl/sharedStrings.xml` + sheet XML are tag-stripped and hashed. Legacy OLE `.doc/.ppt/.xls` without a reliable extractor go to Uncompared.

### ZIP / RAR

ZIP: central-directory manifest of normalized names + uncompressed sizes + CRC-32, then SHA-256 of that manifest.

RAR: conservative local header walk when the signature is recognized. If the archive cannot be parsed reliably → Uncompared (no guessing).

### Other

Exact binary hash only. Otherwise Unique if readable, Uncompared if not.

### BEST file

BEST is the current representative (largest, then oldest created, then shortest path). It is **not** locked. Deleting or moving it promotes another member and the UI says so.

## UI principles

- Custom tab bars (not `TabView`) so disabled categories cannot collapse the window.
- Real `Toggle` + `.checkbox` style; row click selects for preview only.
- `List(selection:)` plus `onMoveCommand` for arrow keys; preview follows selection; `ScrollViewReader` keeps the row visible.
- `AVKit.VideoPlayer` keeps transport controls.
- Progress bar is a large green capsule with percent + live path.
- Statistics sit on **one** horizontally scrollable line.

## Enhancement

`EnhanceEngine` loads an optional bundled `.mlmodel` (Core ML, `cpuAndGPU` — no ANE assumption). If no model is present it runs a local Core Image pipeline (Lanczos scale, noise reduction, unsharp) and labels it **Local enhancement**, never “AI”. Originals stay untouched when “Preserve original” is on; output uses collision-safe names.

## Privacy

No network, no telemetry, no cloud embeddings. Scan is read-only. Only Trash / Move / Enhance mutate the filesystem, and only after an explicit user action.
