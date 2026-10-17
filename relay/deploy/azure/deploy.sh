#!/bin/bash
# Builds the relay from this checkout's HEAD on the Azure VM and restarts it.
# Run from anywhere in the repository; the first run also sets the host up.
#
#   relay/deploy/azure/deploy.sh
#
# Settings default to the official deployment; override with CONDUIT_RELAY_*
# variables to deploy elsewhere.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

host=${CONDUIT_RELAY_HOST:-conduit-push.swedencentral.cloudapp.azure.com}
public_url=${CONDUIT_RELAY_PUBLIC_URL:-https://$host}
ssh_key=${CONDUIT_RELAY_SSH_KEY:-$HOME/.ssh/conduit-push-relay_ed25519}
vault=${CONDUIT_RELAY_VAULT:-kv-conduit-push-01}
team_id=${CONDUIT_RELAY_APNS_TEAM_ID:-X2662V5DT2}
apps=${CONDUIT_RELAY_APPS:-app.cogwheel.conduit,app.cogwheel.conduit.debug}

if ! git diff --quiet HEAD -- relay; then
  echo "deploy.sh: relay/ has uncommitted changes; commit them first, since only HEAD is deployed" >&2
  exit 1
fi
label=$(git rev-parse --short=12 HEAD)

remote() { ssh -i "$ssh_key" -o StrictHostKeyChecking=accept-new "conduit@$host" "$@"; }

echo "Deploying $label to $host"
remote 'sudo install -d -m 0755 /etc/conduit-push && sudo tee /etc/conduit-push/relay.conf >/dev/null' <<EOF
# Written by relay/deploy/azure/deploy.sh. Not secret: the keys come from the
# Key Vault below, read by /usr/local/libexec/conduit-push/fetch-secrets.
KEY_VAULT_NAME=$vault
RELAY_PUBLIC_URL=$public_url
RELAY_TRUST_FORWARDED_FOR=true
RUST_LOG=warn
APNS_TEAM_ID=$team_id
APNS_APPS=$apps
FCM_APPS=$apps
EOF
git archive --format=tar HEAD relay |
  remote 'sudo rm -rf /opt/conduit-push/src && sudo install -d -m 0755 /opt/conduit-push/src && sudo tar -x -C /opt/conduit-push/src'
remote sudo bash /opt/conduit-push/src/relay/deploy/host/install.sh "$label"
