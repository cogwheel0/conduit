import 'dart:typed_data';

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/composer_recordings.dart';

part 'composer_recordings_dao.g.dart';

@DriftAccessor(tables: [ComposerRecordings, ComposerRecordingChunks])
class ComposerRecordingsDao extends DatabaseAccessor<AppDatabase>
    with _$ComposerRecordingsDaoMixin {
  ComposerRecordingsDao(super.db);

  Future<String> _resolve(String scope, String chatId) =>
      attachedDatabase.composerDraftsDao.resolveChatId(scope, chatId);

  Future<void> _checkChat(String scope, String chatId) async {
    if (scope != 'chat') return;
    final chat = await attachedDatabase.chatsDao.getChat(chatId);
    if (chat == null || chat.deleted) {
      throw StateError('The chat is no longer available for recording');
    }
  }

  Future<void> create({
    required String id,
    required String scope,
    required String chatId,
    required int createdAt,
  }) => attachedDatabase.transaction(() async {
    final resolved = await _resolve(scope, chatId);
    await _checkChat(scope, resolved);
    await into(composerRecordings).insert(
      ComposerRecordingsCompanion.insert(
        id: id,
        scope: scope,
        chatId: resolved,
        createdAt: createdAt,
      ),
    );
  });

  Stream<List<ComposerRecording>> watch(String scope, String chatId) async* {
    final resolved = await _resolve(scope, chatId);
    yield* (select(composerRecordings)
          ..where((r) => r.scope.equals(scope) & r.chatId.equals(resolved))
          ..orderBy([(r) => OrderingTerm.asc(r.createdAt)]))
        .watch();
  }

  Future<void> append(String id, Uint8List pcm, {bool longForm = false}) =>
      attachedDatabase.transaction(() async {
        if (pcm.isEmpty || pcm.length.isOdd) {
          throw ArgumentError('PCM must contain complete 16-bit samples');
        }
        final row = await (select(
          composerRecordings,
        )..where((r) => r.id.equals(id))).getSingleOrNull();
        // Discard or chat deletion wins over an already queued capture chunk.
        if (row == null) return;
        await _checkChat(row.scope, row.chatId);
        if (!longForm && row.byteCount + pcm.length > 32000 * 600) {
          throw StateError('Recording exceeds the ten-minute limit');
        }
        await into(composerRecordingChunks).insert(
          ComposerRecordingChunksCompanion.insert(
            recordingId: id,
            sequence: row.byteCount,
            pcm: pcm,
          ),
        );
        await (update(composerRecordings)..where((r) => r.id.equals(id))).write(
          ComposerRecordingsCompanion(
            byteCount: Value(row.byteCount + pcm.length),
          ),
        );
      });

  Stream<Uint8List> pcmChunks(String id) async* {
    var offset = 0;
    while (true) {
      final page =
          await (select(composerRecordingChunks)
                ..where(
                  (r) =>
                      r.recordingId.equals(id) &
                      r.sequence.isBiggerOrEqualValue(offset),
                )
                ..orderBy([(r) => OrderingTerm.asc(r.sequence)])
                ..limit(16))
              .get();
      if (page.isEmpty) return;
      for (final chunk in page) {
        yield chunk.pcm;
        offset = chunk.sequence + chunk.pcm.length;
      }
    }
  }

  Future<Uint8List> readPcm(String id) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in pcmChunks(id)) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<void> discard(String id) async {
    await (delete(composerRecordings)..where((r) => r.id.equals(id))).go();
  }

  Future<void> discardChat(String scope, String chatId) async {
    final resolved = await _resolve(scope, chatId);
    await (delete(
      composerRecordings,
    )..where((r) => r.scope.equals(scope) & r.chatId.equals(resolved))).go();
  }

  Future<void> remap(String scope, String from, String to) async {
    await (update(composerRecordings)
          ..where((r) => r.scope.equals(scope) & r.chatId.equals(from)))
        .write(ComposerRecordingsCompanion(chatId: Value(to)));
  }
}
