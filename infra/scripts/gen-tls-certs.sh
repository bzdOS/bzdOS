#!/bin/sh
[ -r "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}" ] && . "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}"
# Генерация mTLS сертификатов для bsdOS Zenoh stream
# CA → server cert (VM) + client cert (Mac)
set -eu

CERTS_DIR="${CERTS_DIR:-$(dirname "$0")/../../certs}"
# Server public IP for the cert SAN. Default = current deployment host;
# override for a different host: BSDOS_SERVER_IP=1.2.3.4 make ...
BSDOS_SERVER_IP="${BSDOS_SERVER_IP:-${BSDOS_DEV_IP:?set BSDOS_DEV_IP in /etc/bsdos/hosts.env}}"
mkdir -p "$CERTS_DIR"

echo "=== bsdOS TLS cert generation ==="
echo "Output: $CERTS_DIR"

# 1. CA key + cert (самоподписанный, 10 лет)
echo "Generating CA key..."
openssl genrsa -out "$CERTS_DIR/ca.key" 4096 2>/dev/null

echo "Generating CA certificate..."
openssl req -new -x509 -days 3650 -key "$CERTS_DIR/ca.key" \
    -out "$CERTS_DIR/ca.pem" \
    -subj "/CN=bsdOS-CA/O=bsdOS/C=XX"

# 2. Server cert (для VM bsdos-core)
echo "Generating server key..."
openssl genrsa -out "$CERTS_DIR/server.key" 2048 2>/dev/null

echo "Generating server CSR..."
openssl req -new -key "$CERTS_DIR/server.key" \
    -out "$CERTS_DIR/server.csr" \
    -subj "/CN=bsdos-server/O=bsdOS/C=XX"

echo "Signing server certificate (SAN includes all valid IPs; server IP=$BSDOS_SERVER_IP)..."
# Clean up the temp SAN config even if openssl fails under set -e (it used to leak
# on the failure path because the rm came after the openssl call).
trap 'rm -f /tmp/bsdos-server-ext.cnf' EXIT
cat > /tmp/bsdos-server-ext.cnf << EXTEOF
[v3_req]
subjectAltName = @alt_names
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment

[alt_names]
DNS.1 = localhost
DNS.2 = bsdos-server
IP.1 = 127.0.0.1
IP.2 = 0.0.0.0
IP.3 = $BSDOS_SERVER_IP
EXTEOF
openssl x509 -req -days 3650 \
    -in "$CERTS_DIR/server.csr" \
    -CA "$CERTS_DIR/ca.pem" \
    -CAkey "$CERTS_DIR/ca.key" \
    -CAcreateserial \
    -extensions v3_req \
    -extfile /tmp/bsdos-server-ext.cnf \
    -out "$CERTS_DIR/server.pem" 2>/dev/null
rm -f /tmp/bsdos-server-ext.cnf

# 3. Client cert (для Mac)
echo "Generating client key..."
openssl genrsa -out "$CERTS_DIR/client.key" 2048 2>/dev/null

echo "Generating client CSR..."
openssl req -new -key "$CERTS_DIR/client.key" \
    -out "$CERTS_DIR/client.csr" \
    -subj "/CN=bsdos-client/O=bsdOS/C=XX"

echo "Signing client certificate..."
openssl x509 -req -days 3650 \
    -in "$CERTS_DIR/client.csr" \
    -CA "$CERTS_DIR/ca.pem" \
    -CAkey "$CERTS_DIR/ca.key" \
    -CAcreateserial \
    -out "$CERTS_DIR/client.pem" 2>/dev/null

# 4. Очистить CSR
rm -f "$CERTS_DIR"/*.csr "$CERTS_DIR"/*.srl

echo ""
echo "Generated certs in $CERTS_DIR:"
ls -la "$CERTS_DIR/"
echo ""
echo "Next steps:"
echo "  1. Deploy to VM: make vm-deploy-certs"
echo "  2. Copy to Mac: scp $CERTS_DIR/ca.pem $CERTS_DIR/client.{pem,key} user@mac:/etc/bsdos/"
