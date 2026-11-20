@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/auth/auth_state_manager.dart' show AuthStatus;
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart'
    show PersonalConnectionKind;
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart'
    hide PersonalConnectionTestResult;
import 'package:conduit_core/features/notifications/models/notification_target.dart';
import 'package:conduit_core/features/notifications/providers/notification_target_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/account_metadata.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/testing.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import 'support/null_sink.dart';

const String _token = 'Qm7vR2xKp9LwZt4NbHs6YdFe3GjCa8UoTi1XkPq5VrS';
final String _masterKey = base64.encode(List<int>.filled(32, 11));

/// `settings.*` (core's AppSettings), `releaseNotes.*` and what `profile.*`,
/// `memories.*` and `data.*` say with no account, over one daemon's socket.
/// The live suite covers them against a server.
void main() {
  late Directory tempDir;
  late DaemonServer server;
  late json_rpc.Peer peer;
  final events = <EventEnvelope>[];
  final waiting = <(String, Completer<void>)>[];

  /// The next [event] this window is sent.
  Future<void> next(String event) {
    final arrived = Completer<void>();
    waiting.add((event, arrived));
    return arrived.future;
  }

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('conduitd_settings');
    final config = BootstrapConfig(
      sessionToken: _token,
      masterKey: _masterKey,
      userDataDir: tempDir.path,
    );
    final directories = DaemonDirectories.create(tempDir.path);
    final log = DaemonLog(level: 'error', sink: NullSink());
    server = DaemonServer(
      config: config,
      directories: directories,
      daemonVersion: '0.0.0-test',
      log: log,
    );
    final port = await server.start();
    server.attachCore(
      await CoreRuntime.start(
        config: config,
        directories: directories,
        log: log,
      ),
    );
    final socket = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port${ConduitHttpRoutes.rpc}'),
      protocols: buildSubprotocols(_token),
      headers: <String, dynamic>{'Origin': kConduitAppOrigin},
    );
    await socket.ready;
    peer = json_rpc.Peer(socket.cast<String>());
    registerEventSink(
      peer,
      onEvent: (envelope) {
        events.add(envelope);
        for (final entry in waiting.toList()) {
          if (entry.$1 == envelope.event) {
            waiting.remove(entry);
            entry.$2.complete();
          }
        }
      },
    );
    unawaited(peer.listen());
    await callTyped<HandshakeResponse>(
      peer,
      ConduitMethods.systemHandshake,
      params: const HandshakeRequest(
        protocolVersion: kConduitProtocolVersion,
        clientName: 'test',
        clientVersion: '0.0.0',
        windowKind: WindowKind.headless,
        locale: 'en',
      ).toJson(),
      decodeResult: HandshakeResponse.fromJson,
    );
    await callTyped<EventSubscription>(
      peer,
      ConduitMethods.eventsSubscribe,
      params: const EventSubscription(
        events: <String>[
          ConduitEvents.settingsChanged,
          ConduitEvents.notificationsChanged,
        ],
      ).toJson(),
      decodeResult: EventSubscription.fromJson,
    );
  });

  tearDownAll(() async {
    await peer.close();
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<T> call<T>(
    String method,
    T Function(Map<String, dynamic>) decode, [
    Map<String, dynamic>? params,
  ]) => callTyped<T>(peer, method, params: params, decodeResult: decode);

  Future<AppSettingsDto> read() =>
      call(ConduitMethods.settingsGet, AppSettingsDto.fromJson);

  Future<AppSettingsDto> patch(AppSettingsPatch p) =>
      call(ConduitMethods.settingsSet, AppSettingsDto.fromJson, p.toJson());

  Matcher rpcCode(String code) =>
      throwsA(isA<RpcError>().having((e) => e.code, 'code', code));

  group('notifications.*, webhooks.* and integrations.*', () {
    test(
      'notifications start on here, change, persist and announce it',
      () async {
        final start = await call(
          ConduitMethods.notificationsGet,
          NotificationSettingsDto.fromJson,
        );
        // The desktop's host default (the phone's stays off).
        expect(start.enabled, isTrue);
        expect(start.answers, isTrue);
        expect(start.channels, isTrue);
        expect(start.mentionsOnly, isFalse);
        // Nothing to mirror to without an account.
        expect(start.synced, isFalse);
        // The shared daemon gets its start values back, pass or fail.
        addTearDown(
          () => call(
            ConduitMethods.notificationsSet,
            NotificationSettingsDto.fromJson,
            NotificationSettingsPatch(
              inAppBanner: start.inAppBanner,
              answers: start.answers,
            ).toJson(),
          ),
        );

        final announced = next(ConduitEvents.notificationsChanged);
        final after = await call(
          ConduitMethods.notificationsSet,
          NotificationSettingsDto.fromJson,
          const NotificationSettingsPatch(
            inAppBanner: false,
            answers: false,
          ).toJson(),
        );
        expect(after.inAppBanner, isFalse);
        expect(after.answers, isFalse);
        expect(after.system, isTrue);
        await announced;

        Future<NotificationRoute> route(NotificationRouteParams p) => call(
          ConduitMethods.notificationsRoute,
          NotificationRoute.fromJson,
          p.toJson(),
        );
        // Answers are off now.
        expect(
          (await route(const NotificationRouteParams(kind: NotifyKind.answer)))
              .surface,
          NotifySurface.suppressed,
        );
        // A channel message in front with the banner off: silent.
        expect(
          (await route(
            const NotificationRouteParams(
              kind: NotifyKind.channelMessage,
              foreground: true,
            ),
          )).surface,
          NotifySurface.silent,
        );
        // Behind: a system notification with its sound.
        final behind = await route(
          const NotificationRouteParams(kind: NotifyKind.channelMessage),
        );
        expect(behind.surface, NotifySurface.system);
        expect(behind.systemSound, isTrue);
      },
    );

    test(
      'webhooks and personal connections need an Open WebUI account',
      () async {
        final hooks = await call(
          ConduitMethods.webhooksList,
          WebhookList.fromJson,
        );
        expect(hooks.available, isFalse);
        final connections = await call(
          ConduitMethods.integrationsList,
          PersonalConnections.fromJson,
        );
        expect(connections.access, PersonalAccess.noAccount);
        // An owner no list handed out is refused before anything is sent.
        await expectLater(
          call(
            ConduitMethods.webhooksDelete,
            WebhookList.fromJson,
            const WebhookRef(owner: 'w9', id: 'x').toJson(),
          ),
          rpcCode(ConduitErrorCodes.conflict),
        );
        await expectLater(
          call(
            ConduitMethods.integrationsSave,
            PersonalConnections.fromJson,
            const PersonalConnectionSave(
              owner: 'p9',
              kind: PersonalKind.toolServer,
              op: PersonalEditOp.remove,
              identity: 'x',
            ).toJson(),
          ),
          rpcCode(ConduitErrorCodes.conflict),
        );
      },
    );

    test('a tool server mode the form does not offer is refused, never read '
        'as bearer', () async {
      for (final draft in const <PersonalConnectionDraft>[
        PersonalConnectionDraft(
          url: 'https://tools.example.com',
          authType: 'session',
          key: 'seed-token',
        ),
        PersonalConnectionDraft(
          url: 'https://tools.example.com',
          specType: 'yaml',
        ),
      ]) {
        await expectLater(
          call(
            ConduitMethods.integrationsTest,
            PersonalConnectionTestResult.fromJson,
            PersonalConnectionTest(
              owner: 'p9',
              kind: PersonalKind.toolServer,
              draft: draft,
            ).toJson(),
          ),
          rpcCode(ConduitErrorCodes.invalidParams),
        );
        await expectLater(
          call(
            ConduitMethods.integrationsSave,
            PersonalConnections.fromJson,
            PersonalConnectionSave(
              owner: 'p9',
              kind: PersonalKind.toolServer,
              op: PersonalEditOp.add,
              draft: draft,
            ).toJson(),
          ),
          rpcCode(ConduitErrorCodes.invalidParams),
        );
      }
    });
  });

  group('settings.get and settings.set', () {
    test("start at core's defaults, with the message action catalog", () async {
      final s = await read();
      // The desktop's own default: Enter sends until it is turned off.
      expect(s.sendOnEnter, isTrue);
      expect(s.showComposerNotesButton, isTrue);
      expect(s.computerEnabled, isTrue);
      expect(s.quickPills, isEmpty);
      expect(s.inlineMessageActions, isNull);
      expect(s.socketTransportMode, 'ws');
      expect(s.voiceCallMode, 'auto');
      expect(s.sttPreference, 'deviceOnly');
      expect(s.ttsEngine, 'device');
      expect(s.ttsSpeed, 1.0);
      expect(s.voiceSilenceDuration, 2000);
      expect(s.messageActions.first, 'copy');
      expect(s.messageActions, contains('delete'));
      expect(s.defaultInlineMessageActions, <String>[
        'copy',
        'tts',
        'regenerate',
      ]);
    });

    test('a patch writes what it names, persists, and announces it', () async {
      final announced = next(ConduitEvents.settingsChanged);
      final after = await patch(
        const AppSettingsPatch(
          sendOnEnter: false,
          temporaryChatByDefault: true,
          showComposerNotesButton: false,
          quickPills: <String>['web', 'web', ' image '],
          inlineMessageActions: <String>['regenerate', 'copy'],
          advancedFeaturesEnabled: true,
          citationShowTitles: true,
        ),
      );
      expect(after.sendOnEnter, isFalse);
      expect(after.temporaryChatByDefault, isTrue);
      expect(after.showComposerNotesButton, isFalse);
      expect(after.quickPills, <String>['web', 'image']);
      expect(after.inlineMessageActions, <String>['regenerate', 'copy']);
      expect(after.advancedFeaturesEnabled, isTrue);
      expect(after.citationShowTitles, isTrue);
      // Untouched.
      expect(after.computerEnabled, isTrue);
      expect(await read(), after);
      await announced;
    });

    test('a transport change alone is announced', () async {
      final before = (await read()).socketTransportMode;
      final announced = next(ConduitEvents.settingsChanged);
      final after = await patch(
        AppSettingsPatch(
          socketTransportMode: before == 'polling' ? 'ws' : 'polling',
        ),
      );
      expect(after.socketTransportMode, isNot(before));
      await announced;
    });

    test('values are held to what core offers', () async {
      final s = await patch(
        const AppSettingsPatch(
          ttsSpeed: 1.4,
          voiceSilenceDuration: 9999,
          socketTransportMode: 'polling',
          voiceCallMode: 'standard',
          sttPreference: 'serverOnly',
          ttsEngine: 'server',
        ),
      );
      expect(s.ttsSpeed, 1.5);
      expect(s.voiceSilenceDuration, 5000);
      expect(s.socketTransportMode, 'polling');
      expect(s.voiceCallMode, 'standard');
      expect(s.sttPreference, 'serverOnly');
      expect(s.ttsEngine, 'server');
      final rounded = await patch(
        const AppSettingsPatch(voiceSilenceDuration: 1449),
      );
      expect(rounded.voiceSilenceDuration, 1400);
    });

    test(
      'clear sets nullable fields back, and a bad value changes nothing',
      () async {
        await patch(
          const AppSettingsPatch(
            defaultModel: 'fake-model',
            sttLanguageCode: 'de',
            directVoiceProvider: DirectVoiceProviderDto(
              profileId: 'dc-1',
              speechModel: ' tts-1 ',
              realtimeInstructions: '  Speak slowly.',
            ),
          ),
        );
        var s = await read();
        expect(s.defaultModel, 'fake-model');
        expect(s.directVoiceProvider?.speechModel, 'tts-1');
        expect(s.directVoiceProvider?.realtimeInstructions, '  Speak slowly.');

        await expectLater(
          patch(
            const AppSettingsPatch(
              sendOnEnter: true,
              inlineMessageActions: <String>['teleport'],
            ),
          ),
          rpcCode(ConduitErrorCodes.invalidParams),
        );
        await expectLater(
          patch(const AppSettingsPatch(clear: <String>['sendOnEnter'])),
          rpcCode(ConduitErrorCodes.invalidParams),
        );
        await expectLater(
          patch(const AppSettingsPatch(ttsEngine: 'robot')),
          rpcCode(ConduitErrorCodes.invalidParams),
        );
        expect((await read()).sendOnEnter, isFalse);

        s = await patch(
          const AppSettingsPatch(
            clear: <String>[
              'defaultModel',
              'sttLanguageCode',
              'inlineMessageActions',
              'directVoiceProvider',
            ],
          ),
        );
        expect(s.defaultModel, isNull);
        expect(s.sttLanguageCode, isNull);
        expect(s.inlineMessageActions, isNull);
        expect(s.directVoiceProvider, isNull);
      },
    );
  });

  group('voice names', () {
    test('a name alone renames the voice chosen', () async {
      var s = await patch(
        const AppSettingsPatch(
          ttsVoice: 'voice-a',
          ttsVoiceName: 'Voice A',
          ttsServerVoiceId: 'server-a',
          ttsServerVoiceName: 'Server A',
        ),
      );
      expect(s.ttsVoiceName, 'Voice A');
      s = await patch(const AppSettingsPatch(ttsVoiceName: 'Voice A (Mac)'));
      expect(s.ttsVoice, 'voice-a');
      expect(s.ttsVoiceName, 'Voice A (Mac)');
      s = await patch(const AppSettingsPatch(ttsServerVoiceName: 'Server A2'));
      expect(s.ttsServerVoiceId, 'server-a');
      expect(s.ttsServerVoiceName, 'Server A2');
    });

    test('a voice given with its name cleared is kept', () async {
      final s = await patch(
        const AppSettingsPatch(
          ttsVoice: 'voice-b',
          ttsServerVoiceId: 'server-b',
          clear: <String>['ttsVoiceName', 'ttsServerVoiceName'],
        ),
      );
      expect(s.ttsVoice, 'voice-b');
      expect(s.ttsVoiceName, isNull);
      expect(s.ttsServerVoiceId, 'server-b');
      expect(s.ttsServerVoiceName, isNull);
    });

    test('a name with no voice chosen is refused', () async {
      await patch(
        const AppSettingsPatch(clear: <String>['ttsVoice', 'ttsServerVoiceId']),
      );
      await expectLater(
        patch(const AppSettingsPatch(ttsVoiceName: 'Nobody')),
        rpcCode(ConduitErrorCodes.invalidParams),
      );
      await expectLater(
        patch(const AppSettingsPatch(ttsServerVoiceName: 'Nobody')),
        rpcCode(ConduitErrorCodes.invalidParams),
      );
      // The server engine forgets the device voice: a name with it names
      // nothing.
      await patch(const AppSettingsPatch(ttsVoice: 'voice-a'));
      await expectLater(
        patch(
          const AppSettingsPatch(ttsEngine: 'server', ttsVoiceName: 'Renamed'),
        ),
        rpcCode(ConduitErrorCodes.invalidParams),
      );
      await patch(const AppSettingsPatch(clear: <String>['ttsVoice']));
      final s = await read();
      expect(s.ttsVoiceName, isNull);
      expect(s.ttsServerVoiceName, isNull);
    });
  });

  group('without an Open WebUI account', () {
    test('a backup that cannot be read is a failed result', () async {
      final file = File('${tempDir.path}/locked.json')..writeAsStringSync('[]');
      Process.runSync('chmod', <String>['000', file.path]);
      addTearDown(() => Process.runSync('chmod', <String>['600', file.path]));
      final preview = await call(
        ConduitMethods.dataPreviewImport,
        DataActionResult.fromJson,
        DataImportRequest(path: file.path).toJson(),
      );
      expect(preview.failure, 'failed');
    });

    test('the account pages say they do not apply', () async {
      final account = await call(
        ConduitMethods.settingsGetAccount,
        AccountSettingsDto.fromJson,
      );
      expect(account.available, isFalse);
      final memories = await call(
        ConduitMethods.memoriesList,
        MemoryList.fromJson,
      );
      expect(memories.available, isFalse);
      final data = await call(
        ConduitMethods.dataSummary,
        ChatDataSummary.fromJson,
      );
      expect(data.available, isFalse);
      final health = await call(
        ConduitMethods.dataConnection,
        ConnectionHealth.fromJson,
      );
      expect(health.available, isFalse);
      await expectLater(
        call(ConduitMethods.profileGet, ProfileDto.fromJson),
        rpcCode(ConduitErrorCodes.unauthenticated),
      );
    });

    test("About still has Conduit's links", () async {
      final about = await call(
        ConduitMethods.settingsAbout,
        AboutInfo.fromJson,
      );
      expect(about.server, isFalse);
      expect(about.repositoryUrl, 'https://github.com/cogwheel0/conduit');
      expect(
        about.githubSponsorsUrl,
        startsWith('https://github.com/sponsors'),
      );
      expect(about.buyMeACoffeeUrl, startsWith('https://www.buymeacoffee.com'));
    });

    test('a backup that is not a chat export is refused, naming why', () async {
      final file = File('${tempDir.path}/not-chats.json')
        ..writeAsStringSync('{"hello": "world"}');
      final preview = await call(
        ConduitMethods.dataPreviewImport,
        DataActionResult.fromJson,
        DataImportRequest(path: file.path).toJson(),
      );
      expect(preview.failure, 'notAList');
      final missing = await call(
        ConduitMethods.dataPreviewImport,
        DataActionResult.fromJson,
        DataImportRequest(path: '${tempDir.path}/nowhere.json').toJson(),
      );
      expect(missing.failure, isNotNull);
    });
  });

  group('releaseNotes.*', () {
    String catalog(List<String> versions) => jsonEncode(<String, Object>{
      'notes': <Object>[
        for (final v in versions)
          <String, Object>{
            'version': v,
            'title': 'What is new',
            'intro': 'Notes for $v.',
            'bullets': <Object>[
              <String, Object>{'text': 'Something in $v.', 'icon': 'polish'},
            ],
          },
      ],
    });

    ReleaseNotesQuery query(String version, {String language = 'en'}) =>
        ReleaseNotesQuery(
          currentVersion: version,
          languageCode: language,
          catalogs: <String, String>{
            'en': catalog(<String>['0.9.0', '0.10.0']),
            'de': catalog(<String>['0.9.0']),
          },
        );

    Future<ReleaseNotesState> check(ReleaseNotesQuery q) => call(
      ConduitMethods.releaseNotesCheck,
      ReleaseNotesState.fromJson,
      q.toJson(),
    );

    test('a first launch shows none, an update shows its notes once', () async {
      // First run: nothing seen before, so nothing to show.
      final first = await check(query('0.9.0-beta.4'));
      expect(first.currentVersion, '0.9.0');
      expect(first.banner, isFalse);

      // The update: the banner, with the notes since the last version.
      final updated = await check(query('0.10.0'));
      expect(updated.banner, isTrue);
      expect(updated.notes.map((n) => n.version), <String>['0.10.0']);
      expect(updated.notes.single.bullets.single.icon, 'polish');

      // A relaunch before it is dismissed brings it back.
      expect((await check(query('0.10.0'))).banner, isTrue);
      final dismissed = await call(
        ConduitMethods.releaseNotesDismiss,
        OkResult.fromJson,
      );
      expect(dismissed.ok, isTrue);
      expect((await check(query('0.10.0'))).banner, isFalse);
    });

    test(
      "About's entry shows the newest note at or before the version",
      () async {
        final latest = await call(
          ConduitMethods.releaseNotesLatest,
          ReleaseNotesState.fromJson,
          query('0.9.5').toJson(),
        );
        expect(latest.notes.single.version, '0.9.0');
        // A language without its own catalog falls back to English.
        final fallback = await call(
          ConduitMethods.releaseNotesLatest,
          ReleaseNotesState.fromJson,
          query('0.10.0', language: 'ko').toJson(),
        );
        expect(fallback.notes.single.version, '0.10.0');
        final german = await call(
          ConduitMethods.releaseNotesLatest,
          ReleaseNotesState.fromJson,
          query('0.10.0', language: 'de').toJson(),
        );
        expect(german.notes.single.version, '0.9.0');
      },
    );

    test('a broken catalog is refused', () async {
      await expectLater(
        call(
          ConduitMethods.releaseNotesLatest,
          ReleaseNotesState.fromJson,
          const ReleaseNotesQuery(
            currentVersion: '1.0.0',
            languageCode: 'en',
            catalogs: <String, String>{
              'en': '{"notes": [{"version": "1.0.0"}]}',
            },
          ).toJson(),
        ),
        rpcCode(ConduitErrorCodes.invalidParams),
      );
    });
  });

  _withAnAccount();
}

const _server = ServerConfig(
  id: 'server',
  name: 'Home server',
  url: 'https://home.invalid',
);

const _ava = User(
  id: 'user-1',
  username: 'ava',
  email: 'ava@example.com',
  name: 'Ava',
  role: 'user',
);

const _bo = User(
  id: 'user-2',
  username: 'bo',
  email: 'bo@example.com',
  name: 'Bo',
  role: 'user',
);

/// `profile.*`, `data.*` and the model prompts over core's providers with
/// one signed-in account, whose session the tests change mid-request. The
/// API answers from memory: nothing reaches a network.
void _withAnAccount() {
  group('with an account', () {
    late AppDatabase db;
    late _Api api;
    late Object epoch;
    late User? user;
    late ServerConfig server;
    late AuthStatus status;
    late bool previousWarning;
    late ProviderContainer mirrorContainer;

    setUpAll(() {
      previousWarning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    });
    tearDownAll(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousWarning;
    });

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      api = _Api();
      epoch = Object();
      user = _ava;
      server = _server;
      status = AuthStatus.authenticated;
    });
    tearDown(() async {
      api.dispose();
      await db.close();
    });

    /// Notification settings whose server mirror waits on the account in
    /// charge: its session, user, sign-in state and server read from
    /// [epoch], [user], [status] and [server], which [signIn] moves on.
    NotificationsService mirroring(FakeAsync async) {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(_NotificationSettings.new),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
          currentUserProvider2.overrideWith((ref) => user),
          authStatusProvider.overrideWith((ref) => status),
          activeServerProvider.overrideWith((ref) async => server),
          apiServiceProvider.overrideWith((ref) => api),
        ],
      );
      addTearDown(container.dispose);
      container.listen(activeServerProvider, (_, _) {});
      async.flushMicrotasks();
      mirrorContainer = container;
      return NotificationsService(container);
    }

    /// The account's sign-in moves to [next] as [who]: a new session.
    void signIn(FakeAsync async, AuthStatus next, User? who) {
      status = next;
      user = who;
      epoch = Object();
      mirrorContainer
        ..invalidate(authStatusProvider)
        ..invalidate(currentUserProvider2)
        ..invalidate(openWebUiAuthSessionEpochProvider);
      async.elapse(Duration.zero);
    }

    /// Two changes, the first one's mirror held at the server until
    /// [Completer.complete]; the second's waits behind it.
    Completer<void> twoChanges(
      FakeAsync async,
      NotificationsService notifications,
    ) {
      final held = api.mirrorHeld = Completer<void>();
      notifications.set(const NotificationSettingsPatch(enabled: false));
      async.flushMicrotasks();
      notifications.set(const NotificationSettingsPatch(enabled: true));
      async.flushMicrotasks();
      return held;
    }

    /// Set to hold `serverAboutInfo`: completes [aboutAsked] when asked.
    Completer<void>? aboutHeld;
    Completer<void>? aboutAsked;

    ProviderContainer containerWith({List<Override> extra = const []}) {
      final container = ProviderContainer(
        overrides: [
          ...extra,
          ...openWebUiStorageOpenOverrides(database: db),
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          apiServiceProvider.overrideWith((ref) => api),
          currentUserProvider2.overrideWith((ref) => user),
          isAuthenticatedProvider2.overrideWithValue(true),
          reviewerModeProvider.overrideWithValue(false),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
          socketServiceProvider.overrideWithValue(null),
          syncEngineProvider.overrideWith(_QuietSyncEngine.new),
          legacyConversationCachePurgerProvider.overrideWith(
            (ref) => () async {},
          ),
          userPermissionsProvider.overrideWith(
            (ref) async => const <String, dynamic>{},
          ),
          serverAboutInfoProvider.overrideWith((ref) async {
            aboutAsked?.complete();
            await aboutHeld?.future;
            return null;
          }),
          authActionsProvider.overrideWith(_QuietAuth.new),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    /// Another account signs in on this computer.
    void switchAccount(ProviderContainer container) {
      epoch = Object();
      user = _bo;
      container
        ..invalidate(openWebUiAuthSessionEpochProvider)
        ..invalidate(currentUserProvider2);
    }

    Matcher refused(String code) =>
        throwsA(isA<RpcError>().having((e) => e.code, 'code', code));

    test(
      'a profile read under one account is never saved under the next',
      () async {
        final container = containerWith();
        final profiles = ProfileService(container);
        final read = Completer<AccountMetadata>();
        api.metadata = () => read.future;
        final saving = profiles.update(const ProfileEdit(bio: 'Hello'));
        switchAccount(container);
        read.complete(_avaMetadata());
        await expectLater(saving, refused(ConduitErrorCodes.sessionExpired));
        expect(api.saved, isEmpty);
      },
    );

    test("a profile read under one account never fetches the next one's "
        'photo', () async {
      aboutHeld = Completer<void>();
      aboutAsked = Completer<void>();
      addTearDown(() {
        aboutHeld = null;
        aboutAsked = null;
      });
      final container = containerWith();
      api.metadata = () async => _avaMetadata(image: '/static/me.png');
      final reading = ProfileService(container).get();
      await aboutAsked!.future;
      // Another account signs in while the server's About is read.
      switchAccount(container);
      aboutHeld!.complete();
      await expectLater(reading, refused(ConduitErrorCodes.sessionExpired));
      expect(api.asked.where((uri) => uri.path.endsWith('/me.png')), isEmpty);
    });

    test('a settings patch stops once another account signs in', () async {
      final settings = _Settings();
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(() => settings),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
        ],
      );
      addTearDown(container.dispose);
      final saving = CoreSettingsService(
        container,
      ).set(const AppSettingsPatch(computerEnabled: false, sendOnEnter: false));
      // Another account signs in while the first setting is written.
      epoch = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);
      settings.written.complete();
      await expectLater(saving, refused(ConduitErrorCodes.sessionExpired));
      expect(settings.calls, <String>['computerEnabled']);
    });

    test('a settings patch stops once another account is active, signed in '
        'or not', () async {
      final settings = _Settings();
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(() => settings),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
        ],
      );
      addTearDown(container.dispose);
      final before = PreferencesStore.getString(PreferenceKeys.activeServerId);
      addTearDown(
        () => PreferencesStore.put(PreferenceKeys.activeServerId, before),
      );
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-a');
      final saving = CoreSettingsService(
        container,
      ).set(const AppSettingsPatch(computerEnabled: false, sendOnEnter: false));
      // Account B becomes active with no sign-in: the session epoch stays.
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-b');
      settings.written.complete();
      await expectLater(saving, refused(ConduitErrorCodes.sessionExpired));
      expect(settings.calls, <String>['computerEnabled']);
    });

    test('notification settings asked under one account are never written '
        'for the next', () async {
      final settings = _Settings();
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(() => settings),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
          apiServiceProvider.overrideWith((ref) => null),
        ],
      );
      addTearDown(container.dispose);
      final saving = NotificationsService(container)
          .set(const NotificationSettingsPatch(enabled: false, sound: false));
      // Another account signs in while the first setting is written.
      await settings.notificationsAsked.future;
      epoch = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);
      settings.written.complete();
      await expectLater(saving, refused(ConduitErrorCodes.sessionExpired));
      expect(settings.calls, <String>['notificationsEnabled']);
    });

    test('a server mirror that has not answered never holds the next '
        'notification change', () async {
      final settings = _NotificationSettings();
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(() => settings),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
          apiServiceProvider.overrideWith((ref) => api),
        ],
      );
      addTearDown(container.dispose);
      final notifications = NotificationsService(container);
      // The first change's mirror is slow to reach the server.
      final held = api.mirrorHeld = Completer<void>();
      final off = notifications.set(
        const NotificationSettingsPatch(enabled: false),
      );
      await api.mirrorAsked.future;
      var answered = false;
      final on = notifications
          .set(const NotificationSettingsPatch(enabled: true))
          .then((dto) => answered = true);
      await pumpEventQueue();
      // Written and answered while the server still has not answered.
      expect(answered, isTrue);
      expect(container.read(appSettingsProvider).notificationsEnabled, isTrue);
      held.complete();
      await off;
      await on;
      // Settled: the server got both, in order, and holds what this Mac does.
      await api.mirrorsSettled(2);
      expect(api.mirrored, <bool?>[false, true]);
    });

    test("a notification mirror waits for the account's earlier one when "
        'its API client is replaced and its token renewed in between', () {
      fakeAsync((async) {
        final settings = _NotificationSettings();
        final container = ProviderContainer(
          overrides: [
            appSettingsProvider.overrideWith(() => settings),
            openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
            currentUserProvider2.overrideWith((ref) => user),
            activeServerProvider.overrideWith((ref) async => server),
            apiServiceProvider.overrideWith((ref) => api),
          ],
        );
        addTearDown(container.dispose);
        container.listen(activeServerProvider, (_, _) {});
        async.flushMicrotasks();
        final notifications = NotificationsService(container);
        final first = api;
        // The first change's mirror is slow to reach the server.
        final held = first.mirrorHeld = Completer<void>();
        notifications.set(const NotificationSettingsPatch(enabled: false));
        async.flushMicrotasks();
        expect(first.mirrorAsked.isCompleted, isTrue);
        // The account's client is rebuilt before the next change.
        final second = api = _Api()..reached = first.reached;
        container.invalidate(apiServiceProvider);
        var answered = false;
        notifications
            .set(const NotificationSettingsPatch(enabled: true))
            .then((_) => answered = true);
        async.flushMicrotasks();
        // Answered at once; its mirror waits for the account's earlier one.
        expect(answered, isTrue);
        expect(second.mirrored, isEmpty);
        // The same account's token is renewed (a new session) meanwhile, and
        // its address is read back spelled another way.
        epoch = Object();
        server = const ServerConfig(
          id: 'server',
          name: 'Home server',
          url: 'HTTPS://Home.invalid/',
        );
        container
          ..invalidate(openWebUiAuthSessionEpochProvider)
          ..invalidate(activeServerProvider);
        async.elapse(Duration.zero);
        held.complete();
        async.flushMicrotasks();
        expect(first.reached, <bool?>[false, true]);
        expect(second.mirrored, <bool?>[true]);
      });
    });

    test("another account taking charge drops the first account's pending "
        'notification mirror', () {
      fakeAsync((async) {
        final settings = _NotificationSettings();
        final container = ProviderContainer(
          overrides: [
            appSettingsProvider.overrideWith(() => settings),
            openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
            currentUserProvider2.overrideWith((ref) => user),
            apiServiceProvider.overrideWith((ref) => api),
          ],
        );
        addTearDown(container.dispose);
        final notifications = NotificationsService(container);
        final held = api.mirrorHeld = Completer<void>();
        notifications.set(const NotificationSettingsPatch(enabled: false));
        async.flushMicrotasks();
        notifications.set(const NotificationSettingsPatch(enabled: true));
        async.flushMicrotasks();
        // Another user signs in before the first account's second mirror.
        user = _bo;
        epoch = Object();
        container
          ..invalidate(currentUserProvider2)
          ..invalidate(openWebUiAuthSessionEpochProvider);
        held.complete();
        async.flushMicrotasks();
        expect(api.reached, <bool?>[false]);
      });
    });

    // The token expired, and its user is unknown until the silent sign-in
    // ends: the mirror waits for it, and goes once the same user is back.
    test("a notification mirror waits out its account's sign-in renewing, "
        'then goes', () {
      fakeAsync((async) {
        final held = twoChanges(async, mirroring(async));
        signIn(async, AuthStatus.loading, null);
        held.complete();
        async.flushMicrotasks();
        expect(api.reached, <bool?>[false], reason: 'no user to send it as');
        signIn(async, AuthStatus.authenticated, _ava);
        expect(api.reached, <bool?>[false, true]);
      });
    });

    // Signed out while the mirror waited for its sign-in to renew: it goes
    // nowhere, the account's queue moves on, and its next change is sent
    // once it is signed in to again.
    test('a notification mirror waiting for its account is dropped once the '
        'account signs out', () {
      fakeAsync((async) {
        final notifications = mirroring(async);
        final held = twoChanges(async, notifications);
        signIn(async, AuthStatus.loading, null);
        held.complete();
        async.flushMicrotasks();
        expect(api.reached, <bool?>[false]);
        signIn(async, AuthStatus.unauthenticated, null);
        signIn(async, AuthStatus.authenticated, _ava);
        notifications.set(const NotificationSettingsPatch(enabled: false));
        async.flushMicrotasks();
        expect(api.reached, <bool?>[false, false]);
      });
    });

    // The address of the server in charge changed while the mirror waited:
    // a change and back is still a change, so it never goes.
    test('a notification mirror waiting for its account is dropped once the '
        "account's address changes", () {
      fakeAsync((async) {
        final held = twoChanges(async, mirroring(async));
        signIn(async, AuthStatus.loading, null);
        held.complete();
        async.flushMicrotasks();
        server = const ServerConfig(
          id: 'server',
          name: 'Home server',
          url: 'https://away.invalid',
        );
        mirrorContainer.invalidate(activeServerProvider);
        async.elapse(Duration.zero);
        server = _server;
        mirrorContainer.invalidate(activeServerProvider);
        async.elapse(Duration.zero);
        signIn(async, AuthStatus.authenticated, _ava);
        expect(api.reached, <bool?>[false]);
      });
    });

    // Saved before its user was validated, then again after: one account,
    // one queue, and the server ends up with the last change.
    test('notification mirrors keep their order across the user being '
        'validated', () {
      fakeAsync((async) {
        user = null;
        final settings = _NotificationSettings();
        final container = ProviderContainer(
          overrides: [
            appSettingsProvider.overrideWith(() => settings),
            openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
            currentUserProvider2.overrideWith((ref) => user),
            apiServiceProvider.overrideWith((ref) => api),
          ],
        );
        addTearDown(container.dispose);
        final notifications = NotificationsService(container);
        final held = api.mirrorHeld = Completer<void>();
        notifications.set(const NotificationSettingsPatch(enabled: false));
        async.flushMicrotasks();
        expect(api.mirrorAsked.isCompleted, isTrue);
        user = _ava;
        container.invalidate(currentUserProvider2);
        async.elapse(Duration.zero);
        notifications.set(const NotificationSettingsPatch(enabled: true));
        async.flushMicrotasks();
        held.complete();
        async.flushMicrotasks();
        expect(api.reached, <bool?>[false, true]);
      });
    });

    test("a notification mirror queued for one server never goes once the "
        "account's address moves to another", () {
      fakeAsync((async) {
        final settings = _NotificationSettings();
        final container = ProviderContainer(
          overrides: [
            appSettingsProvider.overrideWith(() => settings),
            openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
            currentUserProvider2.overrideWith((ref) => user),
            activeServerProvider.overrideWith((ref) async => server),
            apiServiceProvider.overrideWith((ref) => api),
          ],
        );
        addTearDown(container.dispose);
        container.listen(activeServerProvider, (_, _) {});
        async.flushMicrotasks();
        final notifications = NotificationsService(container);
        final held = api.mirrorHeld = Completer<void>();
        notifications.set(const NotificationSettingsPatch(enabled: false));
        async.flushMicrotasks();
        notifications.set(const NotificationSettingsPatch(enabled: true));
        async.flushMicrotasks();
        // The saved server keeps its id and user but now reaches another
        // server, whose account has the same user id.
        server = const ServerConfig(
          id: 'server',
          name: 'Home server',
          url: 'https://away.invalid',
        );
        container.invalidate(activeServerProvider);
        async.elapse(Duration.zero);
        held.complete();
        async.flushMicrotasks();
        expect(api.reached, <bool?>[false]);
      });
    });

    test('notification changes reach the server in the order their settings '
        'were written', () async {
      final held = Completer<void>();
      final settings = _NotificationSettings()..held = held;
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(() => settings),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
          apiServiceProvider.overrideWith((ref) => api),
        ],
      );
      addTearDown(container.dispose);
      final notifications = NotificationsService(container);
      // The first change's own setting is slow to be written.
      final off = notifications.set(
        const NotificationSettingsPatch(enabled: false),
      );
      await settings.asked.future;
      final on = notifications.set(
        const NotificationSettingsPatch(enabled: true),
      );
      held.complete();
      await off;
      await on;
      await api.mirrorsSettled(2);
      expect(api.mirrored, <bool?>[false, true]);
      expect(container.read(appSettingsProvider).notificationsEnabled, isTrue);
    });

    test("a webhook list read under one account is never answered with the "
        "next one's under the first one's owner", () async {
      final targets = _Targets();
      final container = containerWith(
        extra: [
          notificationTargetsProvider.overrideWith(() => targets),
          notificationTargetsAvailableProvider.overrideWithValue(true),
          authTokenProvider3.overrideWithValue('token-a'),
        ],
      );
      final reading = WebhooksService(container).list();
      await targets.asked.future;
      // Another account signs in while the destinations are read.
      switchAccount(container);
      targets.held.complete();
      await expectLater(reading, refused(ConduitErrorCodes.sessionExpired));
    });

    test('a webhook list that could not be read is read again when the '
        'window asks again', () async {
      user = _avaAdmin;
      var failing = true;
      api.targets = () async {
        if (failing) throw StateError('the server did not answer');
        return const <NotificationTarget>[_pager];
      };
      final webhooks = WebhooksService(containerWith(extra: _webhooksOn));
      expect((await webhooks.list()).failed, isTrue);
      failing = false;
      final again = await webhooks.list();
      expect(again.failed, isFalse);
      expect(again.items.map((w) => w.id), <String>['pager']);
    });

    test('a webhook list read again while the API client is replaced is '
        'answered, and the next one reads the list', () async {
      user = _avaAdmin;
      var failing = true;
      Completer<void>? held;
      final asked = Completer<void>();
      Future<List<NotificationTarget>> targets() async {
        if (failing) throw StateError('the server did not answer');
        final wait = held;
        held = null;
        if (wait != null) {
          asked.complete();
          await wait.future;
        }
        return const <NotificationTarget>[_pager];
      }

      api.targets = targets;
      final container = containerWith(extra: _webhooksOn);
      final webhooks = WebhooksService(container);
      expect((await webhooks.list()).failed, isTrue);
      failing = false;
      final release = held = Completer<void>();
      var settled = false;
      final again = webhooks.list().whenComplete(() => settled = true);
      await asked.future;
      // The same account's API client is replaced while the list is read.
      api = _Api()..targets = targets;
      container.invalidate(apiServiceProvider);
      release.complete();
      await pumpEventQueue();
      expect(settled, isTrue, reason: 'the list waits on a load never settled');
      await again;
      final next = await webhooks.list();
      expect(next.failed, isFalse);
      expect(next.items.map((w) => w.id), <String>['pager']);
    });

    test("an open editor's owner outlasts other windows' list reads", () async {
      user = _avaAdmin;
      api.targets = () async => const <NotificationTarget>[_pager];
      final webhooks = WebhooksService(containerWith(extra: _webhooksOn));
      final editor = (await webhooks.list()).owner;
      // Other windows (and this one's Settings) read the list meanwhile.
      for (var i = 0; i < 40; i++) {
        await webhooks.list();
      }
      await expectLater(
        webhooks.update(
          WebhookUpdate(owner: editor, id: 'pager', enabled: false),
        ),
        completes,
      );
      expect(api.updatedTargets, <String>['pager']);
    });

    test('the composer offers a personal tool server once a config cached '
        'before sign-in is read again', () async {
      user = _avaAdmin;
      final container = containerWith(
        extra: [
          backendConfigProvider.overrideWith(_PreSignInConfig.new),
          personalConnectionsProvider.overrideWith(
            () => _Connections(() => api),
          ),
        ],
      );
      final options = await ComposerService(container).options();
      expect(options.tools.map((t) => t.name), contains('Seed catalogue'));
    });

    test('a server that moved personal connections to Tether lists them to '
        'read only, and the composer offers none', () async {
      user = _avaAdmin;
      final container = containerWith(
        extra: [
          backendConfigProvider.overrideWith(_TetherServer.new),
          personalConnectionsProvider.overrideWith(
            () => _Connections(() => api),
          ),
          movedPersonalConnectionsProvider.overrideWith(
            (ref) => _Connections(() => api).build(),
          ),
        ],
      );

      final list = await IntegrationsService(container).list();
      expect(list.access, PersonalAccess.movedToTether);
      expect(list.owner, isEmpty);
      expect(list.toolServers.map((t) => t.name), <String>['Seed catalogue']);
      final options = await ComposerService(container).options();
      expect(options.tools.map((t) => t.name), isNot(contains('Seed catalogue')));
    });

    test("the composer marks the tools the user's devices offer", () async {
      user = _avaAdmin;
      final container = containerWith(
        extra: [toolsListProvider.overrideWith(_DeviceTools.new)],
      );

      final options = await ComposerService(container).options();

      expect(
        {for (final tool in options.tools) tool.name: tool.device},
        containsPair('Studio Mac · Garage tools', true),
      );
      expect(
        {for (final tool in options.tools) tool.name: tool.device},
        containsPair('Weather', false),
      );
    });

    test('an account switch while the composer reads the config again is '
        'refused', () async {
      user = _avaAdmin;
      final config = _PreSignInConfig()..held = Completer<void>();
      final container = containerWith(
        extra: [
          backendConfigProvider.overrideWith(() => config),
          personalConnectionsProvider.overrideWith(
            () => _Connections(() => api),
          ),
        ],
      );
      final reading = ComposerService(container).options();
      await config.asked.future;
      // Another account signs in while the config is read again.
      switchAccount(container);
      config.held!.complete();
      await expectLater(reading, refused(ConduitErrorCodes.sessionExpired));
    });

    test('a birth date past its month is refused', () async {
      final profiles = ProfileService(containerWith());
      await expectLater(
        profiles.update(const ProfileEdit(dateOfBirth: '2020-01-42')),
        refused(ConduitErrorCodes.invalidParams),
      );
      expect(api.saved, isEmpty);
    });

    test(
      "a profile save survives the sign-in refresh core makes after it",
      () async {
        final container = containerWith();
        final profiles = ProfileService(container);
        api.saves = true;
        // Core refreshes the same account's sign-in after a save: a new
        // session epoch, the same account.
        api.onSaved = () {
          epoch = Object();
          container.invalidate(openWebUiAuthSessionEpochProvider);
        };
        addTearDown(() => api.onSaved = null);
        final saved = await profiles.update(
          const ProfileEdit(bio: 'A newer bio'),
        );
        expect(saved.bio, 'A newer bio');
        expect(api.savedBios, <String?>['A newer bio']);
      },
    );

    test("another user signing in on the same entry during a save never gets "
        'the profile', () async {
      final container = containerWith();
      final profiles = ProfileService(container);
      api.saves = true;
      // Bo signs in on the same saved account entry while Ava's save runs.
      api.onSaved = () => switchAccount(container);
      addTearDown(() => api.onSaved = null);
      await expectLater(
        profiles.update(const ProfileEdit(bio: 'A newer bio')),
        refused(ConduitErrorCodes.sessionExpired),
      );
    });

    test('a photo change waits for a details change before it', () async {
      final container = containerWith();
      final profiles = ProfileService(container);
      api.saves = true;
      api.metadata = () async => _avaMetadata(bio: 'An older bio');
      await profiles.get();
      final details = profiles.update(const ProfileEdit(bio: 'A newer bio'));
      final photo = profiles.setImage(const ProfileImageEdit(initials: true));
      await details;
      await photo;
      expect(api.savedBios, <String?>['A newer bio', 'A newer bio']);
    });

    test("a photo only comes from the account's own server", () async {
      final container = containerWith();
      final profiles = ProfileService(container);
      for (final url in <String>[
        'https://elsewhere.invalid/me.png',
        'http://home.invalid/me.png',
        'https://home.invalid:8443/me.png',
        '//elsewhere.invalid/me.png',
        'http://127.0.0.1:9/me.png',
        '@elsewhere.invalid/me.png',
        'https://home.invalid@elsewhere.invalid/me.png',
        r'\\elsewhere.invalid\me.png',
        '%2F%2Felsewhere.invalid/me.png',
      ]) {
        api.metadata = () async => _avaMetadata(image: url);
        container.invalidate(accountProfileProvider);
        expect((await profiles.get()).image, isNull, reason: url);
      }
      expect(api.asked.where((uri) => uri.path.endsWith('/me.png')), isEmpty);
      api.metadata = () async =>
          _avaMetadata(image: '/api/v1/users/user-1/profile/image');
      container.invalidate(accountProfileProvider);
      await profiles.get();
      api.metadata = () async =>
          _avaMetadata(image: 'https://home.invalid/static/me.png');
      container.invalidate(accountProfileProvider);
      await profiles.get();
      expect(
        api.asked.map((uri) => uri.toString()),
        containsAll(<String>[
          'https://home.invalid/api/v1/users/user-1/profile/image',
          'https://home.invalid/static/me.png',
        ]),
      );
    });

    test("a photo's address is resolved on the server's, or refused", () {
      const server = 'https://home.invalid/owui';
      final cases = <String, String?>{
        // On the server: resolved under its sub-path, as other requests.
        '/api/v1/users/user-1/profile/image':
            'https://home.invalid/owui/api/v1/users/user-1/profile/image',
        'static/me.png': 'https://home.invalid/owui/static/me.png',
        'https://home.invalid/owui/static/me.png':
            'https://home.invalid/owui/static/me.png',
        'https://HOME.invalid:443/static/me.png':
            'https://home.invalid/static/me.png',
        // Another origin.
        'https://elsewhere.invalid/me.png': null,
        'http://home.invalid/me.png': null,
        'https://home.invalid:8443/me.png': null,
        'http://127.0.0.1:9/me.png': null,
        'file:///etc/hosts': null,
        // User info, as a reference or in an address.
        '@elsewhere.invalid/me.png': null,
        'me@elsewhere.invalid': null,
        'https://home.invalid@elsewhere.invalid/me.png': null,
        'https://user:pass@home.invalid/me.png': null,
        '%40elsewhere.invalid/me.png': null,
        // Scheme-relative.
        '//elsewhere.invalid/me.png': null,
        '%2F%2Felsewhere.invalid/me.png': null,
        '/%2Felsewhere.invalid/me.png': null,
        '%2f/elsewhere.invalid/me.png': null,
        // Backslashes, raw or encoded.
        r'\\elsewhere.invalid\me.png': null,
        r'/\elsewhere.invalid/me.png': null,
        '%5C%5Celsewhere.invalid/me.png': null,
        // Spaces and control characters.
        ' //elsewhere.invalid/me.png': null,
        '/static/me.png\n//elsewhere.invalid': null,
      };
      cases.forEach((url, expected) {
        expect(
          ProfileService.avatarUri(server, url)?.toString(),
          expected,
          reason: url,
        );
      });
    });

    test("a model's prompt read under one account is never written under "
        'the next', () async {
      final container = containerWith();
      final settings = CoreSettingsService(container);
      final detail = Completer<Map<String, dynamic>?>();
      api.details = (_) => detail.future;
      final saving = settings.setModelPrompt(
        const ModelPromptEdit(modelId: 'model-1', prompt: 'Be brief.'),
      );
      switchAccount(container);
      detail.complete(<String, dynamic>{
        'id': 'model-1',
        'write_access': true,
        'params': <String, dynamic>{},
      });
      await expectLater(saving, refused(ConduitErrorCodes.sessionExpired));
      expect(api.prompts, isEmpty);
    });

    test('Delete All keeps to the summary its window was shown, for its '
        'account', () async {
      final container = containerWith();
      final data = DataService(container);
      final windowA = Object();
      final windowB = Object();
      expect((await data.summary(caller: windowA)).available, isTrue);
      // Window B was shown no summary: what it confirmed is unknown.
      var result = await data.deleteAll(const DataDeleteAll(), caller: windowB);
      expect(result.failure, 'localWorkChanged');
      expect(api.deletedAll, 0);
      // Window A's summary was the last account's.
      switchAccount(container);
      result = await data.deleteAll(const DataDeleteAll(), caller: windowA);
      expect(result.failure, 'localWorkChanged');
      expect(api.deletedAll, 0);
    });

    test('a summary from the last account never confirms a delete', () async {
      final container = containerWith();
      final data = DataService(container);
      expect((await data.summary()).available, isTrue);
      switchAccount(container);
      final result = await data.deleteAll(const DataDeleteAll());
      expect(result.failure, 'localWorkChanged');
      expect(api.deletedAll, 0);
    });
  });

  group('an exported backup', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('conduitd_backup'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('is in place only once it is delivered', () async {
      final target = File('${dir.path}/chats.json')
        ..writeAsStringSync('the backup from before');
      final sink = BackupFileSink(target);
      await sink.write('[]\n');
      await sink.commit();
      // Core's last check after commit stops it: nothing is delivered.
      await sink.abort();
      expect(target.readAsStringSync(), 'the backup from before');
      expect(dir.listSync(), hasLength(1));

      final next = BackupFileSink(target);
      await next.write('[]\n');
      await next.commit();
      await next.deliver();
      expect(target.readAsStringSync(), '[]\n');
      expect(dir.listSync(), hasLength(1));
    });
  });
}

AccountMetadata _avaMetadata({String? image, String? bio}) => AccountMetadata(
  id: 'user-1',
  email: 'ava@example.com',
  name: 'Ava',
  role: 'user',
  isActive: true,
  profileImageUrl: image,
  bio: bio,
);

final class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

/// Core's settings, recording what is written. The first write waits for
/// [written].
final class _Settings extends AppSettingsNotifier {
  final calls = <String>[];
  final written = Completer<void>();
  final notificationsAsked = Completer<void>();

  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> setComputerEnabled(bool value) async {
    calls.add('computerEnabled');
    await written.future;
  }

  @override
  Future<void> setSendOnEnter(bool value) async {
    calls.add('sendOnEnter');
  }

  @override
  Future<void> setNotificationsEnabled(bool value) async {
    calls.add('notificationsEnabled');
    notificationsAsked.complete();
    await written.future;
  }

  @override
  Future<void> setNotificationSound(bool value) async {
    calls.add('notificationSound');
  }
}

/// Notification settings kept in memory: each setter lands at once.
final class _NotificationSettings extends AppSettingsNotifier {
  /// Holds the first write of the master toggle when set; [asked]
  /// completes as it starts.
  Completer<void>? held;
  final asked = Completer<void>();

  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> setNotificationsEnabled(bool value) async {
    final wait = held;
    held = null;
    if (!asked.isCompleted) asked.complete();
    await wait?.future;
    state = state.copyWith(notificationsEnabled: value);
  }
}

const _avaAdmin = User(
  id: 'user-1',
  username: 'ava',
  email: 'ava@example.com',
  name: 'Ava',
  role: 'admin',
);

/// The config as read before sign-in (no feature flags); read again, it
/// offers personal connections. [held] holds that second read.
final class _PreSignInConfig extends BackendConfigNotifier {
  final asked = Completer<void>();
  Completer<void>? held;

  @override
  Future<BackendConfig?> build() async =>
      BackendConfig(serverId: _server.id, enableDirectIntegrations: false);

  @override
  Future<void> refresh() async {
    if (!asked.isCompleted) asked.complete();
    await held?.future;
    state = AsyncData(
      BackendConfig(serverId: _server.id, enableDirectIntegrations: true),
    );
  }
}

/// The server's tools, one of them a Tether device's (as 0.13.4 names it).
final class _DeviceTools extends ToolsList {
  @override
  Future<List<Tool>> build() async => const <Tool>[
    Tool(id: 'weather', name: 'Weather'),
    Tool(
      id: 'server:tether:3f1c9a52-7d4e-4b8a-9c21-5e6f7a8b9c0d:garage_tools',
      name: 'Studio Mac · Garage tools',
    ),
  ];
}

/// Open WebUI 0.13.4, which reports no direct integrations.
final class _TetherServer extends BackendConfigNotifier {
  @override
  Future<BackendConfig?> build() async =>
      BackendConfig(serverId: _server.id, version: '0.13.4');
}

/// The account's personal connections: one enabled tool server.
final class _Connections extends PersonalConnectionsController {
  _Connections(this._api);

  final ApiService Function() _api;

  @override
  Future<PersonalConnectionsSnapshot?> build() async {
    final api = _api();
    final raw = <String, dynamic>{
      'url': 'https://tools.example.com',
      'path': 'openapi.json',
      'auth_type': 'none',
      'key': '',
      'config': <String, dynamic>{'enable': true},
      'info': <String, dynamic>{'name': 'Seed catalogue'},
    };
    final list = <dynamic>[raw];
    return PersonalConnectionsSnapshot(
      session: PersonalConnectionsSession(
        api: api,
        authSnapshot: api.captureAuthSnapshot(),
        accountName: 'Ava',
        isCurrent: () => true,
      ),
      serverId: _server.id,
      accountName: 'Ava',
      toolServers: <PersonalConnectionEntry>[
        PersonalConnectionEntry(
          kind: PersonalConnectionKind.toolServer,
          index: 0,
          identity: 'seed',
          raw: raw,
          list: list,
        ),
      ],
      terminals: const <PersonalConnectionEntry>[],
    );
  }
}

/// A destination the server lists.
const _pager = NotificationTarget(
  id: 'pager',
  type: NotificationTarget.webhookType,
  enabled: true,
  events: <String>[],
  delivery: NotificationTarget.deliveryAlways,
);

/// Webhook destinations on: the server offers them, and the account's
/// session can own them.
final List<Override> _webhooksOn = [
  backendConfigProvider.overrideWith(_WebhooksOn.new),
  authTokenProvider3.overrideWithValue('token-a'),
];

/// A server with webhook destinations on, for the account's own server.
final class _WebhooksOn extends BackendConfigNotifier {
  @override
  Future<BackendConfig?> build() async =>
      BackendConfig(serverId: _server.id, enableUserWebhooks: true);
}

/// Webhook destinations whose first read waits for [held].
final class _Targets extends NotificationTargets {
  final asked = Completer<void>();
  final held = Completer<void>();

  @override
  Future<NotificationTargetsData> build() async {
    if (!asked.isCompleted) asked.complete();
    await held.future;
    return const NotificationTargetsData();
  }
}

/// Signed in already: a profile save's refresh of the session asks
/// nothing.
final class _QuietAuth extends AuthActions {
  _QuietAuth(super.ref);

  @override
  Future<void> refresh() async {}
}

final class _QuietSyncEngine extends SyncEngine {
  @override
  Future<PullResult?> requestPull({required String reason}) =>
      Future<PullResult?>.value(null);
}

/// The account's server, answered from memory. Every HTTP request is
/// recorded and refused before it leaves.
final class _Api extends ApiService {
  _Api() : super(serverConfig: _server, workerManager: WorkerManager()) {
    dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          asked.add(options.uri);
          handler.reject(
            DioException(requestOptions: options, message: 'offline test'),
          );
        },
      ),
    );
  }

  final asked = <Uri>[];
  final saved = <String>[];

  /// Saves go through and are what the profile reads next.
  var saves = false;

  /// Run after a save, as core's own auth refresh after it.
  void Function()? onSaved;
  final savedBios = <String?>[];
  final prompts = <String>[];
  var deletedAll = 0;
  Future<AccountMetadata> Function() metadata = () async => _avaMetadata();
  Future<Map<String, dynamic>?> Function(String id) details = (_) async => null;

  /// The account's webhook destinations, as the server lists them.
  Future<List<NotificationTarget>> Function() targets = () async =>
      throw StateError('no destinations in this test');
  final updatedTargets = <String>[];

  @override
  Future<List<NotificationTarget>> getNotificationTargets({
    required ApiAuthSnapshot authSnapshot,
  }) => targets();

  @override
  Future<List<NotificationEvent>> getNotificationEvents({
    required ApiAuthSnapshot authSnapshot,
  }) async => const <NotificationEvent>[];

  @override
  Future<NotificationTarget> updateNotificationTarget(
    String targetId, {
    bool? enabled,
    List<String>? events,
    String? delivery,
    String? replacementUrl,
    required ApiAuthSnapshot authSnapshot,
  }) async {
    updatedTargets.add(targetId);
    return _pager;
  }

  /// The notification master toggle as each mirror reached the server;
  /// the first mirror waits for [mirrorHeld] when it is set.
  final mirrored = <bool?>[];

  /// Every mirror as it reached the server, shared by the clients of one
  /// account when a test sets it.
  List<bool?> reached = <bool?>[];
  final mirrorAsked = Completer<void>();
  Completer<void>? mirrorHeld;
  final _mirrorWaits = <(int, Completer<void>)>[];

  /// Completes once [count] mirrors reached the server.
  Future<void> mirrorsSettled(int count) {
    if (mirrored.length >= count) return Future<void>.value();
    final settled = Completer<void>();
    _mirrorWaits.add((count, settled));
    return settled.future;
  }

  @override
  Future<ServerUserSettings> updateUserNotificationSettings({
    bool? notificationEnabled,
    bool? notificationSound,
    bool? notificationSoundAlways,
  }) async {
    final held = mirrorHeld;
    mirrorHeld = null;
    if (!mirrorAsked.isCompleted) mirrorAsked.complete();
    await held?.future;
    mirrored.add(notificationEnabled);
    reached.add(notificationEnabled);
    for (final wait in _mirrorWaits.toList()) {
      if (mirrored.length >= wait.$1) {
        _mirrorWaits.remove(wait);
        wait.$2.complete();
      }
    }
    return ServerUserSettings(notificationEnabled: notificationEnabled);
  }

  @override
  Future<AccountMetadata> getAccountMetadata() => metadata();

  @override
  Future<AccountMetadata> updateAccountMetadata({
    required String name,
    required String profileImageUrl,
    String? bio,
    String? gender,
    String? dateOfBirth,
    String? timezone,
  }) async {
    saved.add(name);
    if (!saves) throw StateError('saved under the account in use now');
    savedBios.add(bio);
    final updated = AccountMetadata(
      id: 'user-1',
      email: 'ava@example.com',
      name: name,
      role: 'user',
      isActive: true,
      profileImageUrl: profileImageUrl,
      bio: bio,
    );
    metadata = () async => updated;
    onSaved?.call();
    return updated;
  }

  @override
  Future<Map<String, dynamic>?> getModelDetails(String modelId) =>
      details(modelId);

  @override
  Future<Map<String, dynamic>?> updateModelSystemPrompt(
    String modelId,
    String? systemPrompt,
  ) async {
    prompts.add(modelId);
    return null;
  }

  @override
  Future<bool> deleteAllChatsRaw({ApiAuthSnapshot? authSnapshot}) async {
    deletedAll++;
    return true;
  }
}
