ATLAS v2.1.2 — Build 16 — Intel x86_64

List, Tiles, and Large views. Duplicate groups stay separated by a thick rule in every view.
Local pair model keeps learning from NOT DUPLICATE / NOT UNIQUE. No cloud.

Canonical installer: `install_v2.0.1.sh` (installs only to `/Applications/Atlas.app`).

# ATLAS 2.0.0 — Offline ML / Human Feedback

Intel x86_64 macOS 13+ file inventory and duplicate analysis.

## Privacy

ATLAS 2.0 performs scanning and ML inference locally. The project contains no network AI client, cloud model endpoint, telemetry service, or model-download step. Network entitlements are disabled.

Local state is stored under:

- `~/Library/Application Support/Atlas/Results.sqlite`
- `~/Library/Application Support/Atlas/OfflineFeedback.sqlite`
- `~/Library/Application Support/Atlas/OfflinePairModel.json`

## Classification philosophy

ATLAS does not force uncertain files into Duplicate. It uses:

1. exact SHA-256 content identity;
2. format-specific deterministic signatures;
3. conservative perceptual image comparison;
4. Vision feature-print ML for ambiguous image candidates;
5. a small locally trained pair classifier using trusted matches and explicit user feedback;
6. persistent user veto/override memory;
7. `Uncompared` when evidence is insufficient.

No system can guarantee perfect semantic duplicate detection for every possible file. This build is deliberately designed to avoid false duplicate claims rather than manufacture certainty.

## Human feedback

- In **Duplicates**, select one or more items and press **NOT DUPLICATE**.
- In **Unique**, select one or more items and press **NOT UNIQUE**.

Feedback is stored locally and reused on future scans.

`NOT DUPLICATE` stores pairwise negative relationships with the item's previous group members and updates the local image-pair learner when applicable.

`NOT UNIQUE` stores a persistent file-level duplicate override. It is represented as a singleton manual duplicate group until another matching item is found; ATLAS does not invent an unrelated partner.

## Installation

1. Extract this package.
2. Open Terminal.
3. `cd` into the extracted package directory.
4. Run:

    `./install_v2.0.0.sh`

The installer performs a project/version preflight, builds with Xcode for Intel x86_64, verifies the produced app, backs up any existing `/Applications/Atlas.app`, installs only after successful verification, verifies the installed version, and launches ATLAS.

If compilation fails, the existing `/Applications/Atlas.app` is not replaced.

## Build

`./build.sh`

## Verify installation

`./verify_installed_v2.0.0.sh`
