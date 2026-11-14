# Conduit

Conduit is a native Flutter client for iOS and Android. It talks to self-hosted
Open WebUI and LibreChat servers, straight to model providers
(OpenAI-compatible APIs, Ollama, OpenRouter), to Apple's on-device and Private
Cloud Compute models, and to self-hosted Hermes agents. It ships on the App
Store and Google Play, and as a build without Google services for F-Droid and
IzzyOnDroid.

## What Conduit must keep

People chose Conduit for these. Weigh every change against them.

### 1. Private and local-first

Chats, notes, and drafts live on the device first. No service the maintainer
runs receives chat content: traffic goes from the device to the server or
provider the user configured. The one exception is the optional push relay,
which forwards notifications it cannot read
([what each party sees](docs/push/THREAT_MODEL.md)). Credentials stay in
platform secure storage. There are no analytics or advertising SDKs. A change
that sends anything anywhere new needs the maintainer's sign-off first.

### 2. Native on each platform

iOS gets iOS controls and behavior, and Android gets Android's. The app does
not paint one look on both. Platform widgets are reached only through the
platform UI seam, `lib/shared/widgets/platform_ui`.

### 3. Every backend counts

Open WebUI, LibreChat, Direct connections, Apple's models, and Hermes are all
first-class. A feature needs a decision for each one, even when the decision is
"not supported here", and that decision should be visible to the user rather
than a silent gap.

### 4. Smooth under load

Long chats scroll and stream without dropped frames. People notice a hitch, a
spinner that lies, and a stale label. Weigh frame time and memory for anything
that touches the transcript, streaming, markdown, or lists.

## How to work

Understand the real constraint, then make the smallest change that makes the
correct behavior unsurprising. Do not keep complexity because it already
exists, and do not add machinery because it looks impressive. Fight scope
creep. Honor what the maintainer asked for, in a minimal and realistic way.

Treat the rest of this file as good defaults, not hard rules. What the
maintainer tells you overrides anything here, except the privacy review.

Most changes here are made by agents, often several at once on one machine.
Other worktrees, simulators, emulators, and builds probably belong to someone
else's task.

## A small glossary

- **you** means the agent reading this file.
- **maintainer** means the person directing your work.
- **user** means the person using the app.
- **backend** means what a chat talks to: an Open WebUI server, a LibreChat
  server, a Direct connection, an Apple model, or a Hermes agent.
- **account** means a signed-in Open WebUI or LibreChat server. Several can
  sit side by side.
- **Direct connection** means a saved profile for a provider endpoint, with no
  server account.
- **core** means `packages/conduit_core`: the logic, in pure Dart.
- **host** means the program that runs the core and supplies what it cannot do
  itself. Today that is the Flutter app.
- **port** means an interface the core declares and the host implements, such
  as storage, the clipboard, or connectivity. The Flutter ones are in
  `lib/platform`.
- **seam** means the platform UI seam, `lib/shared/widgets/platform_ui`.
- **reference sources** means the `openwebui-src`, `librechat-src`, and
  `hermes-src` submodules: upstream code kept to read, never built or shipped.

## The three ways to hurt yourself

1. **Acting on what you did not start.** Never `pkill -f`, `killall`, or kill a
   process you found by matching a name or a path. Never shut down, erase, or
   delete a simulator, an emulator, a worktree, or a build folder you did not
   create. Stop only a PID you captured when you started it.
2. **Leaking private data.** Real chats, prompts, server addresses, tokens, and
   screenshots of them never go into a commit, a fixture, a log you paste, or a
   pull request. See the privacy review below.
3. **Fighting generated code.** `*.g.dart` and `*.freezed.dart` files are
   git-ignored. Hundreds of analyzer errors in files you never touched mean
   code generation has not run, not that the source is broken. Never hand-edit
   or commit generated files. Change the input (annotated Dart, an ARB file,
   `pigeons/`) and generate again.

## Hit every surface

The most common defect is a change that works on the path you tested and is
missing everywhere else. Before calling user-visible work done, walk this list
and say which entries applied:

- **Platforms.** iOS and Android, phone and tablet. Android has two builds:
  `play` and `foss`. The `foss` build must compile without Firebase, Google
  Play services, or ML Kit; CI fails if it pulls them in.
- **Backends.** Open WebUI, LibreChat, Direct connections (OpenAI-compatible,
  Ollama, OpenRouter), Apple On-Device and Private Cloud Compute, and Hermes.
  Do not carry one backend's assumptions into another.
- **Entry points.** Something reachable from the chat screen is often also
  reachable from Settings, a keyboard shortcut, the share sheet, a home screen
  widget, a quick action, App Intents and Shortcuts, the Android assistant,
  CarPlay, or a notification. Fixing one is not fixing the feature.
- **Core first.** Logic goes in `packages/conduit_core`; the app's widgets stay
  thin. `tool/check_package_boundaries.dart` lists the directories that are
  already free of Flutter, and that list only grows.
- **The seam.** No new `material_ui` or `cupertino_ui` import, and no raw
  platform control, outside `lib/shared/widgets/platform_ui`.
  `tool/platform_ui_allowlist.yaml` only shrinks.
- **Languages.** A new string goes in `lib/l10n/app_en.arb` with an `@key`
  description, and is translated in every other locale in the same change.
- **Connection states.** Online, offline, and reconnecting. Synced chats and
  notes stay readable without a connection.
- **Reverse states.** If you added a way in, add the way out and the way to see
  it. A one-way door is a bug.
- **Docs.** Check whether the change makes the README, `docs/BUILDING.md`, or a
  page under `docs/` inaccurate. Apply the [documentation rules](#documentation)
  before adding anything.

## Setup

- `dart tool/setup_worktree.dart` prepares a clone or a worktree: the two
  submodules the build needs, `flutter pub get`, and code generation for the
  app and the packages. T3 Code runs it from `t3.json` when it creates a
  worktree.
- That setup runs in the background. While `.t3/setup-running` exists and
  names a live PID, wait for it and do not start `pub get` or `build_runner`
  yourself. It ends with `.t3/setup-done` or `.t3/setup-failed`, which holds
  the end of the failing step's output. With no marker at all, setup never ran
  here, so run it.
- After you change annotated Dart, switch branches, or pull, run
  `dart run build_runner build` again, in the app or in the package whose
  sources changed.
- The iOS simulator build is Apple Silicon only and needs the
  `XCODE_XCCONFIG_FILE` setting shown in [docs/BUILDING.md](docs/BUILDING.md),
  which also covers Android, release builds, and troubleshooting.

## Verifying

- Before you push, run `dart run tool/check_changed.dart`. It runs CI's fast
  checks for what the branch changed: the seam, the package boundaries, the
  ARB checks, the analyzer for each changed package and everything that
  depends on it, and the tests beside the changed files. It ends by naming the
  CI jobs it left out.
- While you iterate, run `flutter test <file>` for the app, or `dart test
  <file>` from a package's own directory.
- **Do not run the whole suite** (`dart run tool/run_test_shards.dart`, or a
  bare `flutter test`) unless the maintainer asks, or the change is broad: a
  dependency bump, shared test setup, or `test/flutter_test_config.dart`. CI
  runs it on every pull request.
- Test behavior that can break: transports and streaming, sync and the offline
  queue, sign-in, migrations, parsing, race fixes, and the logic a bug fix
  changed. Leave out tests for what types guarantee, trivial logic, copy text,
  and mock-call mirrors.
- Extend an existing test or table before you add a new test. Test at one
  layer, the lowest one that fails on `main`.
- A logic, data, state, or protocol bug gets a failing test first, then the
  fix. A purely visual bug gets before and after captures and no test.
- No test waits on real time. Use `fakeTimeTest` from
  `test/support/fake_time.dart`, `fakeAsync`, or `tester.pump(duration)`.
- A test must pass alone and inside its shard, where files share an isolate.
  Set up the state the test needs and put back what it changed.
- [docs/internals/testing.md](docs/internals/testing.md) has these rules in
  full, plus the review guidance the review bots follow. Change both together.
- Before you change a call to Open WebUI, LibreChat, or Hermes, read the
  endpoint, the payload, and the events in the matching reference source. Do
  not trust memory for a server's API.
- A user-visible change gets one pass in the real app, on a simulator or an
  emulator, after everything is integrated. The primary agent does it once.
  Subagents do not boot devices or start builds of their own.

## Pull requests

- Never push, open a pull request, comment, or label unless the maintainer
  asks.
- Title: one plain sentence saying what changes for the user, such as "Keep
  the top bars clear of a side safe area". No prefixes and no internal names.
- Body: the problem in a sentence or two, then how you fixed it, then how you
  checked it and what you could not check.
- UI changes need before and after images. Motion or timing needs a short
  recording. Upload them to the pull request. Never commit them.
- One request is one pull request. Split it only when the maintainer asks.
  Outside contributions follow [CONTRIBUTING.md](CONTRIBUTING.md).
- Check every bot finding against the source. Fix the real ones and answer the
  false ones with the reason.

### Privacy review before pull requests

Before creating or updating a pull request, review its complete diff, title,
body, comments, screenshots, recordings, and attachments for private information.
Never include personal information, private reference images, real chats, prompts,
responses, files, credentials, or instance configuration. All examples, fixtures,
screenshots, and recordings must use newly invented synthetic content. Do not
copy or paraphrase private content into demo data. Complete this review before
publication or uploading any attachment.

## Documentation

Most code changes need no documentation change. Agents can read the code.

- `docs/internals/` is for decisions and their reasons, constraints that span
  components, and traps that are hard to find from the source. Before adding a
  paragraph, ask what a maintainer would get wrong without it. If reading the
  code answers the question, leave it out.
- Do not document every feature, list fields or methods, narrate control flow,
  keep file catalogs, or append summaries of pull requests.
- A reason the code cannot show goes in a short comment beside the code. Use a
  page when the reasoning crosses components. Link to the source instead of
  copying it.
- When a documented decision changes, rewrite or remove the text. Do not add a
  second account beside the old one.
- The README is for people who use the app: what a feature does, how to start,
  and anything surprising. `docs/BUILDING.md` is for building and verifying.
  `docs/push/` is for people who run a server.

## Plans and work artifacts

- Do not commit implementation plans, research notes, review reports, or
  scratch files. Keep them outside the worktree.
- A merged pull request is the record of the work. Do not keep a second
  checklist in the repository.

## Where code lives

- `lib/` is the Flutter app. `lib/features/` holds the product areas,
  `lib/core/` the app-wide services and routing, `lib/shared/` the reusable
  widgets and the seam, and `lib/platform/` the Flutter side of the core's
  ports and the native integrations.
- `packages/conduit_core` holds the logic: auth, API clients, streaming, sync,
  the database, chat state, and Direct connections. Pure Dart; `dart:io` is
  allowed, Flutter is not.
- `packages/conduit_markdown` holds markdown preprocessing and the parsers that
  turn model output into blocks. It must compile with `dart compile js`.
- `packages/conduit_theme` holds the color palettes, and `packages/conduit_ddgs`
  the web search scrapers for on-device models.
- `ios/` and `android/` hold the native code: bridges, widgets, the share and
  notification extensions, and CarPlay. Swift in `ios/Runner` reaches its host
  only through `ConduitBridgeHost`, unless it is marked Flutter-host-only.
- `relay/` is the push relay (Rust). `server-plugins/` holds the Open WebUI
  function and the Hermes plugin that send pushes (Python). The relay, the
  plugins, and the Swift tests all check against `push/test-vectors`.
- `tool/` holds the checks and generators, with their tests in `test/tool/`.
- `openwebui-src/`, `librechat-src/`, `hermes-src/`, and `third_party/` are
  submodules. Never edit them.

## Taste

- Complexity belongs at the edge where a backend or a platform differs. The
  core stays free of Flutter, and widgets stay thin.
- Diagnostics go through `DebugLogger` with a slash-scoped `scope:` such as
  `auth/proxy`. No `print`.
- Credentials, tokens, and keys go through `SecureCredentialStorage`. Headers
  that carry them stay on the client configured for that server.
- Text from a model or a server is untrusted wherever it reaches a WebView, a
  URL, or a file path.
- Reuse what the repository, the SDK, and the platform already offer before you
  add a dependency or an abstraction.
- Default to no comment. Write one only for a constraint, an outside quirk, or
  an invariant the code cannot show. Do not restate names, narrate steps,
  record history, or explain the fix you just made; the pull request carries
  that.
- Never add or widen an `// ignore:`, an `analysis_options.yaml` exclusion, or
  an allow-list entry to make a check pass without the maintainer's sign-off.
- If a rule here fights the task in front of you, say so plainly and get the
  maintainer's sign-off before breaking it.
