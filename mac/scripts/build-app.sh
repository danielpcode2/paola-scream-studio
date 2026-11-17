#!/usr/bin/env bash
# Builds build/Paola Screen Studio.app (release).
#
# Signing: uses the "Paola Screen Studio Local Signing" identity when it exists (see
# scripts/create-signing-cert.sh). A stable identity keeps macOS privacy permissions across
# rebuilds. Without it the app is signed ad hoc, and macOS ties permissions to that exact
# build, so it asks again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

# Bundle id kept from the first version so granted permissions and settings carry over.
BUNDLE_ID="local.mirecorder.app"
IDENTITY="Paola Screen Studio Local Signing"
# Identity created by earlier versions of create-signing-cert.sh.
if ! security find-identity -p codesigning | grep -q "$IDENTITY" \
    && security find-identity -p codesigning | grep -q "Mi Recorder Local Signing"; then
    IDENTITY="Mi Recorder Local Signing"
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PaolaScreenStudio"
APP="build/Paola Screen Studio.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PaolaScreenStudio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
    echo "Aviso: firma ad hoc. macOS volverá a pedir permisos tras cada compilación."
    echo "       Ejecuta ./scripts/create-signing-cert.sh una vez para evitarlo."
fi

echo "Listo: $APP"
echo "Abrir con: open \"$APP\""
