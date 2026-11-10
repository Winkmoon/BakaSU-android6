#!/bin/sh
# Print the Kbuild arguments needed to trust a manager APK's signing key.
#
# The kernel checks the DER-encoded signing certificate inside the APK v2
# block. A v1+v2 APK carries the same certificate in META-INF/*.RSA, so use
# that copy to calculate the size and SHA-256 expected by apk_sign.c.
set -eu

APK=${1:-}
if [ -z "$APK" ] || [ ! -f "$APK" ]; then
    echo "Usage: $0 <manager.apk>" >&2
    exit 2
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

CERT_ENTRY=$(unzip -Z1 "$APK" 2>/dev/null |
    grep -E '^META-INF/.*\.(RSA|DSA|EC)$' |
    head -n 1 || true)
if [ -z "$CERT_ENTRY" ]; then
    echo "No v1 certificate found in $APK." >&2
    echo "Build the manager with v1+v2 signing (required for Android 6)." >&2
    exit 1
fi

unzip -p "$APK" "$CERT_ENTRY" > "$TMP_DIR/cert.p7b"
if ! openssl pkcs7 -inform DER -in "$TMP_DIR/cert.p7b" \
        -print_certs -out "$TMP_DIR/cert.pem" 2>/dev/null; then
    echo "Failed to decode $CERT_ENTRY with openssl." >&2
    exit 1
fi

openssl x509 -in "$TMP_DIR/cert.pem" -outform DER -out "$TMP_DIR/cert.der"
SIZE=$(wc -c < "$TMP_DIR/cert.der" | tr -d ' ')
HASH=$(sha256sum "$TMP_DIR/cert.der" | awk '{print $1}')

printf 'KSU_EXPECTED_SIZE=0x%x\n' "$SIZE"
printf 'KSU_EXPECTED_HASH=%s\n' "$HASH"
