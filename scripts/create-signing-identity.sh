#!/bin/zsh
# Creates a self-signed "Offrecord Local" code signing identity in the login keychain,
# so macOS keeps Microphone / Screen Recording permissions across rebuilds.
# Remove later with: security delete-identity -c "Offrecord Local"
set -euo pipefail
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
cat > "$DIR/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Offrecord Local
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -days 3650 -config "$DIR/cert.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -out "$DIR/id.p12" -passout pass:offrecord -name "Offrecord Local" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -out "$DIR/id.p12" -passout pass:offrecord -name "Offrecord Local"
security import "$DIR/id.p12" -k ~/Library/Keychains/login.keychain-db -P offrecord -T /usr/bin/codesign
echo "Created identity 'Offrecord Local'. Now run: ./scripts/build-app.sh --install"
