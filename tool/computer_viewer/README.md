# Computer viewer

The bundled viewer renders Open Terminal pixels in an isolated, nonpersistent
WebView. Browser content runs on the terminal, never in this WebView. It supports
the browser patch/JPEG stream, native desktop patches, and VNC desktops.

Rebuild the checked-in asset with `npm ci && npm run build` in this directory.
Run protocol checks with `npm test`. Dependencies are pinned in the lockfile.
noVNC is distributed under MPL-2.0; its full license and the third-party
notices ship alongside the bundle in `assets/computer`.

Protocol references:
- https://github.com/open-webui/open-terminal/tree/v0.17.2/open_terminal
- https://github.com/open-webui/open-webui/tree/v0.13.0/src/lib/apis/terminal

Credentials exist only in a mounted viewer's in-memory configuration. Never log
WebSocket URLs: browser viewer URLs contain a scoped access token. Previews are
explicit, in-memory snapshots and are discarded on collapse or backgrounding.
Take control waits for the chat's response cancellation; this is not an exclusive
lock on the server or on other clients. Returning to Watch does not resume a model
response. A new chat message continues work.

## Local review

`tool/computer_review.dart` is an intentionally synthetic review entry point. It
uses the production launcher, page, service and bundled viewer with a real Open
Terminal browser. The surrounding conversation and task progress are invented;
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
   `--target tool/computer_review.dart` on a fresh simulator.
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

Verified with Open WebUI 0.13 protocol, Open Terminal 0.17.2, iOS 27 simulator,
Android/iOS widget layouts, and the real browser integration. Browser typing,
shortcuts, viewport resize, Watch input blocking, blur and reconnect are asserted
against the real service. Native pointer input, rotation, background recovery and
the text dialog were exercised manually. Desktop transport coverage uses fixtures;
it does not establish compatibility with every desktop platform or VNC server.
