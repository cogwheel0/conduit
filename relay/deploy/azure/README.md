# The push relay on Azure

The official relay runs on one small Azure VM. It's the setup
[SELF_HOSTING.md](../../../docs/push/SELF_HOSTING.md) describes: the relay's
Docker image behind Caddy, with no access logs. Its keys are kept in Azure Key
Vault.

| | |
|---|---|
| Address | `https://conduit-push.swedencentral.cloudapp.azure.com` |
| Resource group | `rg-conduit-push` (Sweden Central) |
| VM | `vm-conduit-push-relay`: `Standard_B2pts_v2` (2 Arm vCPUs, 1 GiB), Ubuntu 24.04 |
| Key Vault | `kv-conduit-push-01` |
| SSH | `ssh -i ~/.ssh/conduit-push-relay_ed25519 conduit@conduit-push.swedencentral.cloudapp.azure.com` |

## How it fits together

- **Firewall:** the subnet allows 443 and 80 (Let's Encrypt's challenge and the redirect to
  HTTPS) from anywhere, and SSH only from the admin's ISP block, by key only.
  NSG flow logs are off; they would record the address of every server and
  device that connects.
- **Keys:** the relay's seal key and its APNs and FCM keys live in the vault. The
  VM's managed identity can read them, and nothing else can. Before each start,
  `fetch-secrets` reads them into `/run/conduit-push`, which is in memory and
  removed when the relay stops. The keys never reach the VM's disk.
- **Relay container:** the relay runs as `conduit-push-relay.service`, a read-only
  container with no capabilities, published on `127.0.0.1:8080` only.
  - Caddy terminates TLS for it, and its upstream keep-alive is below the relay's
    idle close.
  - Docker keeps no copy of the relay's output. The relay logs nothing about
    requests.
- **Updates:** Ubuntu, Docker and Caddy update themselves. When an update needs a
  reboot, the VM reboots at 03:40 UTC, and pushes sent during that minute fail.
- **Cost:** about $13 a month in total: the VM about $6.30, the static address
  about $3.65, the 30 GB disk about $2.40, and the vault a few cents.

## Tasks

**Add or replace the APNs and FCM keys.** The files go straight to the vault:

```bash
relay/deploy/azure/upload-keys.sh --apns-key-id ABC123DEFG --apns-p8 AuthKey_ABC123DEFG.p8
relay/deploy/azure/upload-keys.sh --fcm-service-account conduit-fcm.json
```

Until the vault has keys for at least one of them, the relay waits. It starts on its
own within a minute of them being added.

**Deploy a new relay version.** This deploys the checkout's committed `relay/`:

```bash
relay/deploy/azure/deploy.sh
```

It builds the image on the VM, keeps the previous one, and restarts the relay.
To roll back, run `docker image ls conduit-push-relay` on the VM to find the
previous label, then:

```bash
sudo docker tag conduit-push-relay:<label> conduit-push-relay:current
sudo systemctl restart conduit-push-relay
```

**Allow SSH from another network:**

```bash
az network nsg rule update -g rg-conduit-push --nsg-name nsg-conduit-push \
  -n allow-ssh-admin --source-address-prefixes <your-cidr>
```

Without SSH, `az vm run-command invoke -g rg-conduit-push -n vm-conduit-push-relay
--command-id RunShellScript --scripts '...'` still reaches the VM, and so does
the serial console in the portal.

**Look at the relay:**

```bash
sudo systemctl status conduit-push-relay
sudo journalctl -u conduit-push-relay -n 50
curl https://conduit-push.swedencentral.cloudapp.azure.com/v1/info
```

**Rebuild from nothing.** Run `provision.sh` (resources and the seal key), then
`deploy.sh` and `upload-keys.sh`. The seal key is the one thing that can't be
remade: a new one breaks every endpoint handed out, so phones receive nothing
until they open Conduit again. It stays in the vault. Deleting the vault keeps
it recoverable for 90 days.

**Use another hostname, such as `push.cogwheel.app`.** Point a CNAME at
`conduit-push.swedencentral.cloudapp.azure.com`, then deploy with
`CONDUIT_RELAY_PUBLIC_URL=https://push.cogwheel.app`. Then change the app's
built-in relay address (`kConduitPushRelayUrl`) to match. Every endpoint carries
the address it was made with, so do this before release, or keep serving the
old name as well.
