#!/bin/bash
# Puts the relay's APNs and FCM keys in its Key Vault, then restarts it so it
# uses them at once. The files go straight from this machine to the vault;
# nothing is printed.
#
#   relay/deploy/azure/upload-keys.sh --apns-key-id ABC123DEFG --apns-p8 AuthKey_ABC123DEFG.p8
#   relay/deploy/azure/upload-keys.sh --fcm-service-account conduit-fcm.json
#
# Either provider can be added on its own, and both at once. Needs `az login`
# with the Key Vault Secrets Officer role on the vault.
set -euo pipefail

vault=${CONDUIT_RELAY_VAULT:-kv-conduit-push-01}
host=${CONDUIT_RELAY_HOST:-conduit-push.swedencentral.cloudapp.azure.com}
ssh_key=${CONDUIT_RELAY_SSH_KEY:-$HOME/.ssh/conduit-push-relay_ed25519}
apns_key_id='' apns_p8='' fcm_json=''

while [ $# -gt 0 ]; do
  case "$1" in
    --apns-key-id) apns_key_id=${2:?}; shift 2 ;;
    --apns-p8) apns_p8=${2:?}; shift 2 ;;
    --fcm-service-account) fcm_json=${2:?}; shift 2 ;;
    *) sed -n '2,12p' "$0" >&2; exit 2 ;;
  esac
done

if [ -n "$apns_key_id$apns_p8" ]; then
  [ -n "$apns_key_id" ] && [ -n "$apns_p8" ] || { echo "APNs needs both --apns-key-id and --apns-p8" >&2; exit 2; }
  [[ "$apns_key_id" =~ ^[A-Z0-9]{10}$ ]] || { echo "--apns-key-id should be the key's 10-character Key ID" >&2; exit 2; }
  grep -q -- '-----BEGIN PRIVATE KEY-----' "$apns_p8" || { echo "$apns_p8 doesn't look like an APNs .p8 key" >&2; exit 2; }
fi
if [ -n "$fcm_json" ]; then
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("type")=="service_account" and d.get("private_key") and d.get("project_id")' "$fcm_json" 2>/dev/null ||
    { echo "$fcm_json doesn't look like a Google service-account key" >&2; exit 2; }
fi
[ -n "$apns_key_id$fcm_json" ] || { sed -n '2,12p' "$0" >&2; exit 2; }

if [ -n "$apns_key_id" ]; then
  az keyvault secret set --vault-name "$vault" --name apns-key-id --value "$apns_key_id" -o none
  az keyvault secret set --vault-name "$vault" --name apns-p8 --file "$apns_p8" --content-type application/x-pem-file -o none
  echo "APNs key $apns_key_id stored in $vault"
fi
if [ -n "$fcm_json" ]; then
  az keyvault secret set --vault-name "$vault" --name fcm-service-account --file "$fcm_json" --content-type application/json -o none
  echo "FCM service account stored in $vault"
fi

if ssh -i "$ssh_key" -o ConnectTimeout=15 "conduit@$host" sudo systemctl restart conduit-push-relay 2>/dev/null; then
  sleep 5
  curl -fsS "https://$host/v1/info" && echo
else
  echo "Couldn't reach the VM over SSH; the relay picks the keys up by itself within a minute."
fi
