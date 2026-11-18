@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/apple_pcc_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/apple_pcc_adapter.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'support/null_sink.dart';

/// Apple's on-device model runs in the window; the chat runs here, in the
/// core's Direct engine and Apple adapter. A fake window answers
/// `apple.command` as the desktop app's Foundation Models engine does.
void main() {
  late EventBus bus;
  late ProviderContainer container;
  late AppleModelsBridge bridge;
  late AppleModelsService apple;
  late _Window window;

  setUp(() async {
    // A fresh store each test: one test's preferences (Private Cloud
    // Compute switched on, say) never reach the next.
    PreferencesStore.debugReset();
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    bus = EventBus();
    bridge = AppleModelsBridge(timeout: const Duration(seconds: 2));
    container = ProviderContainer(overrides: appleModelsOverrides(bridge));
    bridge.bind(bus);
    apple = AppleModelsService(container, bridge: bridge);
    window = _Window(bus, apple);
  });

  tearDown(() => container.dispose());

  Future<List<String>> offered() async => (await container.read(
    effectiveDirectConnectionProfilesFutureProvider.future,
  )).map((profile) => profile.id).toList();

  /// Completes once the offer says [want]: a listener on the offer,
  /// registered now, never a poll.
  Future<void> answers(bool want) {
    final reached = Completer<void>();
    final listener = container.listen<bool>(appleOnDeviceAnswersProvider, (
      _,
      next,
    ) {
      if (next == want && !reached.isCompleted) reached.complete();
    }, fireImmediately: true);
    return reached.future.whenComplete(listener.close);
  }

  DirectCompletionRequest ask(String text) => DirectCompletionRequest(
    remoteModelId: kAppleOnDeviceRemoteModelId,
    messages: <DirectChatMessage>[
      DirectChatMessage.text(role: 'system', text: 'Answer briefly.'),
      DirectChatMessage.text(role: 'user', text: text),
    ],
    parameters: const <String, dynamic>{'temperature': 0.3},
  );

  test(
    'no Apple model is offered before a window says the Mac has one',
    () async {
      expect(await offered(), isEmpty);
      final status = await apple.status();
      expect(status.models.single.model, AppleModelKind.onDevice);
      expect(status.models.single.availability, AppleAvailability.unavailable);
      expect(status.models.single.reason, AppleUnavailableReason.noEngine);
      expect(window.commands, isEmpty, reason: 'nothing asked of no engine');
    },
  );

  test(
    'a Mac with Apple Intelligence offers Apple On-Device with its context',
    () async {
      window.ready(supported: true);
      await window.until(() => container.read(appleOnDeviceAnswersProvider));
      expect(await offered(), <String>[kAppleOnDeviceProfileId]);

      final status = await apple.status();
      final onDevice = status.models.single;
      expect(onDevice.availability, AppleAvailability.available);
      expect(onDevice.reason, isNull);
      expect(onDevice.contextSize, 4096);
      expect(onDevice.supportsCurrentLocale, isTrue);

      final models = await container
          .read(applePccAdapterProvider)
          .listModels(DirectConnectionProfile.appleOnDevice());
      expect(models.single.id, kAppleOnDeviceRemoteModelId);
      expect(models.single.name, 'Apple On-Device');
      expect(models.single.capabilities['context_length'], 4096);
      expect(models.single.capabilities['reasoning'], isFalse);
    },
  );

  test('an unready model says why, and Refresh asks the Mac again', () async {
    window.engine = const AppleEngineStatus(
      availability: AppleAvailability.unavailable,
      reason: AppleUnavailableReason.modelNotReady,
      supportsCurrentLocale: true,
    );
    window.ready(supported: true);
    var onDevice = (await apple.status()).models.single;
    expect(onDevice.availability, AppleAvailability.unavailable);
    expect(onDevice.reason, AppleUnavailableReason.modelNotReady);
    // Not offered while it cannot answer: no connection to fall back on,
    // no model in the picker.
    expect(await offered(), isEmpty);
    await expectLater(
      container
          .read(applePccAdapterProvider)
          .listModels(DirectConnectionProfile.appleOnDevice()),
      throwsA(
        isA<DirectProviderException>().having(
          (e) => e.message,
          'message',
          'The Apple on-device model is still downloading or not ready.',
        ),
      ),
    );

    window.engine = const AppleEngineStatus(
      availability: AppleAvailability.available,
      contextSize: 4096,
    );
    final asked = window.statusAsked;
    onDevice = (await apple.refresh()).models.single;
    expect(window.statusAsked, greaterThan(asked));
    expect(onDevice.availability, AppleAvailability.available);
    expect(await offered(), <String>[kAppleOnDeviceProfileId]);
  });

  test('a status asked before the window changed its answer never offers '
      'the model', () async {
    final held = window.holdStatus = Completer<void>();
    window.ready(supported: true);
    await window.until(() => window.statusAsked > 0);
    // Asked of the engine; meanwhile the window says this Mac has none.
    window.ready(supported: false);
    held.complete();
    await window.until(() => window.statusAnswered > 0);
    await pumpEventQueue();
    expect(container.read(appleOnDeviceAnswersProvider), isFalse);
    expect(await offered(), isEmpty);
  });

  test('an older macOS keeps the model out and says so', () async {
    window.ready(supported: false);
    expect(await offered(), isEmpty);
    final onDevice = (await apple.status()).models.single;
    expect(onDevice.availability, AppleAvailability.unsupported);
    expect(onDevice.reason, AppleUnavailableReason.systemTooOld);
  });

  test('Private Cloud Compute is never offered or asked for', () async {
    await PreferencesStore.put(PreferenceKeys.applePccEnabled, true);
    window.ready(supported: true);
    await window.until(() => container.read(appleOnDeviceAnswersProvider));
    expect(await offered(), <String>[kAppleOnDeviceProfileId]);
    final pcc = await container.read(applePccStatusProvider.future);
    expect(pcc.availability, PlatformPccAvailability.unsupported);
    expect(
      window.commands.where(
        (c) => c.model == AppleModelKind.privateCloudCompute,
      ),
      isEmpty,
    );
    expect((await apple.status()).models.map((m) => m.model), <AppleModelKind>[
      AppleModelKind.onDevice,
    ]);
  });

  test('a reply streams from the window and ends', () async {
    window.ready(supported: true);
    window.reply = const <String>['Thyme, ', 'rosemary ', 'and sage.'];
    final run = container
        .read(applePccAdapterProvider)
        .startCompletion(
          DirectConnectionProfile.appleOnDevice(),
          ask('Name three hardy herbs.'),
        );
    final events = await run.events.toList();
    final text = events.whereType<DirectContentDelta>().map((e) => e.content);
    expect(text.join(), 'Thyme, rosemary and sage.');
    expect(events.whereType<DirectUsageUpdate>().single.usage, <String, int>{
      'prompt_tokens': 12,
      'completion_tokens': 7,
      'total_tokens': 19,
    });
    expect(events.last, isA<DirectStreamDone>());

    final start = window.commands.firstWhere(
      (c) => c.kind == AppleCommandKind.start,
    );
    final request = start.request!;
    expect(request.model, AppleModelKind.onDevice);
    expect(request.messages.map((m) => m.role), <String>['system', 'user']);
    expect(request.messages.last.content, 'Name three hardy herbs.');
    expect(request.temperature, 0.3);
  });

  test('Stop cancels the run in the window', () async {
    window.ready(supported: true);
    window.reply = const <String>['Slowly '];
    window.holdOpen = true;
    final run = container
        .read(applePccAdapterProvider)
        .startCompletion(
          DirectConnectionProfile.appleOnDevice(),
          ask('Tell me a long story.'),
        );
    final events = <DirectStreamEvent>[];
    final done = run.events.listen(events.add).asFuture<void>();
    await window.until(() => events.whereType<DirectContentDelta>().isNotEmpty);
    unawaited(run.cancel('stop'));
    await done.timeout(const Duration(seconds: 2));
    await window.until(
      () => window.commands.any((c) => c.kind == AppleCommandKind.cancel),
    );
    expect(window.cancelled, <String>[run.id]);
    expect(events.whereType<DirectStreamError>(), isEmpty);
  });

  test("the window's failure reads as the phone's", () async {
    window.ready(supported: true);
    window.failure = AppleFailure.contextExceeded;
    final run = container
        .read(applePccAdapterProvider)
        .startCompletion(
          DirectConnectionProfile.appleOnDevice(),
          ask('A very long conversation.'),
        );
    final events = await run.events.toList();
    final error = events.whereType<DirectStreamError>().single;
    expect(
      error.message,
      'This conversation exceeds the Apple On-Device context limit.',
    );
  });

  test('a run that says the model cannot answer asks the Mac again, so the '
      'offer follows; another failure leaves it', () async {
    final offeredNow = answers(true);
    window.ready(supported: true);
    await offeredNow;
    Future<void> run(String text) => container
        .read(applePccAdapterProvider)
        .startCompletion(DirectConnectionProfile.appleOnDevice(), ask(text))
        .events
        .drain<void>();

    window.failure = AppleFailure.contextExceeded;
    final asked = window.statusAsked;
    await run('A very long conversation.');
    await pumpEventQueue();
    expect(window.statusAsked, asked, reason: 'a full context is not the Mac');
    expect(container.read(appleOnDeviceAnswersProvider), isTrue);

    // Apple Intelligence was turned off since the last ask.
    window.engine = const AppleEngineStatus(
      availability: AppleAvailability.unavailable,
      reason: AppleUnavailableReason.appleIntelligenceNotEnabled,
    );
    window.failure = AppleFailure.unavailable;
    final withdrawn = answers(false);
    await run('Name three hardy herbs.');
    await withdrawn;
    expect(window.statusAsked, greaterThan(asked), reason: 'not asked again');
    expect(container.read(appleOnDeviceAnswersProvider), isFalse);
  });

  test("a tool call is answered back to the window's run", () async {
    window.ready(supported: true);
    window.toolCall = true;
    final run = container
        .read(applePccAdapterProvider)
        .startCompletion(
          DirectConnectionProfile.appleOnDevice(),
          ask('Look up thyme.'),
        );
    final events = await run.events.toList();
    expect(events.last, isA<DirectStreamDone>());
    final result = window.commands.singleWhere(
      (c) => c.kind == AppleCommandKind.toolResult,
    );
    expect(result.runId, run.id);
    expect(result.callId, 'call-1');
    // This run has no tools: the core ends the model's tool loop.
    expect(result.toolCancelled, isTrue);
  });

  test(
    'a socket that comes back keeps the runs the engine still has',
    () async {
      window.ready(supported: true);
      window.reply = const <String>['Half '];
      window.holdOpen = true;
      final run = container
          .read(applePccAdapterProvider)
          .startCompletion(
            DirectConnectionProfile.appleOnDevice(),
            ask('Keep going.'),
          );
      final events = <DirectStreamEvent>[];
      final done = run.events.listen(events.add).asFuture<void>();
      await window.until(
        () => events.whereType<DirectContentDelta>().isNotEmpty,
      );
      window.ready(supported: true, runs: <String>[run.id]);
      await pumpEventQueue();
      expect(events.whereType<DirectStreamError>(), isEmpty);
      window.finish(run.id);
      await done.timeout(const Duration(seconds: 2));
      expect(events.last, isA<DirectStreamDone>());
    },
  );

  test('a window without the run ends it', () async {
    window.ready(supported: true);
    window.reply = const <String>['Half '];
    window.holdOpen = true;
    final run = container
        .read(applePccAdapterProvider)
        .startCompletion(
          DirectConnectionProfile.appleOnDevice(),
          ask('Keep going.'),
        );
    final events = <DirectStreamEvent>[];
    final done = run.events.listen(events.add).asFuture<void>();
    await window.until(() => events.whereType<DirectContentDelta>().isNotEmpty);
    window.ready(supported: true);
    await done.timeout(const Duration(seconds: 2));
    expect(
      events.whereType<DirectStreamError>().single.message,
      'Apple On-Device request failed.',
    );
  });

  test('a ready said again while a start is on its way keeps that run: the '
      'window cannot list it yet', () async {
    window.ready(supported: true);
    window.reply = const <String>['Basil.'];
    final held = window.holdStart = Completer<void>();
    final run = container
        .read(applePccAdapterProvider)
        .startCompletion(
          DirectConnectionProfile.appleOnDevice(),
          ask('Name one tender herb.'),
        );
    final events = <DirectStreamEvent>[];
    final done = run.events.listen(events.add).asFuture<void>();
    await window.until(
      () => window.commands.any((c) => c.kind == AppleCommandKind.start),
    );
    // Events were lost: the window says ready with the runs it has, and it
    // has not taken the start yet.
    window.ready(supported: true);
    await pumpEventQueue();
    held.complete();
    await done;
    expect(events.whereType<DirectStreamError>(), isEmpty);
    expect(
      events.whereType<DirectContentDelta>().map((e) => e.content).join(),
      'Basil.',
    );
    expect(events.last, isA<DirectStreamDone>());
    expect(window.cancelled, isEmpty);
  });

  test('a ready sent before a start was answered, delivered again after it, '
      'never ends that run', () async {
    window.ready(supported: true);
    // Numbered now; the connection delivers it again once the run started.
    final stale = window.readyReport(supported: true);
    window.reply = const <String>['Slowly '];
    window.holdOpen = true;
    final run = container
        .read(applePccAdapterProvider)
        .startCompletion(
          DirectConnectionProfile.appleOnDevice(),
          ask('Tell me a long story.'),
        );
    final events = <DirectStreamEvent>[];
    final done = run.events.listen(events.add).asFuture<void>();
    await window.until(() => events.whereType<DirectContentDelta>().isNotEmpty);
    window.resend(stale);
    await pumpEventQueue();
    window.finish(run.id);
    await done;
    expect(events.whereType<DirectStreamError>(), isEmpty);
    expect(events.last, isA<DirectStreamDone>());
  });

  test('a Cancel lost on the way is sent again when the window says ready '
      'still holding the run', () async {
    window.ready(supported: true);
    window.reply = const <String>['Slowly '];
    window.holdOpen = true;
    final run = container
        .read(applePccAdapterProvider)
        .startCompletion(
          DirectConnectionProfile.appleOnDevice(),
          ask('Tell me a long story.'),
        );
    final events = <DirectStreamEvent>[];
    final done = run.events.listen(events.add).asFuture<void>();
    await window.until(() => events.whereType<DirectContentDelta>().isNotEmpty);
    window.dropCancels = 1;
    unawaited(run.cancel('stop'));
    await window.until(() => window.lost.isNotEmpty);
    expect(window.cancelled, isEmpty, reason: 'that Cancel never arrived');
    // The window, after the gap, still has the run.
    window.ready(supported: true, runs: <String>[run.id]);
    await window.until(() => window.cancelled.isNotEmpty);
    expect(window.cancelled, <String>[run.id]);
    window.answerLost();
    await done;
    expect(events.whereType<DirectStreamError>(), isEmpty);
  });

  test('with two windows, one engine runs a request: the last to say '
      'ready', () async {
    final other = _Window(bus, apple, id: 'other');
    window.ready(supported: true);
    other.ready(supported: true);
    window.reply = const <String>['From the first window.'];
    other.reply = const <String>['From the second window.'];
    final run = container
        .read(applePccAdapterProvider)
        .startCompletion(
          DirectConnectionProfile.appleOnDevice(),
          ask('Name a herb.'),
        );
    final events = await run.events.toList();
    expect(
      window.commands.where((c) => c.kind == AppleCommandKind.start),
      isEmpty,
    );
    expect(
      other.commands.where((c) => c.kind == AppleCommandKind.start),
      hasLength(1),
    );
    final text = events.whereType<DirectContentDelta>().map((e) => e.content);
    expect(text.join(), 'From the second window.');
    expect(events.last, isA<DirectStreamDone>());
  });

  test("a window's report for a run it does not run is ignored", () async {
    final other = _Window(bus, apple, id: 'other');
    window.ready(supported: true);
    window.reply = const <String>['Basil.'];
    window.holdOpen = true;
    final run = container
        .read(applePccAdapterProvider)
        .startCompletion(
          DirectConnectionProfile.appleOnDevice(),
          ask('Name a herb.'),
        );
    final events = <DirectStreamEvent>[];
    final done = run.events.listen(events.add).asFuture<void>();
    await window.until(() => events.whereType<DirectContentDelta>().isNotEmpty);
    other.sendRaw(
      AppleReport(
        kind: AppleReportKind.content,
        runId: run.id,
        content: ' Forged.',
        seq: 2,
      ),
    );
    other.sendRaw(
      AppleReport(kind: AppleReportKind.done, runId: run.id, seq: 3),
    );
    await pumpEventQueue();
    expect(events.whereType<DirectStreamDone>(), isEmpty);
    window.finish(run.id);
    await done;
    final text = events.whereType<DirectContentDelta>().map((e) => e.content);
    expect(text.join(), 'Basil.');
    expect(events.last, isA<DirectStreamDone>());
  });

  test('a report lost on the way ends the run and stops it in the window, '
      'rather than keep a reply with words missing', () async {
    window.ready(supported: true);
    window.reply = const <String>['One ', 'two ', 'three.'];
    window.holdOpen = true;
    final run = container
        .read(applePccAdapterProvider)
        .startCompletion(
          DirectConnectionProfile.appleOnDevice(),
          ask('Count to three.'),
        );
    final events = <DirectStreamEvent>[];
    final done = run.events.listen(events.add).asFuture<void>();
    await window.until(
      () => events.whereType<DirectContentDelta>().length >= 3,
    );
    window.lose = 1;
    window.finish(run.id);
    await done;
    expect(events.whereType<DirectStreamDone>(), isEmpty);
    expect(
      events.whereType<DirectStreamError>().single.message,
      'Apple On-Device request failed.',
    );
    await window.until(() => window.cancelled.contains(run.id));
  });

  test('a window that goes ends its runs: the turn gets its failure, and '
      'nothing of the run is kept', () async {
    final other = _Window(bus, apple, id: 'other');
    other.ready(supported: false);
    window.ready(supported: true);
    window.reply = const <String>['Half '];
    window.holdOpen = true;
    final run = container
        .read(applePccAdapterProvider)
        .startCompletion(
          DirectConnectionProfile.appleOnDevice(),
          ask('Keep going.'),
        );
    final events = <DirectStreamEvent>[];
    final done = run.events.listen(events.add).asFuture<void>();
    await window.until(() => events.whereType<DirectContentDelta>().isNotEmpty);
    window.detach();
    await done;
    expect(
      events.whereType<DirectStreamError>().single.message,
      'Apple On-Device request failed.',
    );
    // Nothing kept: a report for it counts from no one, and Stop asks no
    // window.
    other.sendRaw(
      AppleReport(kind: AppleReportKind.content, runId: run.id, seq: 2),
    );
    await run.cancel('stop');
    await pumpEventQueue();
    expect(
      other.commands.where((c) => c.kind == AppleCommandKind.cancel),
      isEmpty,
    );
    expect(events.whereType<DirectContentDelta>(), hasLength(1));
  });

  test('the only engine going takes the model out of the offer', () async {
    window.ready(supported: true);
    await window.until(() => container.read(appleOnDeviceAnswersProvider));
    expect(await offered(), <String>[kAppleOnDeviceProfileId]);
    window.detach();
    await pumpEventQueue();
    expect(container.read(appleOnDeviceAnswersProvider), isFalse);
    expect(await offered(), isEmpty);
  });

  test('a tool result the window cannot be given ends the run, and the '
      'window is told to stop it when it comes back', () async {
    window.ready(supported: true);
    window.toolCall = true;
    window.detachAfterToolCall = true;
    final run = container
        .read(applePccAdapterProvider)
        .startCompletion(
          DirectConnectionProfile.appleOnDevice(),
          ask('Look up thyme.'),
        );
    final events = await run.events.toList();
    expect(
      events.whereType<DirectStreamError>().single.message,
      'Apple On-Device request failed.',
    );
    // The engine, still waiting on that call, comes back with the run.
    final back = _Window(bus, apple, id: 'window-2');
    back.ready(supported: true, runs: <String>[run.id]);
    await back.until(() => back.cancelled.contains(run.id));
  });

  group('a window whose socket just goes away', () {
    late Directory temporary;
    late StreamChannelController<String> pipe;
    late RpcSession session;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('conduitd_apple_drop');
      final log = DaemonLog(level: 'error', sink: NullSink());
      pipe = StreamChannelController<String>(sync: true);
      // The window's daemon session, as DaemonServer makes one per socket.
      session = RpcSession(
        sessionId: window.id,
        channel: pipe.local,
        system: SystemService(
          directories: DaemonDirectories.create(temporary.path),
          daemonVersion: '0.0.0-test',
          log: log,
          requestStop: (_) => fail('nothing here stops the daemon'),
        ),
        events: bus,
        log: log,
        services: () => CoreServices(apple: apple),
      );
      // The session's own fan-out stands in for the window's socket; the
      // fake engine keeps hearing the commands.
      bus.attach(window.id, window._deliver);
    });

    tearDown(() => temporary.delete(recursive: true));

    test('is cleaned up as one that closed: its turn ends, and the window '
        'that comes back runs the next one', () async {
      final listening = session.listen();
      window.ready(supported: true);
      window.reply = const <String>['Half '];
      window.holdOpen = true;
      final run = container
          .read(applePccAdapterProvider)
          .startCompletion(
            DirectConnectionProfile.appleOnDevice(),
            ask('Keep going.'),
          );
      final events = <DirectStreamEvent>[];
      var finished = false;
      run.events.listen(events.add, onDone: () => finished = true);
      await window.until(
        () => events.whereType<DirectContentDelta>().isNotEmpty,
      );

      // The socket drops: no close(), the stream just ends.
      await pipe.foreign.sink.close();
      await listening;
      await window.until(() => finished);
      expect(events.last, isA<DirectStreamError>());

      // The same engine on its new session, still holding the old run: it
      // is told to stop it, and runs the next turn.
      final back = _Window(bus, apple, id: 'window-2');
      back.ready(supported: true, runs: <String>[run.id]);
      await back.until(() => back.cancelled.contains(run.id));
      back.reply = const <String>['All of it.'];
      final next = await container
          .read(applePccAdapterProvider)
          .startCompletion(
            DirectConnectionProfile.appleOnDevice(),
            ask('Again.'),
          )
          .events
          .toList();
      final text = next.whereType<DirectContentDelta>().map((e) => e.content);
      expect(text.join(), 'All of it.');
      expect(next.last, isA<DirectStreamDone>());
    });

    test('closing twice, or after the socket went, is harmless', () async {
      final listening = session.listen();
      await pipe.foreign.sink.close();
      await listening;
      await session.close();
      await session.close();
    });
  });

  test('a turn with no window to run it fails rather than waits', () async {
    window.ready(supported: true);
    window.detach();
    final run = container
        .read(applePccAdapterProvider)
        .startCompletion(
          DirectConnectionProfile.appleOnDevice(),
          ask('Anyone there?'),
        );
    final events = await run.events.toList().timeout(
      const Duration(seconds: 2),
    );
    expect(
      events.whereType<DirectStreamError>().single.message,
      'Apple On-Device could not start the request.',
    );
  });
}

/// The desktop app's Foundation Models engine, as the daemon sees it.
final class _Window {
  _Window(this.bus, this.apple, {this.id = 'window'}) {
    bus.attach(id, _deliver);
  }

  final EventBus bus;
  final AppleModelsService apple;

  /// Its daemon session.
  final String id;

  /// The next number of each run's reports, as the desktop numbers them.
  final Map<String, int> _numbers = <String, int>{};

  /// Skips this many numbers before the run's next report (a report lost
  /// on the way).
  int lose = 0;
  final commands = <AppleCommand>[];
  final cancelled = <String>[];
  AppleEngineStatus engine = const AppleEngineStatus(
    availability: AppleAvailability.available,
    contextSize: 4096,
    supportsCurrentLocale: true,
  );
  List<String> reply = const <String>['Yes.'];
  bool holdOpen = false;
  bool toolCall = false;

  /// The socket drops right after the tool call is reported, while the
  /// core works out its answer.
  bool detachAfterToolCall = false;
  AppleFailure? failure;
  int statusAsked = 0;
  int statusAnswered = 0;

  /// Holds status answers back until it completes.
  Completer<void>? holdStatus;

  /// Holds a start back, untaken (no run, no answer), until it completes.
  Completer<void>? holdStart;

  /// Drops this many Cancel commands, as if lost on the way: they are kept
  /// in [lost], unanswered.
  int dropCancels = 0;
  final lost = <AppleCommand>[];

  /// Answers the dropped commands at last, so nothing waits on them.
  void answerLost() {
    for (final c in lost) {
      _report(AppleReport(id: c.id));
    }
    lost.clear();
  }

  final Map<String, Completer<void>> _toolAnswered =
      <String, Completer<void>>{};

  /// The window's session closes.
  void detach() {
    bus.detach(id);
    apple.forgetWindow(id);
  }

  void ready({required bool supported, List<String> runs = const []}) =>
      resend(readyReport(supported: supported, runs: runs));

  /// A `ready` numbered now, as the window sends it, for [resend] to deliver
  /// (again) later, as the connection does with a send tried again.
  AppleReport readyReport({
    required bool supported,
    List<String> runs = const [],
  }) => AppleReport(
    kind: AppleReportKind.ready,
    supported: supported,
    runs: runs,
    order: ++_order,
  );

  /// Delivers [report] as it was numbered.
  void resend(AppleReport report) => apple.report(report, from: id);

  /// The number of the last report this window sent.
  int _order = 0;

  /// Ends a run held open.
  void finish(String runId) =>
      _report(AppleReport(kind: AppleReportKind.done, runId: runId));

  void _deliver(EventEnvelope envelope) {
    if (envelope.event != ConduitEvents.appleCommand) return;
    final command = AppleCommand.fromJson(envelope.payload);
    commands.add(command);
    scheduleMicrotask(() => _run(command));
  }

  void _report(AppleReport report) {
    final runId = report.runId;
    if (report.kind != null &&
        report.kind != AppleReportKind.ready &&
        runId != null) {
      final number = (_numbers[runId] ?? 0) + 1 + lose;
      lose = 0;
      _numbers[runId] = number;
      report = report.copyWith(seq: number);
    }
    apple.report(report.copyWith(order: ++_order), from: id);
  }

  /// A report this window did not number in order: another window's run,
  /// or a forged one.
  void sendRaw(AppleReport report) => apple.report(report, from: id);

  Future<void> _run(AppleCommand c) async {
    switch (c.kind) {
      case AppleCommandKind.status:
        statusAsked++;
        final status = engine;
        if (holdStatus case final hold?) await hold.future;
        statusAnswered++;
        _report(AppleReport(id: c.id, status: status));
      case AppleCommandKind.start:
        final runId = c.request!.runId;
        if (holdStart case final hold?) await hold.future;
        _report(AppleReport(id: c.id));
        if (failure case final failure?) {
          _report(
            AppleReport(
              kind: AppleReportKind.failed,
              runId: runId,
              failure: failure,
            ),
          );
          return;
        }
        if (toolCall) {
          final answered = _toolAnswered[runId] = Completer<void>();
          _report(
            AppleReport(
              kind: AppleReportKind.toolCall,
              runId: runId,
              callId: 'call-1',
              toolName: 'garden_lookup',
              argumentsJson: '{"plant":"thyme"}',
            ),
          );
          if (detachAfterToolCall) {
            detach();
            return;
          }
          await answered.future;
        }
        for (final part in reply) {
          _report(
            AppleReport(
              kind: AppleReportKind.content,
              runId: runId,
              content: part,
            ),
          );
        }
        if (holdOpen) return;
        _report(
          AppleReport(
            kind: AppleReportKind.usage,
            runId: runId,
            inputTokens: 12,
            outputTokens: 7,
            totalTokens: 19,
          ),
        );
        _report(AppleReport(kind: AppleReportKind.done, runId: runId));
      case AppleCommandKind.cancel:
        if (dropCancels > 0) {
          dropCancels--;
          lost.add(c);
          return;
        }
        cancelled.add(c.runId!);
        _report(AppleReport(id: c.id));
        _report(AppleReport(kind: AppleReportKind.done, runId: c.runId));
      case AppleCommandKind.toolResult:
        _report(AppleReport(id: c.id));
        _toolAnswered.remove(c.runId)?.complete();
    }
  }

  /// Lets the event queue run until [condition] holds: a bounded number of
  /// turns, never a clock.
  Future<void> until(bool Function() condition) async {
    for (var turn = 0; turn < 50; turn++) {
      if (condition()) return;
      await pumpEventQueue();
    }
    if (!condition()) throw StateError('condition not met');
  }
}
