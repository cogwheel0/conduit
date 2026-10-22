# Conduit delivery integration

The Android app renders existing assistant `MEDIA:` references and downloads
original files through authenticated `/api/fs/download`. This optional Hermes
plugin adds the separate cross-app action: `send_to_conduit`.

The plugin is prepared for Hermes 0.22.2. The installed host's API signatures were
inspected through Hermes Desktop on 2026-10-22. **It is not installed by this
directory's existence.** Validate the plugin on the target host before enabling it.

## Behavior

- A user-requested send stores a file snapshot and appends one assistant receipt
  to the profile's **Received files** conversation. It does not invoke a model.
- Use the same UUID `delivery_id` when retrying a send. A journal plus Hermes'
  public `has_platform_message_id` guard recovers a commit without appending it
  twice. Each profile has its own store, snapshots, lock, and inbox.
- Originals can move after delivery. The receipt refers to the durable snapshot.
- Hermes' existing media-delivery policy admits each source. The plugin does not
  bypass that policy, modify SOUL.md, change providers, or open a network listener.
- A delivery contains at most 16 files and 256 MB total. Delivered snapshots
  remain on the server until the owner removes them. Removed snapshots produce
  an error rather than a false successful retry.
- The result confirms **server storage**. Closed-app push notifications and
  automatic phone receipt are separate capabilities and are not promised here.

## Installation boundary

Copy only `conduit_delivery/__init__.py` and `plugin.yaml` into a dedicated user
plugin directory named `conduit-delivery` under the owning Hermes profile. Enable
that plugin through the installed Hermes plugin manager, preserving existing
configuration. Check that `send_to_conduit` is discoverable in a fresh session.
Do not restart a running gateway until its active work can safely stop.

With Dashboard sign-in enabled, the CLI can report a gateway reload while the
separate Dashboard process retains its old tool registry. Activate the Agent
plugin through Hermes Desktop's authenticated **Capabilities → Plugins** control
for the connected profile. The installed 0.22.2 Dashboard also exposes
`POST /api/dashboard/agent-plugins/activate` to authenticated sessions; a CLI
service token does not replace that sign-in. Verify an actual model-facing tool
call, rather than treating a successful standalone handler call as activation.

For natural-language requests from Telegram or Desktop, the plugin registers a
tool and a bounded capability description. This avoids relying on Hermes'
`send_message` helper, which is not an ordinary agent-callable model tool.

The file also supports direct use with the Hermes Python environment:

```text
python /path/to/conduit-delivery/__init__.py /path/to/file.wav --delivery-id UUID
```

The handler borrows the profile's shared writer with
`hermes_state_registry.acquire(home / "state.db")` and releases its reference in
`finally`. It does not open or close a competing writer in the gateway process.
The implementation uses public SessionDB methods. Host verification must check:
create/title/read/append/idempotency primitives; profile selection; file route
access; the visible receipt in Conduit; and retries after an interrupted append.
Keep inbox compression/archiving behavior and live refresh/notification behavior
explicitly unverified until exercised against the installed host.

## Tests

`python3 -m unittest discover -s integrations/hermes -p 'test_*.py'`

These cover the delivery algorithm with a SessionDB contract double. They do not
claim that the plugin has loaded in Hermes or that a phone received anything.
