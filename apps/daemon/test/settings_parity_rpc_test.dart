@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
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
    registerEventSink(peer, onEvent: events.add);
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
      expect(s.sendOnEnter, isFalse);
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
      events.clear();
      final after = await patch(
        const AppSettingsPatch(
          sendOnEnter: true,
          temporaryChatByDefault: true,
          showComposerNotesButton: false,
          quickPills: <String>['web', 'web', ' image '],
          inlineMessageActions: <String>['regenerate', 'copy'],
          advancedFeaturesEnabled: true,
          citationShowTitles: true,
        ),
      );
      expect(after.sendOnEnter, isTrue);
      expect(after.temporaryChatByDefault, isTrue);
      expect(after.showComposerNotesButton, isFalse);
      expect(after.quickPills, <String>['web', 'image']);
      expect(after.inlineMessageActions, <String>['regenerate', 'copy']);
      expect(after.advancedFeaturesEnabled, isTrue);
      expect(after.citationShowTitles, isTrue);
      // Untouched.
      expect(after.computerEnabled, isTrue);
      expect(await read(), after);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        events.map((e) => e.event),
        contains(ConduitEvents.settingsChanged),
      );
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
              sendOnEnter: false,
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
        expect((await read()).sendOnEnter, isTrue);

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

  group('without an Open WebUI account', () {
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
}
