#!/usr/bin/env bash
# setup.sh — one-time setup for Conduit proxy auth bug reproduction environment
# Generates the RSA key Authelia needs for OIDC JWT signing, then hashes
# the OIDC client secret so Authelia can validate it.
set -euo pipefail

echo "==> Generating RSA private key for Authelia OIDC JWT signing..."
# Use Docker to run Authelia's built-in crypto command — no local dependencies needed
docker run --rm \
  -v "$(pwd)/authelia:/config" \
  authelia/authelia:latest \
  authelia crypto pair rsa generate \
    --bits 2048 \
    --file.private-key /config/private.pem \
    --file.public-key /config/public.pem

echo "==> Generating hashed OIDC client secret for Authelia..."
# Hash the plaintext secret "insecure-client-secret-for-local-testing"
# and inject it into configuration.yml
HASHED_SECRET=$(docker run --rm authelia/authelia:latest \
  authelia crypto hash generate pbkdf2 \
    --variant sha512 \
    --password "insecure-client-secret-for-local-testing" \
  | grep "Digest:" | awk '{print $2}')

# Replace the placeholder in configuration.yml
sed -i.bak "s|client_secret: 'REPLACE_WITH_HASHED_SECRET'|client_secret: '${HASHED_SECRET}'|" \
  authelia/configuration.yml
rm -f authelia/configuration.yml.bak

echo "==> Generating hashed password for testuser (password: testpassword)..."
HASHED_PW=$(docker run --rm authelia/authelia:latest \
  authelia crypto hash generate argon2 \
    --password "testpassword" \
  | grep "Digest:" | awk '{print $2}')

sed -i.bak "s|password: 'REPLACE_WITH_HASHED_PASSWORD'|password: '${HASHED_PW}'|" \
  authelia/users_database.yml
rm -f authelia/users_database.yml.bak

echo ""
echo "==> Setup complete. Starting stack..."
echo ""
echo "    Authelia:   https://auth.localtest.me"
echo "    Open-WebUI: https://chat.localtest.me"
echo ""
echo "    Test credentials:  testuser / testpassword"
echo ""
echo "    NOTE: Caddy uses a self-signed CA. You will need to either:"
echo "      a) Accept the certificate warning in your browser/Conduit, OR"
echo "      b) Export Caddy's root CA and install it as trusted on your device:"
echo "         docker cp conduit-repro-caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt"
echo ""
docker compose up -d
echo ""
echo "==> Stack is up. Check logs with: docker compose logs -f"
