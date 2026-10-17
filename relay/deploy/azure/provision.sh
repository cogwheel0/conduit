#!/bin/bash
# Creates the Azure resources the push relay runs on: a resource group, a small
# Ubuntu VM with a static address and DNS name, its firewall, and the Key Vault
# that holds the relay's keys. Run once with `az login` done; running it again
# leaves what exists alone, and never replaces the seal key.
#
#   relay/deploy/azure/provision.sh
#
# Then put the relay on the VM with deploy.sh, and its provider keys in the
# vault with upload-keys.sh. Override the names with CONDUIT_RELAY_* variables.
set -euo pipefail

rg=${CONDUIT_RELAY_RESOURCE_GROUP:-rg-conduit-push}
location=${CONDUIT_RELAY_LOCATION:-swedencentral}
dns_label=${CONDUIT_RELAY_DNS_LABEL:-conduit-push}
vault=${CONDUIT_RELAY_VAULT:-kv-conduit-push-01}
vm=${CONDUIT_RELAY_VM:-vm-conduit-push-relay}
size=${CONDUIT_RELAY_VM_SIZE:-Standard_B2pts_v2} # 2 Arm vCPUs, 1 GiB
ssh_key=${CONDUIT_RELAY_SSH_KEY:-$HOME/.ssh/conduit-push-relay_ed25519}
# SSH is open only to this range. The admin's ISP rotates its NAT address, so a
# single address doesn't stay valid; narrow or widen it with `az network nsg
# rule update ... -n allow-ssh-admin --source-address-prefixes <cidr>`.
ssh_from=${CONDUIT_RELAY_SSH_FROM:?set CONDUIT_RELAY_SSH_FROM to the CIDR SSH may come from}
tags=(project=conduit component=push-relay)

[ -f "$ssh_key" ] || ssh-keygen -q -t ed25519 -N "" -C "conduit push relay admin" -f "$ssh_key"

az group create -n "$rg" -l "$location" --tags "${tags[@]}" -o none

# Each resource is created only when missing, so a second run never rewrites
# one (recreating the VNet would drop its subnet's NSG for a moment).
exists() { "$@" -o none 2>/dev/null; }
has_role() { # principal role: on the vault
  [ -n "$(az role assignment list --assignee "$1" --role "$2" --scope "$vault_id" --query "[0].id" -o tsv 2>/dev/null)" ]
}
exists az network nsg show -g "$rg" -n nsg-conduit-push ||
  az network nsg create -g "$rg" -n nsg-conduit-push -l "$location" --tags "${tags[@]}" -o none
rule() { # name priority port source description
  exists az network nsg rule show -g "$rg" --nsg-name nsg-conduit-push -n "$1" ||
    az network nsg rule create -g "$rg" --nsg-name nsg-conduit-push -n "$1" --priority "$2" \
      --direction Inbound --access Allow --protocol Tcp --source-address-prefixes "$4" \
      --destination-port-ranges "$3" --description "$5" -o none
}
rule allow-ssh-admin 100 22 "$ssh_from" "SSH from the admin's ISP block; key-only"
rule allow-https 110 443 Internet "Relay over HTTPS (TCP)"
rule allow-http-acme 120 80 Internet "Let's Encrypt HTTP challenge and redirect to HTTPS"
exists az network vnet show -g "$rg" -n vnet-conduit-push ||
  az network vnet create -g "$rg" -n vnet-conduit-push -l "$location" --address-prefixes 10.42.0.0/24 \
    --subnet-name snet-relay --subnet-prefixes 10.42.0.0/27 --tags "${tags[@]}" -o none
az network vnet subnet update -g "$rg" --vnet-name vnet-conduit-push -n snet-relay \
  --network-security-group nsg-conduit-push -o none
exists az network public-ip show -g "$rg" -n pip-conduit-push ||
  az network public-ip create -g "$rg" -n pip-conduit-push -l "$location" --sku Standard \
    --allocation-method Static --version IPv4 --dns-name "$dns_label" --tags "${tags[@]}" -o none

exists az keyvault show -n "$vault" ||
  az keyvault create -g "$rg" -n "$vault" -l "$location" --enable-rbac-authorization true \
    --retention-days 90 --tags "${tags[@]}" -o none
vault_id=$(az keyvault show -n "$vault" --query id -o tsv)
me=$(az ad signed-in-user show --query id -o tsv)
has_role "$me" "Key Vault Secrets Officer" ||
  az role assignment create --assignee-object-id "$me" --assignee-principal-type User \
    --role "Key Vault Secrets Officer" --scope "$vault_id" -o none
until az keyvault secret list --vault-name "$vault" -o none 2>/dev/null; do sleep 10; done

# The seal key is made here and goes straight into the vault, unprinted. It is
# never replaced: a new key would break every endpoint already handed out
# (SELF_HOSTING.md, "Rotate the seal key").
if ! az keyvault secret show --vault-name "$vault" -n relay-seal-keys -o none 2>/dev/null; then
  seal=$(mktemp)
  trap 'rm -f "$seal"' EXIT
  (umask 077 && printf '1:%s' "$(openssl rand -base64 32)" >"$seal")
  az keyvault secret set --vault-name "$vault" -n relay-seal-keys --file "$seal" \
    --content-type "kid:base64 32-byte keys, comma-separated" -o none
  az keyvault secret set --vault-name "$vault" -n relay-seal-active-kid --value 1 -o none
fi

exists az vm show -g "$rg" -n "$vm" ||
  az vm create -g "$rg" -n "$vm" -l "$location" \
    --image Canonical:ubuntu-24_04-lts:server-arm64:latest --size "$size" \
    --admin-username conduit --ssh-key-values "$ssh_key.pub" --authentication-type ssh \
    --vnet-name vnet-conduit-push --subnet snet-relay --public-ip-address pip-conduit-push --nsg "" \
    --os-disk-name "osdisk-$vm" --os-disk-size-gb 30 --storage-sku StandardSSD_LRS \
    --os-disk-delete-option Delete --nic-delete-option Delete \
    --assign-identity "[system]" --tags "${tags[@]}" -o none
principal=$(az vm show -g "$rg" -n "$vm" --query identity.principalId -o tsv)
# Read-only: the VM can read the relay's keys and nothing else.
has_role "$principal" "Key Vault Secrets User" ||
  az role assignment create --assignee-object-id "$principal" --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" --scope "$vault_id" -o none
az vm boot-diagnostics enable -g "$rg" -n "$vm" -o none

az network public-ip show -g "$rg" -n pip-conduit-push --query "{address:ipAddress,host:dnsSettings.fqdn}" -o table
