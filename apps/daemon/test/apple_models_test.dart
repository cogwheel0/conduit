@TestOn('vm')
library;

import 'dart:async';

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
import 'package:test/test.dart';

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
  _Window(this.bus, this.apple) {
    bus.attach('window', _deliver);
  }

  final EventBus bus;
  final AppleModelsService apple;
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
  AppleFailure? failure;
  int statusAsked = 0;
  final Map<String, Completer<void>> _toolAnswered =
      <String, Completer<void>>{};

  void detach() => bus.detach('window');

  void ready({required bool supported, List<String> runs = const []}) =>
      apple.report(
        AppleReport(
          kind: AppleReportKind.ready,
          supported: supported,
          runs: runs,
        ),
      );

  /// Ends a run held open.
  void finish(String runId) =>
      _report(AppleReport(kind: AppleReportKind.done, runId: runId));

  void _deliver(EventEnvelope envelope) {
    if (envelope.event != ConduitEvents.appleCommand) return;
    final command = AppleCommand.fromJson(envelope.payload);
    commands.add(command);
    scheduleMicrotask(() => _run(command));
  }

  void _report(AppleReport report) => apple.report(report);

  Future<void> _run(AppleCommand c) async {
    switch (c.kind) {
      case AppleCommandKind.status:
        statusAsked++;
        _report(AppleReport(id: c.id, status: engine));
      case AppleCommandKind.start:
        final runId = c.request!.runId;
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
