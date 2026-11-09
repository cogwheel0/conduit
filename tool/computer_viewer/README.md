# Computer viewer

The bundled viewer renders Open Terminal pixels in a restricted WebView. Browser content runs on the terminal, never in this WebView. It supports
the browser patch/JPEG stream, native desktop patches, and VNC desktops.

Rebuild the checked-in asset with `npm ci && npm run build` in this directory.
Run protocol and gesture checks with `npm test`. CI runs these checks and
rebuilds the viewer to verify the checked-in bundle matches its source.
Dependencies are pinned in the lockfile.
noVNC is distributed under MPL-2.0; its full license and the third-party
notices ship alongside the bundle in `assets/computer`.

`build.js` makes one pinned noVNC adaptation: it omits the two local cursor
encodings, requesting server-rendered cursor pixels instead. This shows the
actual shared desktop pointer in Watch as well as Control. The build fails if
the expected upstream negotiation changes. Native desktop frames show whatever
cursor the server captures. Browser frames do not publish an agent cursor
position; the blue pointer marks only the user's input during Control and is
hidden on Watch, disconnect and mode changes.

In a saved Open WebUI chat, select a Computer-enabled terminal with the existing
composer Terminal picker or the sidebar's Terminal tab. The chat header then
shows a Computer button. Finding out whether the terminal offers Desktop or
Browser reads only `/api/config`; nothing starts until the button is pressed.

The viewer is a full-screen page: the remote screen, letterboxed on the page
background, under a toolbar with Back, the Desktop/Browser title (a menu when
the terminal offers both; Desktop is the default), a keyboard button and More.
More holds Trackpad mode, Paste and Recenter pointer (trackpad only), Zoom,
desktop Sound, and for Browser a row of Back, Forward, Reload and Go to
address, Browser tabs, Desktop site and Lower data use.

Settings > Chat > Computer disables the feature on this device, removes the
header button, releases any open viewer, and prevents Computer discovery and
connection requests. The preference survives restarts. It does not change the
server's tools or stop other clients' sessions. No stream is opened until
requested.

Protocol references:
- https://github.com/open-webui/open-terminal/tree/v0.17.2/open_terminal
- https://github.com/open-webui/open-webui/tree/v0.13.0/src/lib/apis/terminal

A per-viewer loopback relay connects the native WebSocket client to the trusted
pixel document. It forwards only the selected server's proxy cookies and custom
headers, without reading or changing the platform WebView cookie store. The relay
requires an unguessable path and the fixed viewer origin; only that connection's
stream, VNC and advertised audio endpoints are reachable. System terminal streams
reuse the configured server TLS policy, including client certificates and
explicitly enabled, host-scoped self-signed trust. Open WebUI account
cookies are excluded, direct terminals receive no proxy credentials, and remote
HTML navigation stays blocked. Closing the viewer closes the relay and sockets.

Credentials exist only in a mounted viewer's in-memory configuration. Never log
WebSocket URLs: browser viewer URLs contain a scoped access token.

The user controls the screen whenever the chat's response is idle. While a
response runs, the agent drives and the screen is watch-only, with an "Agent is
working" bar whose Take control waits for the response's cancellation before
granting input; this is not an exclusive lock on the server or on other
clients. A new response returns the screen to Watch, closing the keyboard and
any tab sheet. Stopping does not resume later; a new chat message continues
work. Backgrounding returns to Watch until the stream is live again.

## API coverage

Audited against the public [Open WebUI 0.13 browser client](https://github.com/open-webui/open-webui/blob/v0.13.0/src/lib/apis/terminal/browser.ts)
and [Open Terminal 0.17.2 browser](https://github.com/open-webui/open-terminal/blob/v0.17.2/open_terminal/browser/router.py)
and [desktop](https://github.com/open-webui/open-terminal/blob/v0.17.2/open_terminal/desktop.py) routers.

| Surface | Client behavior |
| --- | --- |
| `/api/config`, `/desktop` | Advertised Desktop/Browser capabilities, desktop transport and optional audio |
| `/desktop/stream` | Authenticated VNC or native frames; shared cursor where captured, pointer/keyboard/paste, release on handoff |
| `/desktop/audio` | Explicit, initially muted WebM/Opus playback when both server and device support it; stops on background/disconnect |
| `/browser/tabs` | Refreshable list limited to the current user and chat |
| `/browser/sessions`, `/browser/sessions/{id}` | Create, select, keep alive and explicitly close tabs; clean up failed new sessions |
| `/browser/view/{id}/{token}/stream`, `/vnc` | Both browser transports; navigation, input, frame acknowledgments, visibility, viewport and quality |
| `/desktop/action`, `/browser/action` | Named keyboard combinations from the keyboard row's ⌘ key, targeting the displayed browser session explicitly |
| `/desktop/screenshot`, `/browser/screenshot`, `/browser/snapshot` and batched action tools | Remain server-side agent capabilities; Conduit does not replace or restrict the model's tools |

Tab changes require control, so they wait for an idle chat or Take control.
Closing the last tab leaves an empty state with a New tab button rather than
silently creating another. While empty, the viewer rechecks every three seconds
and on resume for the agent's next tab; it pauses these checks in the
background or during tab management. An existing proxy-mode tab starts its live
view (activating Chrome) only while the chat is idle; while a response runs it
shows a start-live-view hint without fetching pixels or changing server mode,
until Take control. The viewer also attaches if the agent activates the tab
itself. Leaving the viewer does not close the user's tabs. Mouse input includes
right-click, double-click and modifiers.

The keyboard button opens the system keyboard. What is typed goes to the remote
screen as it is typed: text, Backspace and Return, with input-method text sent
once committed. A row above the keyboard adds Esc, Tab and the arrow keys, and
⌘ opens a dialog for named combinations such as `Ctrl+A`, `Alt+Tab` and `Cmd+C`
through the server's action API. The screen moves up above the keyboard; a
remote browser keeps its viewport and scales, instead of reflowing, while any
keyboard is up. A blur of the viewer releases held keys and buttons without
leaving control.

Touch drives the remote pointer directly by default. Trackpad mode in More
turns touch into a relative trackpad: slide to move without clicking, tap to
click, hold to drag, and use two fingers to scroll or tap for a right-click.
Recenter pointer moves the pointer back to the middle of the screen. A held
drag ends on lifting, Watch, disconnect or backgrounding. Trackpad mode and the
browser display options carry across reconnects and a switch of
Desktop/Browser.

This feature is the remote Computer viewer. Upstream's separate HTML Proxy
preview is not embedded: arbitrary remote HTML never runs in the viewer's
credential-bearing WebView. Desktop audio requires an advertised audio service
and WebM/Opus MediaSource support; unsupported devices stay muted. Browser frame
streams do not expose the agent's cursor coordinates, so their blue marker shows
user input only. VNC uses the actual server-rendered pointer.

`computer_tabs_integration_test.dart` exercises the production Dart service
against both isolated browser backends, including creation, selection, shortcuts,
last-tab closure, and rejection of access from another chat scope.
Run it from `packages/conduit_core` with `COMPUTER_REVIEW=true flutter test
test/features/terminal/computer_tabs_integration_test.dart` after the setup below.

`computer_webui_integration_test.dart` additionally exercises an unmodified,
disposable Open WebUI 0.13 installation: authenticated terminal discovery,
saved-chat scope, desktop WebSocket authentication, signed browser viewer
tickets, proxy-tab activation, tab selection, keep-alive, shortcuts and cleanup. Supply
`COMPUTER_WEBUI_REVIEW=true` and `COMPUTER_WEBUI_REVIEW_CONFIG` pointing to a local
JSON file with `url`, `token` and `server_id`. Use a fresh synthetic account and
terminal; never commit that configuration. The test creates and deletes its own
chat and browser tabs. Run it from `packages/conduit_core` with `flutter test
test/features/terminal/computer_webui_integration_test.dart`.

`computer_socket_relay_tls_test.dart` generates temporary synthetic certificates
with OpenSSL and verifies real TLS handshakes, including client-certificate
authentication and rejection when trust or a required identity is absent.

## Local review

`tool/computer_review.dart` is an intentionally synthetic review entry point. It
uses the production launcher, page, service and bundled viewer with real Open
Terminal Desktop and Browser surfaces. The surrounding conversation and task progress are invented;
the task is a timed fixture, not a model response. Production response cancellation
is covered separately in `chat_draft_queue_test.dart`.

Keep all review profiles, environments, build products and recordings on the
machine's approved development volume. Use an empty workspace and a fresh Chrome
profile. Never attach this fixture to a personal browser or production terminal.

1. Run `python3 tool/computer_review_server.py` for the loopback-only sample site
   on port 8767. It reads no files and loads no external resources.
2. Start a separate headless Chrome with remote debugging bound to `127.0.0.1`,
   port 8770, and explicit fresh `--user-data-dir` and `--disk-cache-dir` paths.
3. In an isolated environment, install official `open-terminal==0.17.2`. Start it
   on `127.0.0.1:8766` with API key `computer-review-only`, browser enabled,
   browser mode `personal`, and browser CDP URL `http://127.0.0.1:8770`. Disable
   desktop, terminal, notebooks and system prompt. Point its file root and logs
   at the empty review workspace. The key is a public, synthetic test value.
4. Create a browser session at `http://127.0.0.1:8767` with `X-Session-Id:
   computer-review`, then select its Chrome mode. Run Flutter with
   `--target tool/computer_review.dart --dart-define=COMPUTER_REVIEW_URL=http://127.0.0.1:8766`
   on a fresh simulator for the browser-only setup.
5. Use the play button to run the timed task. Open Computer from the header
   button, watch live, tap or scroll, and type with the keyboard. Record only
   the simulator's framebuffer. Review the entire recording before sharing.

The browser integration test creates and removes its own separate session:

```sh
COMPUTER_REVIEW=true node --test real_browser.test.js
```

`desktop.test.js` exercises native patch and RFB transports using generated pixels
and protocol fixtures; it never captures a host desktop. Set `COMPUTER_REVIEW=true`
and `COMPUTER_REVIEW_PYTHON` to an isolated Python with Pillow and websockets installed,
then run `node --test desktop.test.js` while the synthetic Chrome is available.

For both modes, use a disposable Linux VM with no host mounts. Install official
Open Terminal 0.17.2, `tigervnc-standalone-server`, `xfce4`, `dbus-x11`, `xauth`,
`xdotool`, `scrot`, `xclip` and `mousepad`. Enable Desktop and Browser, with all
files, profiles and caches confined to the VM's external disk. Forward its port
8000 to host loopback port 18768; this is the review entry point's default URL.
The browser may use the same isolated Chrome via the VM's host gateway. Do not
use the host's native desktop: it can expose personal apps and files.

`real_desktop.test.js` uses this disposable VM (hostname/user `studio`, SSH on
loopback port 12222, review key and known-hosts files in
`build/computer-review/linux`). It creates a fresh editor profile per run and
checks actual server-rendered cursor movement, Watch input blocking, dragging, typing and
saving in Mousepad, and safe reconnect. Run from this directory:

```sh
COMPUTER_DESKTOP_REVIEW=true node --test real_desktop.test.js
```

Verified with Open WebUI 0.13 protocol, Open Terminal 0.17.2, iOS 27 simulator,
Android/iOS widget layouts, a real Linux/XFCE desktop and a real Chrome browser.
Native Mac/Windows desktop transports also have fixture coverage; this is not
a claim of end-to-end testing on those host platforms.

For a native secure-context check, launch the normal debug app on a disposable
Android emulator or iOS simulator, attach with `flutter attach`, and open the
synthetic VNC desktop in Watch. Put the attached Dart VM Service WebSocket URL
in a local, ignored JSON file with a single `url` field. With Node 22 or later:

```sh
node tool/computer_viewer/native_context_check.js build/computer-review/native-vm.json
```

The read-only check evaluates the production document through the mounted native
WebView and asserts `window.isSecureContext`, `crypto.subtle`, and a rendered VNC
canvas. It requires an attached debug compiler; it does not add an app test hook.
The debug URL is a local access capability: never commit or share it. Only the
three boolean results are printed. This check passed on Android and iOS with the
normal app connected through Open WebUI 0.13 to the disposable Linux desktop.

The managed-browser path has a separate real-service check. In the same disposable
VM, run a second official Open Terminal with `browser_mode=managed`, a fresh
workspace, and an official Chromium executable. Forward its port to loopback
18769 and keep the synthetic site reachable at the VM host gateway, `10.0.2.2:8767`.
The test uses the same public test API key. Chromium must retain its sandbox;
Ubuntu may require an [executable-specific AppArmor profile](https://chromium.googlesource.com/chromium/src/+/main/docs/security/apparmor-userns-restrictions.md).

```sh
COMPUTER_MANAGED_REVIEW=true node --test managed_browser.test.js
```

This covers the VNC browser path, navigation, input gating and a second viewer
replacing the first. Protocol fixtures additionally exercise repeated transport
announcements and releasing held mouse buttons and keys during takeover changes.
