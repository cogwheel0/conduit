@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_core/features/chat/read_aloud/device_speech_engine.dart'
    show DeviceSpeechEngine, NoDeviceSpeech;
import 'package:conduit_core/features/chat/read_aloud/tts_manager.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart'
    show currentUserProvider2;
import 'package:conduit_core/features/channels/providers/channel_providers.dart'
    show ChannelsList, channelsListProvider;
import 'package:conduit_core/features/chat/voice_mode/voice_mode_ports.dart'
    show voiceModeInputProvider;
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/socket_health.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show
        SettledActiveAccountId,
        settledActiveAccountIdProvider,
        socketServiceProvider;
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/features/direct_connections/providers/apple_pcc_providers.dart'
    show applePccHostProvider;
import 'package:conduit_core/providers/host_ports.dart'
    show cookieJarProvider, openExternalUrlProvider, uiRequestPortProvider;
import 'package:conduit_core/features/chat/read_aloud/text_to_speech_controller.dart'
    show readAloudLiveDeviceSpeechProvider;
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart'
    show applePrivateCloudComputeSupportedProvider;
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/ports.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show ConnectivityService, connectivityServiceProvider;
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart'
    show DirectModelId;
import 'package:conduit_core/providers/backend_mode_providers.dart'
    show PreferredBackend, preferredBackendProvider;
import 'package:conduit_core/services/settings_service.dart'
    show AppSettingsHostDefaults, VoiceCallMode, appSettingsProvider;
import 'package:conduit_core/testing.dart' show FakeAppLifecycle;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduit_services/conduit_services.dart';
import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:hive_ce/hive.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:riverpod/riverpod.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'support/core.dart';
import 'support/scripted_openai.dart';

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

  test('once disposed, no service says anything more to the windows, '
      'whatever changes in the container they watched, or finishes '
      'afterwards', () async {
    final store = _HeldWrites();
    runtime = await startTestCore(temporary, preferences: store);
    addTearDown(runtime.dispose);
    final built = services()..attach(runtime.container);
    final seen = <String>[];
    built.events.tap((event, _, _) => seen.add(event));
    // A settings change still saving when the services stop.
    final shown = built.coreSettings.get().hermesShowScheduledSessions;
    final saved = store.hold();
    final saving = built.coreSettings.set(
      AppSettingsPatch(hermesShowScheduledSessions: !shown),
    );
    await store.held.future;
    await built.closeTransports();
    await built.dispose();
    seen.clear();
    saved.complete();
    await saving;

    final container = runtime.container;
    // Settings (Show Scheduled Runs also changes what Hermes' lists hold).
    final settings = CoreSettingsService(container);
    await settings.set(
      AppSettingsPatch(
        hermesShowScheduledSessions: shown,
        sendOnEnter: !settings.get().sendOnEnter,
      ),
    );
    // A Direct connection, and with it the models and the backend in use.
    await DirectService(container).save(
      const DirectConnectionEdit(
        name: 'Tide tables',
        kind: DirectKind.openai,
        baseUrl: 'http://127.0.0.1:9/v1',
        manualModelIds: <String>['harbour-small'],
      ),
    );
    await container
        .read(preferredBackendProvider.notifier)
        .set(PreferredBackend.direct);
    // Apple's on-device model.
    container.read(appleOnDeviceAnswersProvider.notifier).set(true);
    for (var turn = 0; turn < 5; turn++) {
      await pumpEventQueue();
    }

    expect(seen, isEmpty);
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

  test('a call still starting as transports close hears its window '
      'answer, so closing does not wait out the stop', () async {
    await startDesktop();
    final provider = await ScriptedOpenAi.start();
    addTearDown(provider.close);
    final saved = await DirectService(runtime.container).save(
      DirectConnectionEdit(
        name: 'Scripted',
        kind: DirectKind.openai,
        baseUrl: provider.baseUrl,
        manualModelIds: const <String>['scripted-model'],
      ),
    );
    final model = DirectModelId.encode(
      saved.connections.single.id,
      'scripted-model',
    );
    await runtime.container
        .read(appSettingsProvider.notifier)
        .setVoiceCallMode(VoiceCallMode.standard);
    final built = services()..attach(runtime.container);
    final pipe = StreamChannelController<String>(sync: true);
    final session = built.openSession(pipe.local, sessionId: 'phone');
    addTearDown(session.close);
    unawaited(session.listen());
    final window = json_rpc.Peer(pipe.foreign);
    addTearDown(window.close);
    // The window's microphone prompt is still up: the call waits for it.
    final asked = Completer<CallCommand>();
    var closingBegan = false;
    final afterClosing = <CallCommandKind>[];
    registerEventSink(
      window,
      onEvent: (envelope) {
        if (envelope.event != ConduitEvents.callsCommand) return;
        final command = CallCommand.fromJson(envelope.payload);
        if (closingBegan) afterClosing.add(command.kind);
        if (command.kind == CallCommandKind.permission && !asked.isCompleted) {
          asked.complete(command);
        }
      },
    );
    unawaited(window.listen());
    await handshakeAndAsk(window);
    await window.sendRequest(
      ConduitMethods.eventsSubscribe,
      const EventSubscription().toJson(),
    );
    unawaited(
      window
          .sendRequest(
            ConduitMethods.callsStart,
            CallStart(model: model).toJson(),
          )
          .then<void>((_) {}, onError: (Object _) {}),
    );
    final permission = await asked.future;

    var closed = false;
    closingBegan = true;
    final closing = built.closeTransports().then((_) => closed = true);
    // The user answers the prompt while closing waits for the call.
    final answered = await window.sendRequest(
      ConduitMethods.callsReport,
      CallReport(id: permission.id, value: true).toJson(),
    );

    expect(answered, isA<Map<dynamic, dynamic>>());
    await closing;
    expect(closed, isTrue);
    // The answer ends the start; the microphone never opens.
    expect(afterClosing, isNot(contains(CallCommandKind.listen)));
    // Stopped: from here a report reaches nothing.
    expect(built.core.callsReports, isNull);
  });

  test('over a container an app shares, the app keeps its read-aloud, '
      'calls, Apple models and location: nothing it installed is replaced, '
      'and those namespaces say this host does not offer them', () async {
    await startDesktop();
    // The app's container, with its own ports bound and its own engines
    // installed process-wide before the services come.
    final container = runtime.container;
    final previousPlayback = AudioPlaybackPort.hostFactory;
    final previousDevice = DeviceSpeechEngine.hostFactory;
    final previousClips = TtsManager.clipStore;
    addTearDown(() {
      AudioPlaybackPort.hostFactory = previousPlayback;
      DeviceSpeechEngine.hostFactory = previousDevice;
      TtsManager.clipStore = previousClips;
    });
    final AudioPlaybackPort Function() appPlayback = NullAudioPlayback.new;
    final DeviceSpeechEngine Function() appDevice = NoDeviceSpeech.new;
    final appClips = TemporaryFileClipStore();
    AudioPlaybackPort.hostFactory = appPlayback;
    DeviceSpeechEngine.hostFactory = appDevice;
    TtsManager.clipStore = appClips;
    final ports = <ProviderListenable<Object?>>[
      uiRequestPortProvider,
      openExternalUrlProvider,
      cookieJarProvider,
      voiceModeInputProvider,
      applePccHostProvider,
    ];
    final bound = <Object?>[for (final port in ports) container.read(port)];
    void expectAppKeepsItsOwn() {
      expect(AudioPlaybackPort.hostFactory, same(appPlayback));
      expect(DeviceSpeechEngine.hostFactory, same(appDevice));
      expect(TtsManager.clipStore, same(appClips));
      for (var i = 0; i < ports.length; i++) {
        expect(container.read(ports[i]), same(bound[i]));
      }
    }

    final built = ProtocolServices(
      events: EventBus(),
      system: system(),
      ports: ProtocolHostPorts(
        window: await WindowPorts.open(),
        sharesAppContainer: true,
      ),
    );
    addTearDown(built.dispose);
    addTearDown(built.closeTransports);
    built.attach(container);
    expectAppKeepsItsOwn();

    final window = connect(built);
    final handshake = HandshakeResponse.fromJson(
      await window.sendRequest(
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
    // Known before anything is asked of them, and refused exactly as
    // listed: a method of each namespace, every namespace there is.
    expect(handshake.capabilities.notOffered, HostNamespace.values);
    final methodOf = <HostNamespace, (String, Map<String, dynamic>)>{
      HostNamespace.speech: (ConduitMethods.speechGet, const {}),
      HostNamespace.calls: (ConduitMethods.callsGet, const {}),
      HostNamespace.apple: (ConduitMethods.appleStatus, const {}),
      HostNamespace.location: (
        ConduitMethods.locationReport,
        const LocationReport(id: 1).toJson(),
      ),
    };
    expect(methodOf.keys, unorderedEquals(HostNamespace.values));
    for (final MapEntry(key: namespace, value: (method, params))
        in methodOf.entries) {
      await expectLater(
        window.sendRequest(method, params),
        throwsA(
          isA<json_rpc.RpcException>().having(
            RpcError.fromException,
            'error',
            isA<RpcError>()
                .having((e) => e.code, 'code', ConduitErrorCodes.unsupported)
                .having(
                  (e) => e.debugMessage,
                  'message',
                  '${namespace.name}.* is not offered by this host',
                ),
          ),
        ),
        reason: method,
      );
    }

    await built.closeTransports();
    await built.dispose();
    expectAppKeepsItsOwn();
  });

  test('over a container an app shares, a channel post is counted, a mute '
      'applied and an answer from elsewhere alerted once, by the app: the '
      'services announce none of them', () async {
    await startDesktop();
    // The app's container as its signed-in channels screen leaves it: the
    // socket, the user and the list. The app's own listener counts what
    // the socket says; it is not built here, so anything counted below was
    // counted a second time.
    final socket = _ChannelSocket();
    final app = ProviderContainer(
      parent: runtime.container,
      overrides: [
        socketServiceProvider.overrideWithValue(socket),
        settledActiveAccountIdProvider.overrideWith(_SettledAccount.new),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'me',
            username: 'robin',
            email: 'robin@example.com',
            name: 'Robin',
            role: 'user',
          ),
        ),
        channelsListProvider.overrideWith(_GardenClub.new),
      ],
    );
    addTearDown(app.dispose);
    final built = ProtocolServices(
      events: EventBus(),
      system: system(),
      ports: ProtocolHostPorts(
        window: await WindowPorts.open(),
        sharesAppContainer: true,
      ),
    );
    addTearDown(built.dispose);
    addTearDown(built.closeTransports);
    built.attach(app);
    final posted = <String>[];
    built.events.tap((event, _, _) {
      if (event == ConduitEvents.channelsPosted) posted.add(event);
    });
    await app.read(channelsListProvider.future);
    // The channels service hears the app's socket, and handles each frame
    // before `channel` returns: nothing below waits.
    expect(socket.channelHandlers, 1);

    socket.channel(<String, dynamic>{
      'channel_id': 'c1',
      'data': <String, dynamic>{
        'type': 'message',
        'data': <String, dynamic>{
          'id': 'm1',
          'content': 'Seedlings are up',
          'user': <String, dynamic>{'id': 'u2', 'name': 'Juniper'},
        },
      },
    });
    socket.channel(<String, dynamic>{
      'channel_id': 'c1',
      'data': <String, dynamic>{
        'type': 'channel:mute',
        'data': <String, dynamic>{'is_channel_muted': true},
      },
    });

    final garden = app.read(channelsListProvider).value!.single;
    expect(garden.unreadCount, 0);
    expect(garden.isChannelMuted, isFalse);
    expect(posted, isEmpty);
    expect(socket.chatHandlers, 0);
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

/// Preferences in memory whose next bool write waits for [hold]'s answer.
final class _HeldWrites extends InMemoryKeyValueStore {
  Completer<void>? _gate;
  final held = Completer<void>();

  Completer<void> hold() => _gate = Completer<void>();

  @override
  Future<bool> setBool(String key, bool value) async {
    final gate = _gate;
    if (gate != null) {
      _gate = null;
      if (!held.isCompleted) held.complete();
      await gate.future;
    }
    return super.setBool(key, value);
  }
}

/// The account the app's socket belongs to, settled.
class _SettledAccount extends SettledActiveAccountId {
  @override
  String? build() => 'account-robin';
}

class _GardenClub extends ChannelsList {
  @override
  Future<List<Channel>> build() async => const <Channel>[
    Channel(id: 'c1', name: 'garden-club', type: 'group', userId: 'me'),
  ];
}

/// The app's socket, as far as the services listen to it.
class _ChannelSocket implements SocketService {
  final List<SocketChannelEventHandler> _channel =
      <SocketChannelEventHandler>[];

  int get channelHandlers => _channel.length;

  void channel(Map<String, dynamic> event) {
    for (final handler in List.of(_channel)) {
      handler(event, null);
    }
  }

  @override
  SocketEventSubscription addChannelEventHandler({
    String? conversationId,
    String? sessionId,
    bool requireFocus = true,
    required SocketChannelEventHandler handler,
  }) {
    _channel.add(handler);
    return SocketEventSubscription(() => _channel.remove(handler));
  }

  /// The chat handlers bound now: the services listen for answers to
  /// announce only when nobody else does.
  int chatHandlers = 0;

  @override
  SocketEventSubscription addChatEventHandler({
    String? conversationId,
    String? sessionId,
    String? messageId,
    bool requireFocus = true,
    bool keepsAliveInBackground = false,
    SocketReplayGapCallback? onReplayGap,
    required SocketChatEventHandler handler,
  }) {
    chatHandlers++;
    return SocketEventSubscription(() => chatHandlers--);
  }

  @override
  SocketEventSubscription addAppEventHandler(SocketAppEventHandler handler) =>
      SocketEventSubscription(() {});

  @override
  Stream<void> get onReconnect => const Stream<void>.empty();

  @override
  Stream<SocketHealth> get healthStream => const Stream<SocketHealth>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
