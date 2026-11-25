import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/platform/protocol_channel_host.dart';
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/ports.dart';
import 'package:conduit_core/services/settings_service.dart'
    show AppSettingsHostDefaults;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduit_services/conduit_services.dart';
import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod/riverpod.dart';

/// The protocol host's binding over platform channels, with the test's
/// messenger playing the Swift client.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporary;
  late _Swift swift;
  late ProtocolChannelHost host;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('protocol_channel_host');
    addTearDown(() => temporary.deleteSync(recursive: true));
    PackageInfo.setMockInitialValues(
      appName: 'Conduit',
      packageName: 'app.conduit.test',
      version: '9.9.9',
      buildNumber: '1',
      buildSignature: '',
    );
    swift = _Swift();
    addTearDown(swift.detach);
  });

  /// The binding over a core of its own, as the app's root container would
  /// be, listening, with the client told it is ready.
  late _Paths paths;
  late Map<Object?, Object?> ready;

  Future<void> startHost({int limit = 64}) async {
    final core = await _startCore(temporary);
    addTearDown(core.dispose);
    addTearDown(core.beginShutdown);
    paths = _Paths(temporary);
    host = ProtocolChannelHost(
      container: core.container,
      paths: paths,
      maxUnacknowledged: limit,
    );
    addTearDown(host.dispose);
    final told = swift.nextControl('ready');
    host.listen();
    ready = await told;
  }

  test('the host runs only with the define, and only on iOS', () {
    check(protocolHostRuns(defined: true, platform: TargetPlatform.iOS))
        .isTrue();
    check(protocolHostRuns(defined: true, platform: TargetPlatform.android))
        .isFalse();
    check(protocolHostRuns(defined: false, platform: TargetPlatform.iOS))
        .isFalse();
  });

  test('without the define, the app listens on none of the channels', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    startProtocolChannelHost(container);
    check(await swift.control(<String, Object>{'op': 'hello'})).isNull();
    check(await swift.rpc('phone', '{}')).isNull();
  });

  test('a client says hello, opens a session, handshakes, calls, and hears '
      'the events it subscribed to', () async {
    await startHost();
    final hello = await swift.control(<String, Object>{'op': 'hello'});
    check(hello).isA<Map<Object?, Object?>>()
      ..has((it) => it['op'], 'op').equals('ready')
      ..has(
        (it) => it['protocolVersion'],
        'protocolVersion',
      ).equals(kConduitProtocolVersion)
      // The same start as the ready the host sent, so the client opens once.
      ..has((it) => it['start'], 'start').equals(ready['start']);
    check(
      await swift.control(<String, Object>{'op': 'open', 'session': 'phone'}),
    ).isA<Map<Object?, Object?>>().has((it) => it['ok'], 'ok').equals(true);

    final handshake = HandshakeResponse.fromJson(
      await swift.call(
        'phone',
        ConduitMethods.systemHandshake,
        const HandshakeRequest(
          protocolVersion: kConduitProtocolVersion,
          clientName: 'test',
          clientVersion: '0.0.0',
          windowKind: WindowKind.main,
          locale: 'en',
        ).toJson(),
      ),
    );
    check(handshake.platform).equals('ios');
    check(handshake.daemonVersion).equals('9.9.9');
    check(handshake.capabilities.notOffered).deepEquals(HostNamespace.values);

    final heard = swift.nextEvent('phone');
    await swift.call(
      'phone',
      ConduitMethods.eventsSubscribe,
      const EventSubscription().toJson(),
    );
    // The services announce themselves as they start, numbered per session.
    check(await heard)
      ..has((it) => it['event'], 'event').isA<String>()
      ..has((it) => it['seq'], 'seq').isA<int>();
  });

  group('while the host is starting', () {
    late Completer<void> started;

    Future<Object?> open() =>
        swift.control(<String, Object>{'op': 'open', 'session': 'phone'});

    setUp(() async {
      await startHost();
      started = Completer<void>();
      addTearDown(() {
        if (!started.isCompleted) started.complete();
      });
      paths.gate = started;
    });

    test('a second open is refused, a message for it is answered closed, '
        'hello changes nothing, and a close cancels the open', () async {
      final opening = open();
      check(await open())
          .isA<Map<Object?, Object?>>()
          .has((it) => it['error'], 'error')
          .equals('open');
      check(await swift.rpc('phone', '{}')).equals('closed');
      check(await swift.control(<String, Object>{'op': 'hello'}))
          .isA<Map<Object?, Object?>>()
          .has((it) => it['op'], 'op')
          .equals('ready');
      check(
        await swift.control(<String, Object>{
          'op': 'close',
          'session': 'phone',
        }),
      ).isA<Map<Object?, Object?>>().has((it) => it['ok'], 'ok').equals(true);
      started.complete();
      check(await opening)
          .isA<Map<Object?, Object?>>()
          .has((it) => it['error'], 'error')
          .equals('closed');
      check(await swift.rpc('phone', '{}')).equals('closed');
      // Nothing holds the name: it opens again.
      check(await open())
          .isA<Map<Object?, Object?>>()
          .has((it) => it['ok'], 'ok')
          .equals(true);
    });

    test('stopping the host answers the open stopped', () async {
      final opening = open();
      final stopped = host.dispose();
      started.complete();
      await stopped;
      check(await opening)
          .isA<Map<Object?, Object?>>()
          .has((it) => it['error'], 'error')
          .equals('stopped');
    });
  });

  test('a start that fails is answered unavailable, on the byte channel '
      'without waiting on the client, and the next client starts it again',
      () async {
    await startHost();
    // Two starts fail: an open's, then a byte stream's.
    paths.failing = 2;
    check(
          await swift.control(<String, Object>{
            'op': 'open',
            'session': 'phone',
          }),
        )
        .isA<Map<Object?, Object?>>()
        .has((it) => it['error'], 'error')
        .equals('unavailable');

    final taken = Completer<void>();
    addTearDown(() {
      if (!taken.isCompleted) taken.complete();
    });
    // This client takes the host's frames only once its own open is taken.
    swift.holdFrames = taken;
    Uint8List download(int stream) => ByteFrame(
      stream,
      ByteFrameKind.open,
      payload: _json(<String, Object>{
        'method': 'GET',
        'path': '/files/server/file',
      }),
    ).encode();
    final failed = swift.answer(1);
    check(await swift.bytes(download(1))).isNotNull();
    taken.complete();
    check(utf8.decode((await failed).single.payload)).equals('unavailable');

    // The next client starts it again, on either channel.
    check(
          await swift.control(<String, Object>{
            'op': 'open',
            'session': 'phone',
          }),
        )
        .isA<Map<Object?, Object?>>()
        .has((it) => it['ok'], 'ok')
        .equals(true);
    final answered = swift.answer(2);
    await swift.bytes(download(2));
    await swift.bytes(ByteFrame(2, ByteFrameKind.end).encode());
    check((await answered).map((f) => f.kind))
        .contains(ByteFrameKind.responseHead);
  });

  test('a binding started again names a start of its own', () async {
    await startHost();
    final first = ready['start'];
    check(first).isA<String>().isNotEmpty();
    await host.dispose();
    await startHost();
    check(ready['start'])
      ..isA<String>()
      ..not((it) => it.equals(first));
  });

  test('a message for a session that is gone is answered, not dropped, and '
      'a session the RPC channel could not address is not opened', () async {
    await startHost();
    check(await swift.rpc('nobody', '{}')).equals('closed');
    for (final id in <String>['', '\n', 'phone\nother']) {
      check(
            because: jsonEncode(id),
            await swift.control(<String, Object>{'op': 'open', 'session': id}),
          )
          .isA<Map<Object?, Object?>>()
          .has((it) => it['error'], 'error')
          .equals('no such request');
    }
  });

  test('a session whose message the client does not take is ended, and the '
      'client is told', () async {
    await startHost();
    await swift.control(<String, Object>{'op': 'open', 'session': 'phone'});
    final closed = swift.nextControl('closed');
    // No handler on the client's side: the host's message goes unanswered.
    swift.stopTakingRpc();
    await swift.rpc(
      'phone',
      jsonEncode(<String, Object>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': ConduitMethods.systemHandshake,
        'params': const HandshakeRequest(
          protocolVersion: kConduitProtocolVersion,
          clientName: 'test',
          clientVersion: '0.0.0',
          windowKind: WindowKind.main,
          locale: 'en',
        ).toJson(),
      }),
    );
    check((await closed)['session']).equals('phone');
    check(await swift.rpc('phone', '{}')).equals('closed');
  });

  test(
    'byte routes travel as frames both ways, each answered when taken',
    () async {
      await startHost();
      // A download: no account here, so its answer is the refusal.
      final download = swift.answer(1);
      check(
        await swift.bytes(
          ByteFrame(
            1,
            ByteFrameKind.open,
            payload: _json(<String, Object>{
              'method': 'GET',
              'path': '/files/server/file',
            }),
          ).encode(),
        ),
      ).isNotNull();
      await swift.bytes(ByteFrame(1, ByteFrameKind.end).encode());
      final downloaded = await download;
      check(downloaded.map((f) => f.kind)).contains(ByteFrameKind.responseHead);
      check(downloaded.last.kind).equals(ByteFrameKind.end);

      // An upload of two chunks, each answered once taken.
      final upload = swift.answer(2);
      await swift.bytes(
        ByteFrame(
          2,
          ByteFrameKind.open,
          payload: _json(<String, Object>{
            'method': 'POST',
            'path': ConduitHttpRoutes.upload,
            'headers': <String, String>{'x-conduit-filename': 'tide.txt'},
          }),
        ).encode(),
      );
      for (final byte in <int>[1, 2]) {
        check(
          await swift.bytes(
            ByteFrame(
              2,
              ByteFrameKind.chunk,
              payload: Uint8List.fromList(
                List<int>.filled(ByteFrame.maxChunk, byte),
              ),
            ).encode(),
          ),
        ).isNotNull();
      }
      await swift.bytes(ByteFrame(2, ByteFrameKind.end).encode());
      // Refused before its body was read (no account), so the host told the
      // client to stop sending first; the chunks sent anyway were still taken.
      final uploaded = await upload;
      check(uploaded.map((f) => f.kind)).contains(ByteFrameKind.responseHead);
      check(uploaded.last.kind).equals(ByteFrameKind.end);
    },
  );
}

/// The core with nothing of the device's: preferences, credentials and
/// databases in memory, Hive in [directory], connectivity always there.
Future<CoreRuntime> _startCore(Directory directory) async {
  PreferencesStore.debugReset();
  PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
  addTearDown(() {
    PreferencesStore.debugReset();
    PreferencesStore.installLoader(FlutterKeyValueStore.load);
  });
  await PreferencesStore.ensureInitialized();
  Hive.init('${directory.path}/hive');
  final boxes = <Box<dynamic>>[];
  Future<Box<dynamic>> open(String name) async {
    final box = await Hive.openBox<dynamic>(name);
    boxes.add(box);
    return box;
  }

  return CoreRuntime.start(
    host: CoreHostBindings(
      secureStore: InMemorySecureKeyValueStore(),
      hiveBoxes: HiveBoxes(
        preferences: await open(HiveBoxNames.preferences),
        caches: await open(HiveBoxNames.caches),
        attachmentQueue: await open(HiveBoxNames.attachmentQueue),
        metadata: await open(HiveBoxNames.metadata),
      ),
      databaseOpener: _MemoryDatabases(directory),
      worker: const DaemonWorkerPort(),
      connectivity: const AlwaysOnlineConnectivityPort(),
      close: () async {
        for (final box in boxes) {
          await box.close();
        }
      },
    ),
    policy: const CoreHostPolicy(
      settingsDefaults: AppSettingsHostDefaults(
        sendOnEnter: true,
        notificationsEnabled: true,
      ),
      readAloudLiveDeviceSpeech: true,
    ),
  );
}

final class _MemoryDatabases implements DatabaseOpenerPort {
  _MemoryDatabases(this._directory);

  final Directory _directory;

  @override
  QueryExecutor open(String serverId) => NativeDatabase.memory();

  @override
  Future<Directory> databaseDirectory() async => _directory;
}

Uint8List _json(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

/// The app's directories, in a temporary directory.
final class _Paths implements PathsPort {
  _Paths(this._root);

  final Directory _root;

  /// When set, the host's start waits for it.
  Completer<void>? gate;

  /// How many of the next starts fail.
  int failing = 0;

  @override
  Future<Directory> applicationSupport() async {
    await gate?.future;
    if (failing > 0) {
      failing--;
      throw const FileSystemException('not there yet');
    }
    return _root;
  }

  @override
  Future<Directory> cache() async => _root;

  @override
  Future<Directory> logs() async => _root;

  @override
  Future<Directory> staging() async => _root;
}

/// The Swift client, on the test's messenger.
final class _Swift {
  _Swift() {
    _messenger
      ..setMockMessageHandler(ProtocolChannelHost.controlChannel, (data) async {
        final message = _controlCodec.decodeMessage(data);
        if (message is Map) _control.add(message);
        return null;
      })
      ..setMockMessageHandler(ProtocolChannelHost.rpcChannel, _takeRpc)
      ..setMockMessageHandler(ProtocolChannelHost.bytesChannel, (data) async {
        final bytes = data!.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        _frames.add(ByteFrame.decode(Uint8List.fromList(bytes)));
        await holdFrames?.future;
        return ByteData(0);
      });
  }

  static const _controlCodec = StandardMessageCodec();
  static const _stringCodec = StringCodec();

  final TestDefaultBinaryMessenger _messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final StreamController<Map<Object?, Object?>> _control =
      StreamController<Map<Object?, Object?>>.broadcast(sync: true);
  final StreamController<(String, Map<String, dynamic>)> _rpcIn =
      StreamController<(String, Map<String, dynamic>)>.broadcast(sync: true);
  final StreamController<ByteFrame> _frames =
      StreamController<ByteFrame>.broadcast(sync: true);
  var _nextId = 1;

  /// When set, the host's frames are seen at once but taken only once it
  /// completes.
  Completer<void>? holdFrames;

  Future<ByteData?> _takeRpc(ByteData? data) async {
    final message = _stringCodec.decodeMessage(data)!;
    final at = message.indexOf('\n');
    _rpcIn.add((
      message.substring(0, at),
      jsonDecode(message.substring(at + 1)) as Map<String, dynamic>,
    ));
    return _stringCodec.encodeMessage('');
  }

  void stopTakingRpc() =>
      _messenger.setMockMessageHandler(ProtocolChannelHost.rpcChannel, null);

  void detach() {
    for (final channel in <String>[
      ProtocolChannelHost.controlChannel,
      ProtocolChannelHost.rpcChannel,
      ProtocolChannelHost.bytesChannel,
    ]) {
      _messenger.setMockMessageHandler(channel, null);
    }
  }

  Future<Map<Object?, Object?>> nextControl(String op) =>
      _control.stream.firstWhere((m) => m['op'] == op);

  Future<Map<String, dynamic>> nextEvent(String session) => _rpcIn.stream
      .firstWhere((m) => m.$1 == session && m.$2['method'] == 'event')
      .then((m) => m.$2['params'] as Map<String, dynamic>);

  /// The frames of [stream]'s answer, through its `end` or `error`.
  Future<List<ByteFrame>> answer(int stream) {
    final frames = <ByteFrame>[];
    final done = Completer<List<ByteFrame>>();
    late final StreamSubscription<ByteFrame> subscription;
    subscription = _frames.stream.where((f) => f.stream == stream).listen((f) {
      frames.add(f);
      if (f.kind == ByteFrameKind.end || f.kind == ByteFrameKind.error) {
        unawaited(subscription.cancel());
        done.complete(frames);
      }
    });
    return done.future;
  }

  Future<ByteData?> _send(String channel, ByteData? message) {
    final reply = Completer<ByteData?>();
    unawaited(
      _messenger.handlePlatformMessage(channel, message, reply.complete),
    );
    return reply.future;
  }

  Future<Object?> control(Map<String, Object> message) async =>
      _controlCodec.decodeMessage(
        await _send(
          ProtocolChannelHost.controlChannel,
          _controlCodec.encodeMessage(message),
        ),
      );

  Future<String?> rpc(String session, String message) async =>
      _stringCodec.decodeMessage(
        await _send(
          ProtocolChannelHost.rpcChannel,
          _stringCodec.encodeMessage('$session\n$message'),
        ),
      );

  Future<ByteData?> bytes(Uint8List frame) =>
      _send(ProtocolChannelHost.bytesChannel, ByteData.sublistView(frame));

  /// [method]'s result, through [session].
  Future<Map<String, dynamic>> call(
    String session,
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final id = _nextId++;
    final answered = _rpcIn.stream.firstWhere(
      (m) => m.$1 == session && m.$2['id'] == id,
    );
    await rpc(
      session,
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': ?params,
      }),
    );
    final answer = (await answered).$2;
    if (answer['error'] case final Map<String, dynamic> error) {
      throw StateError('$method failed: ${error['message']}');
    }
    return (answer['result'] as Map).cast<String, dynamic>();
  }
}
