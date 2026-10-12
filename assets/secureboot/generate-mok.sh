#!/bin/bash
# ==============================================================================
# Pulsar OS - Regenera el par de claves MOK de Secure Boot
# ==============================================================================
# English: regenerates the Pulsar OS Secure Boot MOK keypair. The private key is
#          NOT committed (see ISO/.gitignore). Generate it on every build host
#          that signs ISOs, or reuse the same key so users enroll one MOK once.
# Español: regenera el par de claves MOK de Secure Boot. La clave privada NO se
#          commitea (ver ISO/.gitignore). Genérala en cada host que firme ISOs,
#          o reutiliza la misma clave para que el usuario enrolle una sola MOK.
# Usage / Uso:  ./generate-mok.sh ["CN"]
# ==============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CN="${1:-Pulsar OS Secure Boot MOK}"
DAYS="${MOK_DAYS:-3650}"

echo "🔑 Generando MOK (CN=$CN, $DAYS días)..."
openssl req -new -x509 -newkey rsa:2048 -nodes \
    -keyout "$DIR/pulsar-mok.key" \
    -out "$DIR/pulsar-mok.crt" \
    -days "$DAYS" \
    -subj "/O=Pulsar OS/CN=$CN"

# .cer (DER) es el formato que MokManager acepta para "Enroll key from disk".
# .crt (PEM) es el que usa sbsign para firmar binarios.
openssl x509 -in "$DIR/pulsar-mok.crt" -out "$DIR/pulsar-mok.cer" -outform DER

chmod 600 "$DIR/pulsar-mok.key"
echo "✅ MOK generada en $DIR: pulsar-mok.{key,crt,cer}"
echo "   - pulsar-mok.key: privada, custódiala (600) y nunca la commitees"
echo "   - pulsar-mok.crt: pública PEM, la usan sbsign / refind-install"
echo "   - pulsar-mok.cer: pública DER, la enrola el usuario con MokManager"