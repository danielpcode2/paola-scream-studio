#!/usr/bin/env bash
# Creates a local self-signed code-signing identity ("Mi Recorder Local Signing") in your login
# keychain. With it, every rebuild keeps the same signature, so macOS keeps the Screen Recording,
# Camera and Microphone permissions instead of asking again after each build.
#
# Only touches your login keychain. macOS will ask for your password to trust the certificate
# for code signing. To undo: Keychain Access › login › delete "Mi Recorder Local Signing".
set -euo pipefail

NAME="Mi Recorder Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl # LibreSSL: produces PKCS#12 files that `security import` accepts

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "$NAME"; then
    echo "La identidad \"$NAME\" ya existe."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout pass:mirecorder -name "$NAME"

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P mirecorder -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "Listo: \"$NAME\" creada. Ahora ejecuta ./scripts/build-app.sh"
