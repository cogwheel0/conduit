@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/account_metadata.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
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
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
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
        events: <String>[ConduitEvents.settingsChanged],
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
    late bool previousWarning;

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
    });
    tearDown(() async {
      api.dispose();
      await db.close();
    });

    /// Set to hold `serverAboutInfo`: completes [aboutAsked] when asked.
    Completer<void>? aboutHeld;
    Completer<void>? aboutAsked;

    ProviderContainer containerWith() {
      final container = ProviderContainer(
        overrides: [
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
      final saving = CoreSettingsService(container).set(
        const AppSettingsPatch(computerEnabled: false, sendOnEnter: false),
      );
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
      final saving = CoreSettingsService(container).set(
        const AppSettingsPatch(computerEnabled: false, sendOnEnter: false),
      );
      // Account B becomes active with no sign-in: the session epoch stays.
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-b');
      settings.written.complete();
      await expectLater(saving, refused(ConduitErrorCodes.sessionExpired));
      expect(settings.calls, <String>['computerEnabled']);
    });

    test('a birth date past its month is refused', () async {
      final profiles = ProfileService(containerWith());
      await expectLater(
        profiles.update(const ProfileEdit(dateOfBirth: '2020-01-42')),
        refused(ConduitErrorCodes.invalidParams),
      );
      expect(api.saved, isEmpty);
    });

    test("a profile save survives the sign-in refresh core makes after it",
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
      final saved = await profiles.update(const ProfileEdit(bio: 'A newer bio'));
      expect(saved.bio, 'A newer bio');
      expect(api.savedBios, <String?>['A newer bio']);
    });

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
