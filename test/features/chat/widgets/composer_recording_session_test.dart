import 'dart:async';
import 'dart:typed_data';

import 'package:conduit/features/chat/controllers/composer_recording_session.dart';
import 'package:conduit/features/chat/providers/composer_draft_provider.dart';
import 'package:conduit/features/chat/services/recording_activity_service.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/chat/composer/composer_draft_store.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_mode_ports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class _Activity extends RecordingActivityService {
  Future<void> Function()? stop;
  bool stopImmediately = false;
  final ended = <String>[];

  @override
  Future<bool> start(
    String id,
    Future<void> Function() stop, {
    double Function()? savedSeconds,
  }) async {
    this.stop = stop;
    if (stopImmediately) await stop();
    return true;
  }

  @override
  Future<void> end(String id) async => ended.add(id);
}

class _Background implements VoiceBackgroundPort {
  final calls = <String>[];
  Completer<void>? grant;
  @override
  Future<void> startVoiceLease({
    required String leaseId,
    required bool requiresMicrophone,
  }) async {
    expect(requiresMicrophone, isTrue);
    calls.add('start:$leaseId');
    await grant?.future;
  }

  @override
  Future<void> stopVoiceLease(String leaseId) async =>
      calls.add('stop:$leaseId');
  @override
  Future<bool> keepAlive() async => true;
  @override
  Future<void> setExternalAudioSessionOwner(bool isExternal) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late ComposerDraftStore store;
  late _Activity activity;

  ComposerDraftContext owner({bool temporary = false}) => (
    owner: (
      backend: 'account',
      account: 'demo',
      principal: 'reader',
      session: null,
    ),
    scope: 'new:',
    chatId: '',
    store: temporary ? null : store,
    temporary: temporary,
  );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    store = ComposerDraftStore(db);
    activity = _Activity();
  });
  tearDown(() => db.close());

  test(
    'a microphone lease granted after stop is released for the same recording',
    () async {
      final background = _Background()..grant = Completer<void>();
      final session = await ComposerRecordingSession.begin(
        owner(),
        activity: activity,
        background: background,
        onSaveFailure: () => fail('Unexpected save failure'),
        stop: (session) => session.close(),
      );
      final preparing = session.sink.prepare!();
      expect(background.calls, ['start:${session.id}']);
      await session.close();
      background.grant!.complete();
      await preparing;
      expect(background.calls, [
        'start:${session.id}',
        'stop:${session.id}',
        'stop:${session.id}',
      ]);
      expect(activity.stop, isNull);
    },
  );

  test(
    'lock-screen stop acknowledges saved tail before network transcription',
    () async {
      final transcription = Completer<void>();
      final bytes = Uint8List.fromList([1, 0, 2, 0]);
      final session = await ComposerRecordingSession.begin(
        owner(),
        activity: activity,
        onSaveFailure: () => fail('Unexpected save failure'),
        stop: (session) async {
          session.sink.add(bytes);
          await session.close();
          await transcription.future;
        },
      );
      session.sink.add(bytes);
      await activity.stop!().timeout(const Duration(seconds: 2));
      expect(transcription.isCompleted, isFalse);
      expect(await store.recordings.readPcm(session.id), [...bytes, ...bytes]);
      expect(activity.ended, [session.id]);
      transcription.complete();
      await session.close();
      expect(activity.ended, [session.id]);
    },
  );

  test('an immediate stop as audio begins cannot strand capture', () async {
    activity.stopImmediately = true;
    final session = await ComposerRecordingSession.begin(
      owner(),
      activity: activity,
      onSaveFailure: () => fail('Unexpected save failure'),
      stop: (session) => session.close(),
    ).timeout(const Duration(seconds: 2));
    session.sink.add(Uint8List.fromList([1, 0]));
    await session.close();
    expect(activity.ended, [session.id]);
    expect(await store.recordings.readPcm(session.id), [1, 0]);
  });

  test(
    'Temporary Chat capture never writes audio or recording metadata',
    () async {
      final session = await ComposerRecordingSession.begin(
        owner(temporary: true),
        activity: activity,
        onSaveFailure: () => fail('Unexpected save failure'),
        stop: (session) => session.close(),
      );
      session.sink.add(Uint8List.fromList([1, 0, 2, 0]));
      await session.flush();
      await session.close();
      expect(session.writer, isNull);
      expect(await store.recordings.watch('new:', '').first, isEmpty);
    },
  );
}
