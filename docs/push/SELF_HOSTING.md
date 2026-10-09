# Self-hosting the push relay

The relay turns the Web Push requests your Open WebUI or Hermes server sends
into APNs and FCM pushes (see [PROTOCOL.md](PROTOCOL.md) §5). It only ever
handles ciphertext, keeps no database, and writes no access logs. The source
is in [`relay/`](../../relay).

> **A self-hosted relay only serves apps you build yourself.** An APNs device
> token is bound to the app's bundle id and the Apple team that signs it, and
> an FCM token to the Firebase project built into the app. Your relay can't
> hold the official Conduit keys, so it can't reach the App Store or Google
> Play builds. Build Conduit with your own bundle id, Firebase project and
> relay:
>
> ```bash
> flutter build ipa --dart-define=CONDUIT_PUSH_RELAY_URL=https://push.example.com
> ```
>
> On Android you can skip the relay altogether: pick a UnifiedPush
> distributor (ntfy and others) in Conduit's push settings, and your server
> posts to it directly.

## 1. Build the image

```bash
docker build -t conduit-push-relay relay/
```

The image holds one Rust binary on `gcr.io/distroless/cc-debian12`. It runs
as the unprivileged `nonroot` user (uid 65532), has no shell, and holds
no configuration. Without Docker, `cargo build --release --locked` in `relay/`
produces the same binary at `relay/target/release/conduit-push-relay`.

## 2. Make the keys

### Seal key

Endpoints are sealed with a 32-byte key that only the relay holds:

```bash
openssl rand -base64 32
```

Back it up. If it is lost, every endpoint the relay has issued stops opening,
servers delete those subscriptions, and devices must register again.

### APNs key (`.p8`)

1. In the Apple Developer portal, open **Certificates, Identifiers & Profiles
   → Identifiers**, and make sure your app's bundle id has **Push
   Notifications** enabled.
2. Under **Keys**, add a key with **Apple Push Notifications service (APNs)**
   enabled. If you are asked for an environment, choose **Sandbox &
   Production**.
3. Download the `.p8` file (Apple lets you do this only once), and note the
   **Key ID**. Your **Team ID** is on the Membership page.

### FCM service account

1. In the Firebase console for your project, make sure the **Firebase Cloud
   Messaging API (V1)** is enabled (Project settings → Cloud Messaging).
2. In Google Cloud, create a service account in the same project with only the
   **Firebase Cloud Messaging API Admin** role, and add a JSON key to it.
   (Firebase's Project settings → Service accounts → *Generate new private
   key* also works, but that account has far broader rights.)

The relay reads `project_id`, `client_email`, `private_key` and `token_uri`
from the JSON.

## 3. Configure

Settings come from environment variables. A provider is turned on only when
all of its settings are present. When some are missing, the relay starts
without it and logs which ones.

### Core

| Variable | Default | Meaning |
|---|---|---|
| `RELAY_PUBLIC_URL` | required | The relay's public origin, such as `https://push.example.com`. Endpoints are `<RELAY_PUBLIC_URL>/v1/push/<sealed>`. |
| `RELAY_SEAL_KEYS` | required | `kid:key` pairs, comma-separated: `1:<base64 32 bytes>,2:<…>`. Key ids are 0–255. |
| `RELAY_SEAL_ACTIVE_KID` | required | The key id new endpoints are sealed with. |
| `RELAY_LISTEN_ADDR` | `0.0.0.0:8080` | Address of the public API. |
| `RELAY_METRICS_ADDR` | off | Address for Prometheus `/metrics`. Keep it private. |
| `RELAY_TRUST_FORWARDED_FOR` | `false` | Take the client address for rate limits from the **last** `X-Forwarded-For` entry. Turn it on only when every request comes through your proxy. |
| `RELAY_MAX_CONNECTIONS` | `4096` | Connections served at once, per listener. More wait in the kernel's queue until one closes. |
| `RUST_LOG` | `warn` | Log level. |

### APNs

| Variable | Default | Meaning |
|---|---|---|
| `APNS_TEAM_ID` | | Your Apple Team ID. |
| `APNS_KEY_ID` | | The `.p8` key's Key ID. |
| `APNS_KEY_P8_FILE` | | Path to the `.p8` file. |
| `APNS_KEY_P8` | | The `.p8` contents instead of a file (`\n` escapes are accepted). |
| `APNS_APPS` | | Bundle ids allowed to register, comma-separated. |
| `APNS_HOST_PROD` | `https://api.push.apple.com` | Production host. |
| `APNS_HOST_DEV` | `https://api.sandbox.push.apple.com` | Sandbox host, used for devices that register with `env: dev` (debug builds). |

### FCM

| Variable | Default | Meaning |
|---|---|---|
| `FCM_SERVICE_ACCOUNT_FILE` | | Path to the service-account JSON. |
| `FCM_SERVICE_ACCOUNT_JSON` | | The JSON itself instead of a file. |
| `FCM_APPS` | | Android package names allowed to register, comma-separated. |
| `FCM_API_BASE` | `https://fcm.googleapis.com` | FCM API origin. |
| `FCM_TOKEN_URI` | the JSON's `token_uri` | OAuth token endpoint. |

The relay fetches one FCM access token at a time and shares it. If a fetch
fails, it answers FCM pushes with `503` and `Retry-After` for the next 30
seconds instead of asking Google again for each one, and it turns away pushes
beyond 256 waiting on a slow fetch.

### Rate limits

All limits are kept in memory, per relay instance.

| Variable | Default | Limit |
|---|---|---|
| `RELAY_RATE_ENDPOINT_PER_MIN` | `60` | Pushes per minute to one endpoint… |
| `RELAY_RATE_ENDPOINT_BURST` | `20` | …with bursts of up to this many. |
| `RELAY_RATE_ENDPOINT_PER_DAY` | `2000` | Pushes per day to one endpoint. |
| `RELAY_RATE_IP_PER_MIN` | `6000` | Pushes per minute from one sender address (IPv6: one /64), all of which may arrive at once. |
| `RELAY_RATE_REGISTER_PER_MIN` | `20` | Registrations per minute from one address. |

Over a limit, the relay answers `429` with `Retry-After`.

Each limit tracks at most a million keys (endpoints or addresses), and a
sweep once a minute drops the ones whose buckets have refilled. If a table
fills up anyway, requests with a key it doesn't hold yet get `429` until the
next sweep makes room; keys it already holds carry on as before.

The per-sender limit is high on purpose. One message in an Open WebUI channel
notifies up to 500 members (the function's default), each on up to 10
devices, so a single message can be 5000 pushes from one server within
seconds. A sender's bucket holds a full minute's worth, so that goes through.
Devices are protected by the per-endpoint limits, which every one of those
pushes also has to pass. Servers that share an address, behind one NAT for
example, share this limit.

## 4. Run it behind TLS

The relay speaks plain HTTP, so it must sit behind a reverse proxy that
terminates TLS. Don't expose its port to the internet: the request path *is*
the endpoint capability, so it needs TLS on the wire. Turn the proxy's access
log off for the same reason; the relay itself never logs the path.

The relay also enforces its own timeouts, so a slow or stuck client can't hold
its connections, whatever the proxy in front does:

- A client has 10 seconds to send a request's headers. It has the same to
  start its first request on a new connection, or its next one on a kept-alive
  HTTP/1 connection.
- A connection with no request in progress for 30 seconds is closed. An
  HTTP/2 client that has sent nothing for 15 seconds is pinged, and dropped if
  it doesn't answer within 10.
- At most `RELAY_MAX_CONNECTIONS` connections are open at once.
- On shutdown, requests in progress get 20 seconds to finish. Connections
  still open after that are dropped.

So a proxy that keeps idle connections to the relay open for longer than 10
seconds can pick one just as the relay closes it, and a push sent on it fails
with `502`. Keep the proxy's upstream keep-alive below 10 seconds. Caddy's
default is 2 minutes, which the example below lowers; nginx as configured
below doesn't reuse upstream connections.

Keep the secrets in files readable by uid 65532 and out of your shell history:

```bash
sudo install -d -m 0755 /etc/conduit-push/secrets
sudo install -m 0444 AuthKey_XYZ987WVUT.p8 /etc/conduit-push/secrets/apns.p8
sudo install -m 0444 fcm-service-account.json /etc/conduit-push/secrets/fcm.json
sudo tee /etc/conduit-push/relay.env >/dev/null <<'EOF'
RELAY_PUBLIC_URL=https://push.example.com
RELAY_SEAL_KEYS=1:PASTE_THE_OUTPUT_OF_openssl_rand_-base64_32
RELAY_SEAL_ACTIVE_KID=1
RELAY_TRUST_FORWARDED_FOR=true
RELAY_METRICS_ADDR=0.0.0.0:9100
APNS_TEAM_ID=ABCDE12345
APNS_KEY_ID=XYZ987WVUT
APNS_KEY_P8_FILE=/secrets/apns.p8
APNS_APPS=com.example.conduit,com.example.conduit.debug
FCM_SERVICE_ACCOUNT_FILE=/secrets/fcm.json
FCM_APPS=com.example.conduit
EOF
sudo chmod 0600 /etc/conduit-push/relay.env

docker run -d --name conduit-push-relay --restart unless-stopped \
  --env-file /etc/conduit-push/relay.env \
  -v /etc/conduit-push/secrets:/secrets:ro \
  -p 127.0.0.1:8080:8080 \
  -p 127.0.0.1:9100:9100 \
  conduit-push-relay
```

Docker reads `relay.env` itself, so it stays private to root and is not
mounted into the container.

A [Caddy](https://caddyserver.com) site, which writes no access log unless
you add a `log` directive and sets `X-Forwarded-For` to the real client:

```caddyfile
push.example.com {
	reverse_proxy 127.0.0.1:8080 {
		transport http {
			keepalive 5s
		}
	}
}
```

Or nginx:

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name push.example.com;
    # ssl_certificate / ssl_certificate_key …

    access_log off;
    error_log /var/log/nginx/push-error.log crit;  # error lines name clients
    client_max_body_size 16k;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

Check it:

```bash
curl https://push.example.com/v1/info
# {"proto":1,"active_kid":1,"max_body":2134,"providers":["apns","fcm"]}
```

`GET /healthz` answers 200 while the process runs; use it for liveness.
`GET /readyz` answers 200 once every configured provider can get its
credential (an APNs provider token, an FCM access token), checked at most
every five minutes; use it for readiness. The relay is stateless, so you can
run several instances behind one name. Rate limits are then per instance.

## 5. Rotate the seal key

Every endpoint carries its key id in clear (the second byte of the sealed
string), and `/v1/info` reports the active one. Devices register again when
`/v1/info` shows a newer `active_kid` than their endpoint carries.

1. Generate a new key and add it under a **new** key id on every instance,
   leaving the active id alone: `RELAY_SEAL_KEYS=1:<old>,2:<new>`,
   `RELAY_SEAL_ACTIVE_KID=1`. Wait until every instance runs with it.
2. Set `RELAY_SEAL_ACTIVE_KID=2` everywhere. New endpoints are sealed under
   key 2; devices move over as they next check in.
3. Keep key 1 for **90 days**, then remove it. Endpoints still sealed under it
   answer `410`, servers delete them, and any device that comes back registers
   again.

Never change the bytes behind an existing key id. Endpoints sealed under the
old bytes would answer `404` and be deleted, and devices would not notice,
because the key id did not change. If a key is lost or leaked, replace it
under a new key id.

## 6. Privacy

What the relay sees:

- **For each push:** the sending server's IP address, the time, the padded size
  class (512, 1024 or 2048 bytes), the `TTL`, `Urgency` and `Topic` headers
  (`Topic` is an HMAC the relay can't reverse), and the encrypted body, which
  it can't read. It opens the endpoint in memory to get the provider, app,
  environment, subscription id and device token it needs for the APNs or FCM
  call.
- **For each registration:** the device's IP address, its push token, the app
  id, the environment and the subscription id. It seals them into the endpoint
  it returns, and keeps nothing.

What it keeps:

- No database and no files. Nothing survives a restart.
- No access logs. Log lines are warnings about provider failures, carrying
  only the provider, a category and the provider's status code. The HTTP
  libraries underneath are held at `warn` whatever `RUST_LOG` says, because at
  lower levels they can print URLs.
- Rate-limit counters, in memory, keyed by a truncated SHA-256 of the
  endpoint and by sender address. Each is dropped within a minute of having
  refilled.
- Metrics: counts of pushes and registrations by provider and result, nothing
  else.

Nothing the relay handles names a person, an account or a server, except the
sender's IP address, which it uses only for rate limits.

Apple or Google see the device token, the app, the time and the size of the
encrypted body, as they do for any push. Apple also sees the collapse id.
