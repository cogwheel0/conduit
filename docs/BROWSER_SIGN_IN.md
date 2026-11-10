# Browser sign-in (passkeys and security keys)

Conduit can sign in to an Open WebUI server's SSO provider in the system
browser instead of its in-app web view. The in-app web view can't use
passkeys or security keys for your identity provider: iOS and Android don't
offer WebAuthn there. The system browser can, so passkeys, security keys,
and anything else your provider supports in a browser work.

This guide is for the administrator who sets it up. Users only enter a client
ID, once per server.

## Requirements

| | |
| --- | --- |
| Open WebUI | `0.8.0` or newer, with `ENABLE_OAUTH_TOKEN_EXCHANGE=true`. `0.11.0` or newer to limit which apps' tokens it accepts |
| SSO provider | `oidc`, `microsoft`, or `google`, already working for Open WebUI on the web. GitHub and Feishu use the in-app sign-in only |
| Identity provider | Serves HTTPS, and lets you register a public client (no secret) with PKCE |
| Users | Already exist in Open WebUI. Token exchange never creates accounts, so a new user signs in once on the web first |

## How it works

Conduit asks Open WebUI where its provider signs in (`/oauth/{provider}/login`)
and discovers the identity provider from that. It then runs its own OpenID
Connect sign-in in the system browser: authorization code with PKCE (S256),
using a public client you register for Conduit. Conduit trades the provider's
access token for an Open WebUI session at
`POST /api/v1/auths/oauth/{provider}/token/exchange`. Open WebUI checks the
token against the provider's user info, the same way its own sign-in does.

The provider's refresh token stays on the device, in secure storage, one per
account. When the Open WebUI session expires, Conduit renews it silently, with
no browser. Signing out deletes the refresh token, and revokes it if the
provider has a revocation endpoint. A refresh token is not revoked while
another account on the device still signs in as the same provider user with
the same client, since some providers end the whole grant on revocation.
Conduit doesn't end the provider's browser session.

## Set up Open WebUI

| Variable | Needed for |
| --- | --- |
| `ENABLE_OAUTH_TOKEN_EXCHANGE=true` | Always. It is read only at startup, so restart Open WebUI after setting it |
| `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true` | Microsoft, and any provider whose `sub` differs per client. It covers every provider, so read [Merging by email](#merging-by-email) first |
| `OAUTH_TOKEN_EXCHANGE_TRUSTED_CLIENT_IDS` | Recommended when the provider has token introspection (Open WebUI 0.11 and later). List Conduit's client ID, and any other app that uses token exchange. See [Which apps' tokens are accepted](#which-apps-tokens-are-accepted) |
| `OAUTH_TOKEN_EXCHANGE_RATE_LIMIT`, `OAUTH_TOKEN_EXCHANGE_RATE_LIMIT_WINDOW` | Optional throttle per client address. Off unless set; the window defaults to 180 seconds |
| `MFA_ALLOW_OAUTH_BYPASS=true` | Optional, with `ENABLE_MFA` (0.12 and later). See [Two-step verification](#two-step-verification) |

Open WebUI finds the user for an exchanged token by the provider's `sub` claim.
If that finds no one and `OAUTH_MERGE_ACCOUNTS_BY_EMAIL` is on, it looks the
user up by email instead. Most providers send the same `sub` to every client,
so no merging is needed. Microsoft Entra ID sends a different `sub` to each
application, so Conduit's client can only find the user by email.

### Merging by email

`OAUTH_MERGE_ACCOUNTS_BY_EMAIL` applies to every provider Open WebUI has, and
to its own web sign-in too. Whoever signs in with a matching email address
takes over the existing account. Turn it on only if every configured provider
verifies the email addresses it sends. With Microsoft Entra ID, prefer a
single-tenant app: in a multi-tenant app, a user's email comes from their own
tenant, whose administrator controls it.

### Which apps' tokens are accepted

Token exchange accepts any access token the provider's user info endpoint
accepts. That includes tokens the provider issued to other apps. So without a
client check, any app that holds a user's token from your provider, such as
another app they signed in to with it, can exchange it for that user's Open
WebUI session. Open WebUI before 0.11 has no client check at all.

- **Providers with token introspection,** such as Keycloak: set
  `OAUTH_TOKEN_EXCHANGE_TRUSTED_CLIENT_IDS` to Conduit's client ID, plus any
  other app that uses token exchange. Open WebUI then asks the introspection
  endpoint, with its own client's credentials, which client each token was
  issued to. The provider must let Open WebUI's client introspect tokens
  issued to Conduit's client.
- **Google and Microsoft** have no introspection endpoint, so every exchange
  with them fails while the list is set. Turn on token exchange for them only
  if you accept the risk above. Otherwise users sign in in-app.
- **The list covers every provider on the server.** A server that also signs
  in with Google or Microsoft can't set it without breaking their exchanges.

The list checks a client ID, not the app that holds the token. Conduit's
client is public, so its ID is no secret: another app can run its own sign-in
with it, and use the token it gets if the user signs in there. The list
narrows which apps' tokens are accepted, but doesn't rule this out.

### Other checks on exchanged tokens

- `OAUTH_ALLOWED_DOMAINS` restricts which email domains can sign in.
- With `ENABLE_OAUTH_ROLE_MANAGEMENT` or `ENABLE_OAUTH_GROUP_MANAGEMENT` on,
  Open WebUI reads roles and groups from Conduit's token. It reads the user
  info first, then the access token's own claims.
- So Conduit's client must emit the same role and group claims as Open
  WebUI's client, or users can lose their groups or be refused.
- A token with no roles claim is refused while `OAUTH_ALLOWED_ROLES` doesn't
  contain `*`.

### Session length

`JWT_EXPIRES_IN` (default `4w`) sets how often Conduit
renews. How long a device stays signed in without opening the browser again
depends on the provider's refresh-token lifetime and idle timeout.

## Register Conduit with your identity provider

Create a **new client** for Conduit on the same identity provider Open WebUI
uses. Don't reuse Open WebUI's client: it has a secret, and Conduit can't keep
one.

| Setting | Value |
| --- | --- |
| Client type | Public: no secret, token endpoint auth method `none` |
| Grant types | `authorization_code`, `refresh_token` |
| PKCE | Required, `S256` |
| Redirect URI | `conduit://oauth/callback` (Google: see [Google](#google)) |
| Scopes | `openid email profile`, plus `offline_access` where the provider has it |

Conduit asks for `offline_access` only when the provider advertises it, and
uses `access_type=offline` with Google instead. If the provider issues no
refresh token, sign-in still works, but Conduit asks the user to sign in again
whenever the Open WebUI session expires.

The token's user info must include `sub` and `email` (or whatever
`OAUTH_SUB_CLAIM` and `OAUTH_EMAIL_CLAIM` name).

### PocketID

- **OIDC Clients → Add:** turn on **Public client** and **PKCE**, with callback
  URL `conduit://oauth/callback`.
- **In Conduit:** enter the client ID. Discovery finds PocketID on its own.

### Authentik

Create a provider with these settings:
- **Type:** OAuth2/OpenID.
- **Client type:** Public.
- **Redirect URIs:** strict `conduit://oauth/callback`.
- **Scopes:** add the `offline_access` scope mapping so it issues refresh
  tokens.

Bind the provider to a new application.

Authentik gives each application its own issuer, so Conduit can't discover it.
When the setup asks for one, enter
`https://<authentik>/application/o/<application-slug>/`.

### Keycloak

1. In the same realm as Open WebUI's client, go to **Clients → Create client**
   and choose OpenID Connect.
2. Turn **Client authentication** off and **Standard flow** on.
3. Set **Valid redirect URIs** to `conduit://oauth/callback`.
4. Under **Advanced**, set **Proof Key for Code Exchange Code Challenge Method**
   to `S256`.

`offline_access` is an optional client scope by default, so Conduit gets an
offline token, which outlives the realm's SSO idle timeout. Offline sessions
appear under the user's **Sessions**, and signing out of Conduit revokes them.

If Open WebUI maps roles from a client-specific claim, add the same mapper to
Conduit's client. An example is `resource_access.<client>.roles`.

### Authelia

```yaml
identity_providers:
  oidc:
    clients:
      - client_id: 'conduit'
        client_name: 'Conduit'
        public: true
        authorization_policy: 'two_factor'
        require_pkce: true
        pkce_challenge_method: 'S256'
        redirect_uris:
          - 'conduit://oauth/callback'
        scopes: ['openid', 'email', 'profile', 'offline_access']
        grant_types: ['authorization_code', 'refresh_token']
        response_types: ['code']
        token_endpoint_auth_method: 'none'
```

### Rauthy

- **Add a client:**
  - **Confidential:** off.
  - **Redirect URI:** `conduit://oauth/callback`.
  - **Flows:** `authorization_code` and `refresh_token`.
  - **PKCE challenge:** `S256`.
- **Scopes:** allow `openid email profile`, plus `offline_access` if you want
  long-lived sessions.

### Microsoft Entra ID

1. **App registrations → New registration.** Use the same tenant, and the same
   supported account types, as Open WebUI's registration.
2. **Authentication → Add a platform → Mobile and desktop applications**, with
   the custom redirect URI `conduit://oauth/callback`.
3. Set **Allow public client flows** to **Yes**. This stops the error asking
   for a client secret or assertion.
4. **API permissions:** Microsoft Graph delegated `openid`, `email`, `profile`
   and `offline_access`.
5. On Open WebUI, set `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true` (read [Merging by
   email](#merging-by-email) first).
6. **In Conduit:** enter the **Application (client) ID**.

### Google

Google accepts no custom redirect scheme, so Conduit uses Google's native-app
redirect instead.

1. **APIs & Services → Credentials → Create credentials → OAuth client ID**,
   with application type **iOS** and bundle ID `app.cogwheel.conduit`. Use
   this one client on both iOS and Android.
2. The redirect is the client ID reversed:
   `com.googleusercontent.apps.<id>:/oauth2redirect`. You don't register it;
   the settings sheet shows it for reference.
3. **On Android:** Google sign-in needs a default browser that supports Auth
   Tab, such as a current Chrome. Other browsers use the in-app sign-in.

Google issues a refresh token when the user first agrees to the client. If
renewal stops working, sign in through the browser again.

## Turn it on in Conduit

1. On the sign-in screen, open the **SSO** tab and choose **Set up browser
   sign-in (passkeys)**. It appears for `oidc`, `microsoft` and `google`
   servers that are new enough.
2. Pick the provider if the server has more than one. Enter the client ID, and
   the issuer only if Conduit asks for it (it is also under **Advanced**). The
   sheet shows the redirect URI to register; tap it to copy it.
3. **Test** checks discovery and whether the server accepts token exchange.
   Then choose **Save**.
4. **Continue in browser** signs in. **Use in-app sign-in** is still there as a
   fallback, and **Browser sign-in settings…** changes or removes the
   settings later.

The settings belong to the **server**, so every account on it uses them, on
any of its addresses. Changing the provider, client ID or issuer, or removing
the settings, ends the browser sign-ins of every account on that server.

Open WebUI itself may be served over plain `http`, with a warning. The identity
provider must use `https`.

### Adding another account

When the server already has an account in Conduit, the sign-in asks the
provider to show its account chooser: `prompt=select_account` for Google and
Microsoft, `prompt=login` for other providers. Signing back in to an existing
account suggests its email (`login_hint`).

## Two-step verification

On Open WebUI 0.12 and later, with `ENABLE_MFA` on, OAuth sign-ins also need
the authenticator code. That covers browser sign-ins, unless
`MFA_ALLOW_OAUTH_BYPASS=true`.
- Conduit asks for the code after the browser, as it does for a password
  sign-in.
- A refresh token can't answer that step, so each time the Open WebUI session
  expires, the user must sign in again in the browser.
- If your provider already enforces a second factor, such as the passkey
  itself, consider `MFA_ALLOW_OAUTH_BYPASS=true`.

## Troubleshooting

| Conduit says | Fix |
| --- | --- |
| Token exchange is turned off | Set `ENABLE_OAUTH_TOKEN_EXCHANGE=true` and restart Open WebUI |
| The server is too old | Upgrade Open WebUI to 0.8.0 or newer |
| No Open WebUI account for this user | Sign in once on the web (Conduit offers to open it), then **Retry**. For Microsoft, set `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true` |
| The provider isn't set up on the server | Open WebUI doesn't have this provider enabled |
| The identity provider rejected the client | Check the client ID, that the client is public, the redirect URI, and PKCE `S256` |
| Access prohibited | The client ID is missing from `OAUTH_TOKEN_EXCHANGE_TRUSTED_CLIENT_IDS`, or the email domain isn't in `OAUTH_ALLOWED_DOMAINS`, or role management found no allowed role in Conduit's token |
| The server can't tell which client the token is from | `OAUTH_TOKEN_EXCHANGE_TRUSTED_CLIENT_IDS` is set, but Open WebUI couldn't introspect the token: the provider has no introspection endpoint, or doesn't let Open WebUI's client use it. Allow it, or use the in-app sign-in. Unsetting the list accepts tokens from any app (see [Which apps' tokens are accepted](#which-apps-tokens-are-accepted)) |
| The token is missing required claims | Release `email` (and `sub`) to Conduit's client |
| Couldn't find the identity provider | Enter the issuer, or the full discovery URL |
| The issuer belongs to a different provider | Register Conduit's client on the identity provider Open WebUI uses |
| The identity provider isn't secure | The provider must use `https` |
| A browser with Auth Tab is needed (Android) | Make a current Chrome the default browser, or use the in-app sign-in |
| Sign-in was answered by a proxy | Open WebUI sits behind an authenticating reverse proxy. Use the in-app sign-in |
| The server couldn't check the token | Open WebUI couldn't reach the provider's user info. Usually temporary |
| Too many attempts | Raise or unset `OAUTH_TOKEN_EXCHANGE_RATE_LIMIT`. Devices behind one address share it |
| The account is waiting for approval | Approve the user in Open WebUI's admin panel |
| Signed in as a different user | The browser chose another provider account than this Conduit account's |
| The sign-in expired, or the settings changed | The refresh token expired or was revoked, or an admin changed the settings. Sign in again |

## Known limitations

- Users must already exist in Open WebUI. Token exchange never creates them.
- **Tools that forward the user's OAuth token (`system_oauth`):** token
  exchange doesn't record an OAuth session. These tools use the user's most
  recent web sign-in session instead, and get no token if there is none.
- **Private CAs on Android:** Conduit talks to the identity provider directly,
  and Android doesn't trust user-installed CAs. An exception: a provider on
  exactly the address Conduit uses for the server gets that server's
  certificate settings.
- **Providers that ignore `prompt=login`:** adding a second account signs in
  the first user again. Conduit then merges the two into one account.
- **Microsoft, with merge by email:** Open WebUI rewrites the user's stored
  `sub` whenever they alternate between web and app sign-in. Both keep
  working.
- **Kanidm:** may limit user info to the client a token was issued to. Open
  WebUI then can't check Conduit's token. Test before relying on it.
- **Cancelling on Android:** cancelling in Conduit doesn't close an open
  browser tab.
