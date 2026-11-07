# Computer viewer

The bundled viewer renders Open Terminal pixels in an isolated, nonpersistent
WebView. Browser content runs on the terminal, never in this WebView. It supports
the browser patch/JPEG stream, native desktop patches, and VNC desktops.

Rebuild the checked-in asset with `npm ci && npm run build` in this directory.
Run protocol checks with `npm test`. Dependencies are pinned in the lockfile.
noVNC is distributed under MPL-2.0; its full license and the third-party
notices ship alongside the bundle in `assets/computer`.

`build.js` makes one pinned noVNC adaptation: it omits the two local cursor
encodings, requesting server-rendered cursor pixels instead. This shows the
actual shared desktop pointer in Watch as well as Control. The build fails if
the expected upstream negotiation changes. Native desktop frames show whatever
cursor the server captures. Browser frames do not publish an agent cursor
position; the blue pointer marks only the user's input during Control and is
hidden on Watch, blur, disconnect and mode changes.

Desktop is the default when advertised. Both preview and live view explicitly
select Desktop or Browser. Only Browser has navigation controls. Landscape uses
a side panel, preserving the live surface across rotation. Larger accessibility
text uses a scrollable layout so every control remains reachable. After taking
control, Watch explains that a new chat message continues the task.

Protocol references:
- https://github.com/open-webui/open-terminal/tree/v0.17.2/open_terminal
- https://github.com/open-webui/open-webui/tree/v0.13.0/src/lib/apis/terminal

Credentials exist only in a mounted viewer's in-memory configuration. Never log
WebSocket URLs: browser viewer URLs contain a scoped access token. Previews are
explicit, in-memory snapshots and are discarded on collapse or backgrounding.
Take control waits for the chat's response cancellation; this is not an exclusive
lock on the server or on other clients. Returning to Watch does not resume a model
response. A new chat message continues work.

## API coverage

Audited against the public [Open WebUI 0.13 browser client](https://github.com/open-webui/open-webui/blob/v0.13.0/src/lib/apis/terminal/browser.ts)
and [Open Terminal 0.17.2 browser](https://github.com/open-webui/open-terminal/blob/v0.17.2/open_terminal/browser/router.py)
and [desktop](https://github.com/open-webui/open-terminal/blob/v0.17.2/open_terminal/desktop.py) routers.

| Surface | Client behavior |
| --- | --- |
| `/api/config`, `/desktop` | Advertised Desktop/Browser capabilities, desktop transport and optional audio |
| `/desktop/stream` | Authenticated VNC or native frames; shared cursor where captured, pointer/keyboard/paste, release on handoff |
| `/desktop/audio` | Explicit, initially muted WebM/Opus playback when both server and device support it; stops on background/disconnect |
| `/desktop/screenshot`, `/browser/screenshot` | On-demand preview, discarded on collapse/background |
| `/browser/tabs` | Refreshable list limited to the current user and chat |
| `/browser/sessions`, `/browser/sessions/{id}` | Create, select, keep alive and explicitly close tabs; clean up failed new sessions |
| `/browser/view/{id}/{token}/stream`, `/vnc` | Both browser transports; navigation, input, frame acknowledgments, visibility, viewport and quality |
| `/desktop/action`, `/browser/action` | Named keyboard combinations from the mobile toolbar, targeting the displayed browser session explicitly |
| `/browser/snapshot` and batched action tools | Remain server-side agent capabilities; Conduit does not replace or restrict the model's tools |

Tab mutations require Take control. A newly selected tab opens in Watch, and
closing the last tab leaves an empty state rather than silently creating another.
Leaving the viewer does not close the user's tabs. Display options include three
quality levels and a desktop website viewport. Mouse input includes right-click,
double-click and modifiers; the keyboard dialog also supports named combinations
such as `Ctrl+A`, `Alt+Tab` and `Cmd+C` through the server's action API.

On phones and tablets, Pointer controls switches between direct touch and a
relative trackpad. In trackpad mode, slide to move without clicking, tap to click,
hold to drag, and use two fingers to scroll or tap for a right-click. Explicit
click, right-click, double-click and Start/End drag controls support precise work
without covering the pointer. A locked drag survives finger lifts and ends on a
tap, explicit End drag, Watch, blur, disconnect or backgrounding. The pointer
state is independent of the connection status. Input mode resets when switching
Desktop/Browser or browser tabs.

This feature is the remote Computer viewer. Upstream's separate HTML Proxy
preview is not embedded: arbitrary remote HTML never runs in the viewer's
credential-bearing WebView. Desktop audio requires an advertised audio service
and WebM/Opus MediaSource support; unsupported devices stay muted. Browser frame
streams do not expose the agent's cursor coordinates, so their blue marker shows
user input only. VNC uses the actual server-rendered pointer.

`computer_tabs_integration_test.dart` exercises the production Dart service
against both isolated browser backends, including creation, selection, shortcuts,
screenshots, last-tab closure, and rejection of access from another chat scope.
Run it from `packages/conduit_core` with `COMPUTER_REVIEW=true flutter test
test/features/terminal/computer_tabs_integration_test.dart` after the setup below.

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
5. Use the play button to run the timed task. Open the preview, watch live, take
   control, tap or scroll, then return to Watch. Record only the simulator's
   framebuffer. Review the entire recording before sharing.

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
