#!/usr/bin/env bash
# Builds MacNowPlaying.app and installs it to /Applications.
# After this: launch via Spotlight ("MacNowPlaying"), `open -a MacNowPlaying`,
# or add it as a Login Item (System Settings > General > Login Items) to auto-start.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

DEST="/Applications/MacNowPlaying.app"
rm -rf "$DEST"
cp -R MacNowPlaying.app "$DEST"

echo "Installed -> $DEST"
echo "Launch it with:  open -a MacNowPlaying   (or Spotlight)"
