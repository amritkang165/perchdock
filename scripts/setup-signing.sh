#!/usr/bin/env bash
# One-time setup: creates a self-signed "PerchDock Local Signing" identity in a
# dedicated keychain, so every build has the same signature and macOS keeps
# PerchDock's Accessibility permission across rebuilds.
#
# The dedicated keychain has its own known password, so codesign never prompts
# for (or depends on) your login keychain password.
set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/perchdock-signing.keychain-db"
KEYCHAIN_PW="perchdock-local"
IDENTITY="PerchDock Local Signing"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "Signing identity already set up."
  exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Create the keychain (no auto-lock) and add it to the user search list.
security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN" 2>/dev/null || true
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
EXISTING=$(security list-keychains -d user | tr -d '"' | xargs)
security list-keychains -d user -s "$KEYCHAIN" $EXISTING

# Self-signed certificate restricted to code signing.
cat > "$WORK_DIR/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$IDENTITY
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" -config "$WORK_DIR/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -name "$IDENTITY" \
  -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
  -out "$WORK_DIR/id.p12" -passout pass:temp 2>/dev/null

security import "$WORK_DIR/id.p12" -k "$KEYCHAIN" -P temp -T /usr/bin/codesign

# Let Apple's signing tools use the key without a GUI prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null

echo "Created signing identity '$IDENTITY' in $KEYCHAIN"
