@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_core/features/chat/read_aloud/tts_manager.dart';
import 'package:conduit_core/features/chat/read_aloud/text_to_speech_controller.dart'
    show readAloudLiveDeviceSpeechProvider;
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart'
    show applePrivateCloudComputeSupportedProvider;
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/ports.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show ConnectivityService, connectivityServiceProvider;
import 'package:conduit_core/services/settings_service.dart'
    show AppSettingsHostDefaults;
import 'package:conduit_core/testing.dart' show FakeAppLifecycle;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduit_services/conduit_services.dart';
import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:hive_ce/hive.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:riverpod/riverpod.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'support/core.dart';

/// The services as a host other than the daemon builds them: over its
/// container, with its own system service, a session over an in-memory
/// channel, and no HTTP server.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('conduitd_composed');
    addTearDown(() => temporary.deleteSync(recursive: true));
  });

  /// The core over the desktop's stores; with [memoryDatabases], its
  /// account databases in memory.
  Future<void> startDesktop({bool memoryDatabases = false}) async {
    runtime = await startTestCore(
      temporary,
      databases: memoryDatabases ? _MemoryDatabases(temporary) : null,
    );
    addTearDown(runtime.dispose);
  }

  SystemService system() => SystemService(
    paths: testDaemonPaths,
    platform: 'ios',
    daemonVersion: '0.0.0-test',
    requestStop: (_) => fail('nothing here stops the host'),
  );

  /// Services stopped as the daemon stops them, after the test.
  ProtocolServices services({SystemService? reused}) {
    final services = ProtocolServices(
      events: EventBus(),
      system: reused ?? system(),
      ports: ProtocolHostPorts(window: runtime.window),
    );
    addTearDown(services.dispose);
    addTearDown(services.closeTransports);
    addTearDown(runtime.beginShutdown);
    return services;
  }

  json_rpc.Peer connect(ProtocolServices services) {
    final pipe = StreamChannelController<String>(sync: true);
    final session = services.openSession(pipe.local, sessionId: 'phone');
    addTearDown(session.close);
    unawaited(session.listen());
    final client = json_rpc.Peer(pipe.foreign);
    addTearDown(client.close);
    unawaited(client.listen());
    return client;
  }

  Future<void> handshakeAndAsk(json_rpc.Peer client) async {
    final handshake = HandshakeResponse.fromJson(
      await client.sendRequest(
        ConduitMethods.systemHandshake,
        const HandshakeRequest(
          protocolVersion: kConduitProtocolVersion,
          clientName: 'test',
          clientVersion: '0.0.0',
          windowKind: WindowKind.main,
          locale: 'en',
        ).toJson(),
      ) as Map<String, dynamic>,
    );
    expect(handshake.sessionId, 'phone');
    expect(handshake.platform, 'ios');
    expect(handshake.paths, testDaemonPaths);

    // A host that supplies no local speech engine offers none.
    final voice = VoiceSettings.fromJson(
      await client.sendRequest(ConduitMethods.voiceSettings)
          as Map<String, dynamic>,
    );
    expect(voice.localStt, isFalse);
  }

  test('a session handshakes and reaches the services', () async {
    await startDesktop();
    final built = services()..attach(runtime.container);
    await handshakeAndAsk(connect(built));
  });

  test('a build that fails part-way still stops what it built', () async {
    await startDesktop();
    // The host's system service fails as the last step.
    final built = services(reused: _RefusingSystem());

    expect(() => built.attach(runtime.container), throwsStateError);
    expect(built.isAttached, isFalse);
    expect(built.core.turns, isNull, reason: 'sessions see none of it');
    // The turns service was built and bound to the host's ports.
    expect(runtime.uiRequests.hermesChatOf, isNotNull);

    await built.closeTransports();
    await built.dispose();
    expect(runtime.uiRequests.hermesChatOf, isNull);
  });

  test(
    'sessions stop reaching services as soon as closing or disposing begins',
    () async {
      await startDesktop();
      final built = services()..attach(runtime.container);
      expect(built.core.terminals, isNotNull);

      // From the moment closing starts, not once it has finished: a
      // request meanwhile must not restart what is being closed.
      final closing = built.closeTransports();
      final core = built.core;
      expect(core.terminals, isNull);
      expect(core.computer, isNull);
      expect(core.calls, isNull);
      expect(core.speech, isNull);
      expect(core.data, isNull);
      expect(core.chats, isNotNull);
      await closing;

      final disposing = built.dispose();
      expect(built.core.chats, isNull);
      expect(built.core.turns, isNull);
      await disposing;
    },
  );

  test('a system service used again reports the new container\'s '
      'capabilities', () async {
    await startDesktop();
    final reused = system()
      ..capabilities = const Capabilities(notes: true, workspace: true);

    services(reused: reused).attach(runtime.container);

    expect(reused.capabilities, Capabilities.none);
  });

  test('a capabilities watcher whose first answer the host refuses is '
      'still stopped', () async {
    await startDesktop();
    final apple = runtime.container.read(appleOnDeviceAnswersProvider.notifier)
      ..set(true);
    final refusing = _RefusingSystem();
    final built = services(reused: refusing);

    expect(() => built.attach(runtime.container), throwsStateError);
    expect(refusing.offered.single.appleOnDeviceModels, isTrue);
    await built.closeTransports();
    await built.dispose();

    apple.set(false);
    await pumpEventQueue();
    expect(refusing.offered, hasLength(1));
  });

  test('once disposed, no session opens', () async {
    await startDesktop();
    final built = services()..attach(runtime.container);
    await built.closeTransports();
    await built.dispose();

    final pipe = StreamChannelController<String>(sync: true);
    expect(
      () => built.openSession(pipe.local, sessionId: 'late'),
      throwsStateError,
    );
  });

  test('once disposed, the core\'s questions no longer reach its '
      'windows', () async {
    await startDesktop();
    final built = services()..attach(runtime.container);
    final seen = <String>[];
    built.events.tap((event, _, _) => seen.add(event));
    await built.closeTransports();
    await built.dispose();
    seen.clear();

    runtime.uiRequests.notify(UiNoticeLevel.info, 'the tide turned');
    expect(seen, isEmpty);
  });

  test('services that began closing are not built', () async {
    await startDesktop();
    final closed = services();
    await closed.closeTransports();
    expect(() => closed.attach(runtime.container), throwsStateError);

    final disposed = services();
    await disposed.dispose();
    expect(() => disposed.attach(runtime.container), throwsStateError);
  });

  test('once disposed, the window ports the host keeps reach none of its '
      'windows', () async {
    await startDesktop();
    final built = services()..attach(runtime.container);
    built.events.attach('window', (_) {});
    await built.closeTransports();
    await built.dispose();

    expect(
      await runtime.openUrl.open(Uri.parse('https://example.com')),
      isFalse,
    );
    final asked = Map.of(runtime.location.sent);
    unawaited(runtime.location.isLocationServiceEnabled());
    expect(runtime.location.sent, asked);
  });

  test('once disposed, Hermes says nothing more to the windows', () async {
    await startDesktop();
    final built = services()..attach(runtime.container);
    final seen = <String>[];
    built.events.tap((event, _, _) => seen.add(event));
    await built.closeTransports();
    await built.dispose();
    seen.clear();

    // Show Scheduled Runs changes what Hermes' lists hold: live, the
    // service tells the windows to read them again.
    final settings = CoreSettingsService(runtime.container);
    await settings.set(
      AppSettingsPatch(
        hermesShowScheduledSessions: !settings
            .get()
            .hermesShowScheduledSessions,
      ),
    );
    await pumpEventQueue();
    expect(seen, isNot(contains(ConduitEvents.hermesChanged)));
  });

  test('a reading stopped as transports close lets go before closing waits '
      'for anything, takes no next sentence, and hears its window answer the '
      'stop, so closing does not wait out the timeout', () async {
    // Not about databases: on files, a rare late write in db/ at teardown
    // (cause unknown, older than this test) failed the directory's delete.
    await startDesktop(memoryDatabases: true);
    final built = services()..attach(runtime.container);
    final pipe = StreamChannelController<String>(sync: true);
    final session = built.openSession(pipe.local, sessionId: 'phone');
    addTearDown(session.close);
    unawaited(session.listen());
    final window = json_rpc.Peer(pipe.foreign);
    addTearDown(window.close);
    // The window's speech engine: it answers every command, and says what
    // it was asked to say and what the answer to the stop was.
    final said = <SpeechCommand>[];
    final spoke = Completer<void>();
    final stopAnswered = Completer<Object?>();
    registerEventSink(
      window,
      onEvent: (envelope) {
        if (envelope.event != ConduitEvents.speechCommand) return;
        final command = SpeechCommand.fromJson(envelope.payload);
        final answered = window.sendRequest(
          ConduitMethods.speechReport,
          SpeechReport(id: command.id, value: true).toJson(),
        );
        switch (command.kind) {
          case SpeechCommandKind.deviceSpeak:
            said.add(command);
            if (!spoke.isCompleted) spoke.complete();
          case SpeechCommandKind.deviceStop when !stopAnswered.isCompleted:
            answered.then(
              stopAnswered.complete,
              onError: (Object error) => stopAnswered.complete(error),
            );
          default:
        }
      },
    );
    unawaited(window.listen());
    await handshakeAndAsk(window);
    await window.sendRequest(
      ConduitMethods.eventsSubscribe,
      const EventSubscription().toJson(),
    );
    await window.sendRequest(
      ConduitMethods.speechPreview,
      const SpeechPreview(
        text:
            'The harbour lights come on one by one as the evening settles '
            'in. A small wooden boat drifts slowly past the green buoy near '
            'the pier.',
      ).toJson(),
    );
    await spoke.future;

    var closed = false;
    final closing = built.closeTransports().then((_) => closed = true);
    // Before closing has waited for anything (a call's stop can take
    // seconds), the reading is let go.
    expect(TtsManager.instance.isPlaying, isFalse);
    // The first sentence ends meanwhile.
    try {
      await window.sendRequest(
        ConduitMethods.speechReport,
        SpeechReport(
          kind: SpeechReportKind.complete,
          utterance: said.single.utterance,
        ).toJson(),
      );
    } on json_rpc.RpcException {
      // Refused once the reading has stopped: nothing to advance either way.
    }

    expect(
      await stopAnswered.future,
      isA<Map<dynamic, dynamic>>(),
      reason: "the window's answer to the stop was refused",
    );
    await pumpEventQueue();
    expect(closed, isTrue);
    await closing;
    expect(said, hasLength(1), reason: 'no next sentence after closing began');
    // Stopped: from here a report reaches nothing.
    expect(built.core.speechReports, isNull);
  });

  test('closing again after disposal shows sessions nothing', () async {
    await startDesktop();
    final built = services()..attach(runtime.container);
    await built.closeTransports();
    await built.dispose();

    await built.closeTransports();
    expect(built.core.chats, isNull);
  });

  test('a late ready from the Apple window reaches nothing of disposed '
      'services', () async {
    await startDesktop();
    final scoped = ProviderContainer(parent: runtime.container);
    final built = services(reused: _RefusingSystem());
    expect(() => built.attach(scoped), throwsStateError);
    await built.closeTransports();
    await built.dispose();
    scoped.dispose();

    expect(
      () => runtime.apple.report(
        const AppleReport(
          kind: AppleReportKind.ready,
          supported: true,
          order: 1,
        ),
        from: 'window',
      ),
      returnsNormally,
    );
  });

  test('over a host\'s own stores, lifecycle and policy', () async {
    // The phone's preferences are its own, not the desktop's file.
    PreferencesStore.debugReset();
    addTearDown(PreferencesStore.debugReset);
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    Hive.init('${temporary.path}/hive');
    Future<Box<dynamic>> box(String name) =>
        Hive.openBox<dynamic>('phone_$name');
    final boxes = <Box<dynamic>>[
      await box('preferences'),
      await box('caches'),
      await box('attachments'),
      await box('metadata'),
    ];
    final lifecycle = FakeAppLifecycle();
    runtime = await CoreRuntime.start(
      host: CoreHostBindings(
        secureStore: InMemorySecureKeyValueStore(),
        hiveBoxes: HiveBoxes(
          preferences: boxes[0],
          caches: boxes[1],
          attachmentQueue: boxes[2],
          metadata: boxes[3],
        ),
        databaseOpener: _MemoryDatabases(temporary),
        worker: const InlineWorkerPort(),
        connectivity: const AlwaysOnlineConnectivityPort(),
        lifecycle: lifecycle,
        close: () async {
          for (final box in boxes) {
            await box.close();
          }
          await lifecycle.dispose();
        },
      ),
      policy: const CoreHostPolicy(
        settingsDefaults: AppSettingsHostDefaults(),
        readAloudLiveDeviceSpeech: false,
      ),
    );
    addTearDown(runtime.dispose);
    final built = services()..attach(runtime.container);
    await handshakeAndAsk(connect(built));

    final container = runtime.container;
    // The window's Apple engine serves only the on-device model, so Private
    // Cloud Compute is never offered through it.
    expect(container.read(applePrivateCloudComputeSupportedProvider), isFalse);
    expect(container.read(readAloudLiveDeviceSpeechProvider), isFalse);

    // The core's connectivity checks stop in the background and start
    // again in the foreground, on the host's lifecycle.
    final watch = container.listen<ConnectivityService>(
      connectivityServiceProvider,
      (_, _) {},
    );
    addTearDown(watch.close);
    final connectivity = watch.read();
    expect(connectivity.debugHasScheduledHealthCheck, isTrue);
    lifecycle.emit(AppLifecyclePhase.paused);
    expect(connectivity.debugHasScheduledHealthCheck, isFalse);
    lifecycle.emit(AppLifecyclePhase.resumed);
    expect(connectivity.debugHasScheduledHealthCheck, isTrue);
  });
}

final class _RefusingSystem extends SystemService {
  _RefusingSystem()
    : super(
        paths: testDaemonPaths,
        platform: 'ios',
        daemonVersion: '0.0.0-test',
        requestStop: (_) {},
      );

  /// What the services offered it, refused each time.
  final List<Capabilities> offered = <Capabilities>[];

  @override
  set capabilities(Capabilities value) {
    offered.add(value);
    throw StateError('refused');
  }
}

/// The account databases in memory.
final class _MemoryDatabases implements DatabaseOpenerPort {
  _MemoryDatabases(this._directory);

  final Directory _directory;

  @override
  QueryExecutor open(String serverId) => NativeDatabase.memory();

  @override
  Future<Directory> databaseDirectory() async => _directory;
}
