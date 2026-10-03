#!/bin/bash
# Render the 1024 px master and build Assets/AppIcon.icns with every macOS size.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p Assets
swift Scripts/make-icon.swift Assets/AppIcon-1024.png
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s Assets/AppIcon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d Assets/AppIcon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Assets/AppIcon.icns
echo "wrote Assets/AppIcon.icns"
