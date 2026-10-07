#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
if [[ -d .git ]]; then
  git pull --ff-only
fi
exec "$ROOT/install_v2.0.1.sh"
