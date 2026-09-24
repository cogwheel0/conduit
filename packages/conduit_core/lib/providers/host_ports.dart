import 'package:conduit_core/conduit_core.dart';
import 'package:riverpod/misc.dart' show ProviderOrFamily;
import 'package:riverpod/riverpod.dart';

/// Where `lib/core` declares the seams its host must fill.
///
/// A provider here is value-less whenever the core genuinely cannot guess —
/// there is no sensible default for "where do database files live". Where a
/// no-op *is* meaningful, the default is a named type
/// (`StaticAppLifecycle`) rather than a null, so the meaning is written down
/// once instead of re-derived at each call site. `lib/core` is being
/// extracted into `packages/conduit_core`, and anything it can reach for
/// directly — `path_provider`, `WidgetsBinding`, a keychain plugin — is
/// something the `conduitd` sidecar could not provide. Throwing at read time
/// makes a missing binding a loud startup failure instead of a subtly
/// different runtime.
///
/// `main.dart` binds the Flutter implementations from `lib/platform/`; the
/// daemon binds its own.

/// Opens per-server database files.
final databaseOpenerProvider = Provider<DatabaseOpenerPort>(
  (ref) => throw UnimplementedError(
    'databaseOpenerProvider must be overridden with a host implementation '
    '(FlutterDatabaseOpener in main.dart).',
  ),
);

/// Reports foreground/background transitions.
///
/// Unlike [databaseOpenerProvider] this one has a default, because "no
/// lifecycle" is a coherent answer: a headless daemon and a unit test are
/// both permanently foreground and never transition. Throwing instead would
/// force every test that happens to construct a socket or a sync engine to
/// bind a port it does not care about.
///
/// `main.dart` still overrides it with `FlutterAppLifecycle`; without that
/// the app would simply never pause background work.
final appLifecycleProvider = Provider<AppLifecyclePort>(
  (ref) => const StaticAppLifecycle(),
);

/// Runs CPU-bound work off the calling isolate.
///
/// Defaults to inline. Spawning an isolate is a host capability — Flutter's
/// `compute` needs the engine's entry point, the daemon uses `Isolate.run` —
/// and running inline is the correct behaviour where neither exists.
final workerPortProvider = Provider<WorkerPort>(
  (ref) => const InlineWorkerPort(),
);

/// Reads and writes the system clipboard.
///
/// Defaults to an always-empty clipboard: a prompt variable that cannot be
/// filled should render blank, not fail the send.
final clipboardPortProvider = Provider<ClipboardPort>(
  (ref) => const NullClipboardPort(),
);

/// Opens links in the platform browser.
///
/// Defaults to refusing every URL, which is the safe answer for a host with
/// no browser — model output contains links, and silently doing nothing beats
/// guessing at a handler.
final openExternalUrlProvider = Provider<OpenExternalUrlPort>(
  (ref) => const NullOpenExternalUrlPort(),
);

/// Cookies captured from an external sign-in surface.
///
/// Defaults to "no browser surface", which also gates the SSO and proxy
/// entry points off in the UI.
final cookieJarProvider = Provider<CookieJarPort>(
  (ref) => const NullCookieJarPort(),
);

/// Reports whether the device has any network interface.
///
/// Defaults to assuming one exists: without an OS signal the core falls back
/// on its own health probes and on request failures, which is how it behaved
/// before the port existed.
final connectivityPortProvider = Provider<ConnectivityPort>(
  (ref) => const AlwaysOnlineConnectivityPort(),
);

/// Schedules coalesced streaming flushes.
///
/// Unlike the ports above, this one does not default to a fixed value: it
/// reads whatever the host installed as [FlushScheduler.hostDefault]. Flush
/// timing is observable — a frame-scheduled flush lands inside the pump that
/// requested it, a microtask one lands before any pump at all — so a default
/// baked in here would quietly change streaming behaviour for every caller
/// that did not think to override it. `main.dart` and
/// `test/flutter_test_config.dart` both install the frame-callback version;
/// the daemon installs its own.
final flushSchedulerProvider = Provider<FlushScheduler>(
  (ref) => FlushScheduler.hostDefault,
);

/// Defers work out of the current build or frame.
///
/// Same shape as [flushSchedulerProvider] and for the same reason: whether
/// the callback lands after a frame or after a microtask is observable, so
/// the value comes from whatever the host installed rather than a default
/// baked in here.
final postFrameSchedulerProvider = Provider<PostFrameScheduler>(
  (ref) => PostFrameScheduler.hostDefault,
);

/// Extra providers a full sign-out must invalidate.
///
/// The core resets its own state directly, but it cannot name the app's
/// theme and locale providers: those resolve to `ThemeData` and `Locale`,
/// which is exactly why they live in the app rather than here. Naming them
/// anyway is what dragged the whole theme and localisation tree into the
/// core's dependency closure.
///
/// The host registers them instead. A host that registers nothing simply has
/// nothing extra to reset, which is true of the daemon.
final signOutResetTargetsProvider = Provider<List<ProviderOrFamily>>(
  (ref) => const <ProviderOrFamily>[],
);
