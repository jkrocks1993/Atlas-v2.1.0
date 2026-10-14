# ATLAS 2.1.5 (build 19)

- Arrow keys move through tiles left, right, up, and down. Preview does not clear checks.
- Select Duplicates stays selected while you preview.
- ETA follows the slow comparison pass, not the fast survey.
- A finished scan no longer blanks the result list.
- During a scan, Delete is enabled only for inferior duplicates of a finished tab. BEST stays so later tabs can still match it. After the scan, every checked file can be deleted.

```bash
cd ~/Downloads/Atlas-v2.1.0
git fetch origin
git reset --hard origin/main
./update.sh
```
