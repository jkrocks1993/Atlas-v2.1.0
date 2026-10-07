# ATLAS 2.1.3 (build 17)

Patch. Not a new application.

- Press and drag across files with the trackpad or the mouse.
- The blue rectangle selects every file it touches, in the list and in tiles.
- Hold Command while dragging to add to the current selection.
- Two-finger scrolling is unchanged.

```bash
cd ~/Downloads/Atlas-v2.1.0
git fetch origin
git reset --hard origin/main
chmod +x update.sh install_v2.0.1.sh install_v2.0.1_core.sh preflight_v2.0.1.sh build.sh
./update.sh
```
