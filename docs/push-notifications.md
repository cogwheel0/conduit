# Push Notifications

Conduit supports optional remote push wakeups through a Conduit-owned push proxy
and Open WebUI's per-user notification webhooks.

The app still uses the existing socket/local notification path for foreground
and connected background behavior. Remote push is only activated when the app is
built with push proxy and Firebase configuration.

## Build Configuration

Set these Dart defines for a build that should register remote push:

```bash
--dart-define=CONDUIT_PUSH_PROXY_BASE_URL=https://push.example.com
--dart-define=CONDUIT_FIREBASE_API_KEY=...
--dart-define=CONDUIT_FIREBASE_PROJECT_ID=...
--dart-define=CONDUIT_FIREBASE_MESSAGING_SENDER_ID=...
--dart-define=CONDUIT_FIREBASE_APP_ID_ANDROID=...
--dart-define=CONDUIT_FIREBASE_APP_ID_IOS=...
```

Optional:

```bash
--dart-define=CONDUIT_FIREBASE_IOS_BUNDLE_ID=app.cogwheel.conduit
--dart-define=CONDUIT_FIREBASE_ANDROID_CLIENT_ID=...
```

If these are omitted, the notification settings screen still works, but remote
push registration is disabled and the app will not write webhook URLs.

## Admin Flow

Admins see an **Auto-configure server** switch in notification settings. Turning
it on shows a disclosure dialog and then sets Open WebUI's
`ENABLE_USER_WEBHOOKS` admin config flag through:

```text
GET  /api/v1/auths/admin/config
POST /api/v1/auths/admin/config
```

Conduit posts the full admin config payload back with only
`ENABLE_USER_WEBHOOKS` changed, matching Open WebUI's admin-config update
contract.

## User Flow

When a user enables system notifications, Conduit:

1. Requests OS notification permission.
2. Checks `/api/config` for `features.enable_user_webhooks`.
3. Reads the device push token:
   - Android: FCM registration token.
   - iOS: APNs token exposed by Firebase Messaging.
4. Registers the token with `CONDUIT_PUSH_PROXY_BASE_URL`.
5. Writes the returned webhook URL to
   `ui.notifications.webhook_url` in `/api/v1/users/user/settings/update`.

Conduit refuses to overwrite an existing webhook URL unless it matches the URL
that Conduit previously stored for that server. This prevents silently replacing
a user's ntfy, Nextcloud, or custom Open WebUI webhook integration.

## Push Proxy Protocol

Registration request:

```http
POST /v1/installations
content-type: application/json
```

```json
{
  "protocol_version": 1,
  "app": "conduit",
  "server_id": "server-id",
  "server_url": "https://openwebui.example.com",
  "user_id": "user-id",
  "installation_id": "stable-device-installation-id",
  "platform": "ios",
  "token_type": "apns",
  "push_token": "native-token"
}
```

Registration response:

```json
{
  "subscription_id": "subscription-id",
  "webhook_url": "https://push.example.com/v1/openwebui/webhooks/..."
}
```

Unregister:

```http
DELETE /v1/installations/{subscription_id}
```

Notification tap payloads should include:

```json
{
  "conduit_kind": "chat_completion",
  "conduit_source_id": "chat-id"
}
```

Supported `conduit_kind` values are `chat_completion` and `channel_message`.
