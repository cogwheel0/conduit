import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../../database/app_database.dart';

/// Audio stays in the owning account's local database. No file paths, chat
/// titles, or audio bytes are included in sync or server chat payloads.
class ComposerRecordingStore {
  ComposerRecordingStore(this._database);

  final AppDatabase _database;

  Stream<List<ComposerRecording>> watch(String scope, String chatId) =>
      _database.composerRecordingsDao.watch(scope, chatId);

  Future<ComposerRecordingWriter> begin({
    required String id,
    required String scope,
    required String chatId,
    required void Function() onFailure,
  }) async {
    await _database.trackComposerDraftWrite(
      () => _database.composerRecordingsDao.create(
        id: id,
        scope: scope,
        chatId: chatId,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return ComposerRecordingWriter(
      (pcm) => _database.trackComposerDraftWrite(
        () => _database.composerRecordingsDao.append(id, pcm),
      ),
      onFailure: onFailure,
    );
  }

  Future<Uint8List> readPcm(String id) =>
      _database.composerRecordingsDao.readPcm(id);

  Future<Uint8List> readWav(String id) async => pcm16Wav(await readPcm(id));

  Future<void> discard(String id) => _database.trackComposerDraftWrite(
    () => _database.composerRecordingsDao.discard(id),
  );
}

/// Buffers at most one second during healthy capture. A flush commits each
/// chunk transactionally; an interrupted process can restore every commit.
/// Failed writes retain their bytes in memory for an explicit retry.
class ComposerRecordingWriter {
  ComposerRecordingWriter(this._append, {required this.onFailure}) {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(flush().catchError((Object _) {}));
    });
  }

  final Future<void> Function(Uint8List) _append;
  final void Function() onFailure;
  final _pending = <Uint8List>[];
  Future<void> _tail = Future<void>.value();
  Timer? _timer;
  bool _closed = false;
  bool _failed = false;
  int _savedBytes = 0;
  int get savedBytes => _savedBytes;

  void add(Uint8List pcm) {
    if (_closed || pcm.isEmpty) return;
    _pending.add(Uint8List.fromList(pcm));
  }

  Future<void> flush() {
    final write = _tail.then((_) async {
      if (_pending.isEmpty) return;
      final count = _pending.length;
      final bytes = BytesBuilder(copy: false);
      for (final chunk in _pending.take(count)) {
        bytes.add(chunk);
      }
      try {
        final pcm = bytes.takeBytes();
        await _append(pcm);
        _savedBytes += pcm.length;
        _pending.removeRange(0, count);
        _failed = false;
      } catch (_) {
        if (!_failed) onFailure();
        _failed = true;
        rethrow;
      }
    });
    _tail = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }

  Future<void> close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    return flush();
  }
}

/// Mono 16-bit little-endian PCM at 16 kHz, shared by capture and retry.
Uint8List pcm16Wav(Uint8List pcm) {
  if (pcm.length.isOdd) throw ArgumentError('Incomplete PCM sample');
  final wav = Uint8List(44 + pcm.length);
  final header = ByteData.sublistView(wav);
  void text(int offset, String value) =>
      wav.setRange(offset, offset + 4, ascii.encode(value));
  text(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 16000, Endian.little);
  header.setUint32(28, 32000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  text(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
  wav.setRange(44, wav.length, pcm);
  return wav;
}
