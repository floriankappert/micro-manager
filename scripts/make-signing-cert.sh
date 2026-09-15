#!/usr/bin/env bash
# Create a local, self-signed code-signing certificate for bundle.sh.
#
# Why: without an identity, bundle.sh signs ad-hoc, and an ad-hoc signature is
# keyed to the hash of the binary. macOS ties the Input Monitoring grant to the
# signature, so every rebuild silently invalidates the grant - the toggle still
# reads "On" while IOHIDDeviceOpen fails with kIOReturnNotPermitted. A
# certificate, even a self-signed one, gives the app a stable identity and the
# grant sticks.
#
# Run once, in a terminal of your own login session (it touches the login
# keychain and asks for your password, twice: once to trust the certificate
# for your account, once with sudo to trust it system-wide):
#
#     ./scripts/make-signing-cert.sh
#
# bundle.sh picks the certificate up by name from then on.
#
# The system-wide trust is not optional. The Input Monitoring check runs in
# the root tccd, which validates the app's signature before honouring a grant
# and only consults the admin trust domain. A certificate trusted just in the
# login keychain leaves the app "denied" while the toggle reads "On".

set -euo pipefail

NAME="MicroManager Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

generate() {
    cat > "$TMP/ext.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
CNF

    echo "==> generating certificate"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" 2>/dev/null
    openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/identity.p12" -passout pass:local -name "$NAME"

    echo "==> importing into the login keychain"
    # -T lets codesign use the key without asking on every build.
    security import "$TMP/identity.p12" -f pkcs12 -k "$KEYCHAIN" -P local \
        -T /usr/bin/codesign -T /usr/bin/security
}

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "==> \"$NAME\" is already in the login keychain; refreshing trust only"
    security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$TMP/cert.pem"
else
    generate
fi

echo "==> trusting it for your account (macOS asks for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "==> trusting it system-wide, for tccd (sudo asks for your password)"
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
    -k /Library/Keychains/System.keychain "$TMP/cert.pem"

echo
security find-identity -v -p codesigning | grep "$NAME" \
    && echo "Done. Rebuild with ./scripts/bundle.sh --install, grant Input Monitoring once, and it stays granted."
