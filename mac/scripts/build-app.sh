#!/usr/bin/env bash
# Builds build/Mi Recorder.app (release).
#
# Signing: uses the "Mi Recorder Local Signing" identity when it exists (see
# scripts/create-signing-cert.sh). A stable identity keeps macOS privacy permissions across
# rebuilds. Without it the app is signed ad hoc, and macOS ties permissions to that exact
# build, so it asks again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Mi Recorder Local Signing"
BUNDLE_ID="local.mirecorder.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MiRecorder"
APP="build/Mi Recorder.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MiRecorder"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
    # First build with the stable identity: drop permission entries made for older ad hoc builds.
    MARKER="build/.stable-signing"
    if [[ ! -f "$MARKER" ]]; then
        for service in ScreenCapture Camera Microphone; do
            tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1 || true
        done
        touch "$MARKER"
        echo "Permisos antiguos de Mi Recorder restablecidos: concédelos una última vez al abrir la app."
    fi
else
    codesign --force --sign - "$APP"
    echo "Aviso: firma ad hoc. macOS volverá a pedir permisos tras cada compilación."
    echo "       Ejecuta ./scripts/create-signing-cert.sh una vez para evitarlo."
fi

echo "Listo: $APP"
echo "Abrir con: open \"$APP\""
