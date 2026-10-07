# ATLAS 2.1.1 (build 15)

Patch. Not a new application.

- Click selects one file. Trackpad and mouse are the same.
- Command-click adds or removes a file.
- Shift-click selects the range from the anchor to the clicked file.
- Delete and Move use that selection.
- Arrow keys still only move the preview.
- The app installs to /Applications/Atlas.app.
- The header version opens these notes inside the app.

Install this patch from the existing clone:

```bash
cd ~/Downloads/Atlas-v2.1.0
git pull --ff-only
chmod +x update.sh install_v2.0.1.sh install_v2.0.1_core.sh preflight_v2.0.1.sh build.sh
./update.sh
```

`./update.sh` pulls the patch and copies the built app to `/Applications/Atlas.app`.
