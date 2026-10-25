#!/usr/bin/env bash
set -euo pipefail

# Download official public OME (Open Microscopy Environment) sample CZI file for validation.
# Source: Image Data Resource (IDR0011) / downloads.openmicroscopy.org

FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/fixtures"
mkdir -p "$FIXTURES_DIR"

OME_CZI_URL="https://downloads.openmicroscopy.org/images/Zeiss-CZI/idr0011/Plate1-Blue-A_TS-Stinger/Plate1-Blue-A-02-Scene-1-P2-E1-01.czi"
TARGET="$FIXTURES_DIR/Plate1-Blue-A-02-Scene-1-P2-E1-01.czi"

if [ ! -f "$TARGET" ]; then
    echo "Downloading public OME CZI fixture (43 MB)..."
    curl -L -f -o "$TARGET" "$OME_CZI_URL"
    echo "Saved fixture to $TARGET"
else
    echo "Fixture already exists at $TARGET"
fi
