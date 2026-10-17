#!/bin/bash
# Sets up or updates the push relay on an Ubuntu 24.04 host, as root:
#
#   install.sh <image-label>
#
# Expects the repository's relay/ directory at /opt/conduit-push/src/relay and
# the relay's settings at /etc/conduit-push/relay.conf (relay/deploy/azure/
# deploy.sh puts both there). Safe to run again: each step only changes what
# isn't already in place. Builds the relay image on the host, then restarts the
# relay on it.
set -euo pipefail

label=${1:?usage: install.sh <image-label>}
src=/opt/conduit-push/src/relay
host_files="$src/deploy/host"
conf=/etc/conduit-push/relay.conf
export DEBIAN_FRONTEND=noninteractive

[ -f "$conf" ] || { echo "install.sh: $conf is missing" >&2; exit 1; }
public_url=$(sed -n 's/^RELAY_PUBLIC_URL=//p' "$conf")
public_host=${public_url#https://}
public_host=${public_host%%/*}
[ -n "$public_host" ] || { echo "install.sh: RELAY_PUBLIC_URL is not set in $conf" >&2; exit 1; }

step() { printf '\n== %s\n' "$*"; }

step "Swap (building the image needs more than the VM's memory)"
if ! swapon --show=NAME --noheadings | grep -q /swapfile; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi
sysctl -q vm.swappiness=10
echo 'vm.swappiness=10' >/etc/sysctl.d/90-conduit-swap.conf

step "Packages"
install -d -m 0755 /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi
cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable
EOF
if [ ! -f /etc/apt/keyrings/caddy-stable.gpg ]; then
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /etc/apt/keyrings/caddy-stable.gpg
  chmod a+r /etc/apt/keyrings/caddy-stable.gpg
fi
cat >/etc/apt/sources.list.d/caddy-stable.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/caddy-stable.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main
EOF
apt-get update -qq
apt-get install -y -qq jq curl ca-certificates docker-ce docker-ce-cli containerd.io docker-buildx-plugin caddy >/dev/null

step "Automatic updates (including Docker and Caddy), with a reboot when one needs it"
cat >/etc/apt/apt.conf.d/52conduit-unattended-upgrades <<'EOF'
// Written by relay/deploy/host/install.sh.
Unattended-Upgrade::Origins-Pattern {
	"origin=Docker,archive=${distro_codename}"; // its Release file has no codename
	"origin=cloudsmith/caddy/stable";
};
// The relay keeps nothing on disk, so a reboot only drops pushes sent during it.
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:40";
EOF
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

step "Relay service and TLS proxy"
install -d -m 0755 /usr/local/libexec/conduit-push
install -m 0755 "$host_files/fetch-secrets" /usr/local/libexec/conduit-push/fetch-secrets
install -m 0644 "$host_files/conduit-push-relay.service" /etc/systemd/system/conduit-push-relay.service
sed "s/@HOST@/$public_host/" "$host_files/Caddyfile.template" >/etc/caddy/Caddyfile.new
caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile.new >/dev/null 2>&1 ||
  { caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile.new; exit 1; }
mv /etc/caddy/Caddyfile.new /etc/caddy/Caddyfile
systemctl daemon-reload
systemctl enable --quiet docker caddy conduit-push-relay
systemctl reload-or-restart caddy

step "Image conduit-push-relay:$label"
docker build --quiet --tag "conduit-push-relay:$label" "$src" >/dev/null
docker tag "conduit-push-relay:$label" conduit-push-relay:current
# Keep the running image and the one before it, so a bad build can be rolled
# back with `docker tag conduit-push-relay:<label> conduit-push-relay:current`.
docker image ls conduit-push-relay --format '{{.Tag}}' |
  { grep -v -x -e current -e "$label" || true; } | tail -n +2 |
  xargs -r -I{} docker image rm "conduit-push-relay:{}" >/dev/null
docker image prune --force >/dev/null
docker builder prune --force --filter until=168h >/dev/null

step "Restart"
# Fails while the vault has no provider keys yet; the loop below tells that
# apart from a real failure.
systemctl restart conduit-push-relay || true
for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    echo "relay is up: https://$public_host/v1/info"
    exit 0
  fi
  if journalctl -u conduit-push-relay --since -2min --no-pager -q | grep -q 'waiting for APNs'; then
    echo "relay is installed and waiting for its APNs or FCM keys in Key Vault;"
    echo "it starts on its own within a minute of them being added"
    exit 0
  fi
  sleep 2
done
echo "relay did not come up; see: journalctl -u conduit-push-relay" >&2
exit 1
