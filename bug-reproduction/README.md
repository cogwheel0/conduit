# Conduit Proxy Auth Bug Reproduction

Reproduces a bug in `proxy_auth_page.dart` where `_cookiesCaptured` is set to
`true` on the first landing on the target server, before Open-WebUI's OIDC flow
has completed and set a usable JWT token. All subsequent page loads — including
the one where Open-WebUI finally sets the `token` cookie — are silently skipped.

## Stack

| Service    | URL                           | Purpose                                      |
|------------|-------------------------------|----------------------------------------------|
| Caddy      | —                             | Reverse proxy with `forward_auth` to Authelia |
| Authelia   | https://auth.localtest.me     | OIDC provider + forwardAuth gate              |
| Open-WebUI | https://chat.localtest.me     | Protected app, OIDC configured via Authelia   |

`localtest.me` is a public DNS wildcard that resolves to `127.0.0.1` — no
`/etc/hosts` changes needed.

## Prerequisites

- Docker + Docker Compose
- Conduit installed on a mobile device on the same network as your machine, OR
  using a simulator/emulator with network access to your machine's IP

## Setup

```bash
git clone <this-repo>
cd conduit-bug-repro
chmod +x setup.sh
./setup.sh
```

`setup.sh` will:
1. Generate an RSA keypair for Authelia's OIDC JWT signing
2. Hash the OIDC client secret and test user password using Authelia's own tooling
3. Start the full stack with `docker compose up -d`

**Trust the Caddy root CA** (required for Conduit's WebView and for browser testing):

```bash
# Export Caddy's self-signed root certificate
docker cp conduit-repro-caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
```

- **iOS**: AirDrop or email `caddy-root.crt` to your device → Settings → General →
  VPN & Device Management → install, then Settings → General → About →
  Certificate Trust Settings → enable full trust
- **Android**: Settings → Security → Install from storage → select `caddy-root.crt`
- **Browser**: Import `caddy-root.crt` into your browser's trusted certificates,
  or just accept the warning when visiting `https://chat.localtest.me`

**If testing on a physical device**, replace `localtest.me` with your machine's
LAN IP in `docker-compose.yml`, `Caddyfile`, and `authelia/configuration.yml`.
`localtest.me` only resolves to `127.0.0.1` which isn't reachable from another device.

## Test Credentials

| Field    | Value        |
|----------|--------------|
| Username | `testuser`   |
| Password | `testpassword` |

## Reproducing the Bug

1. Open Conduit on your device
2. Add a new server: `https://chat.localtest.me`
3. Conduit detects the Authelia proxy (401 from `/health`) and opens the proxy auth WebView
4. Log in with `testuser` / `testpassword`
5. Authelia redirects back to `https://chat.localtest.me/auth`
6. Open-WebUI shows the "Continue with Local Authelia Login" button

**Bug:** Conduit has already set `_cookiesCaptured = true` at step 5 (first landing
on the target host). When you click the SSO button in step 6, Open-WebUI initiates
its own OIDC round-trip back to Authelia, which completes and sets the `token` cookie
— but `_onPageFinished` is now gated by `_cookiesCaptured = true` and never runs
`_tryCaptureJwtToken()` again. Conduit returns `jwtToken: null`, fires
`GET /api/v1/auths/` with no authentication, and displays:

> **SSO auth failed exception: invalid token or insufficient permissions**

## Confirming the Root Cause

The bug is in `lib/features/auth/views/proxy_auth_page.dart`:

```dart
// _onPageFinished — line ~166
if (_cookiesCaptured) return;  // ← blocks ALL future capture attempts
...
if (uri.host == serverUri.host) {
  _isOnTargetServer = true;
  await _checkIfOpenWebUI();   // → calls _captureProxyCookies() unconditionally
}

// _captureProxyCookies — line ~210
_cookiesCaptured = true;       // ← set BEFORE checking if token exists
...
String? jwtToken = await _tryCaptureJwtToken();  // returns null — token not set yet
context.pop(ProxyAuthResult.success(cookies: cookies, jwtToken: jwtToken));
// pops with jwtToken: null
```

The fix: only set `_cookiesCaptured = true` after `_tryCaptureJwtToken()` returns
a valid token. If no token is found, keep monitoring subsequent page loads.

## Verifying the Workaround

To confirm the workaround (server-side `WEBUI_AUTH_TRUSTED_EMAIL_HEADER`), add the
following to the `openwebui` environment in `docker-compose.yml`, then restart:

```yaml
WEBUI_AUTH_TRUSTED_EMAIL_HEADER: Remote-Email
WEBUI_AUTH_TRUSTED_NAME_HEADER: Remote-Name
```

With this set, Open-WebUI auto-signs in the user on first page load using the
`Remote-Email` header injected by Authelia's forwardAuth, setting the `token` cookie
before `_onPageFinished` fires. Conduit captures the token on the first attempt
and authentication succeeds.

## Teardown

```bash
docker compose down -v   # -v removes volumes (clears all state)
```
