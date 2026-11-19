import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/chat/composer/composer_draft_context.dart';
import 'package:conduit_core/features/chat/composer/composer_draft_store.dart';
import 'package:conduit_core/features/chat/composer/composer_recording_store.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:uuid/uuid.dart';

import 'dictation_service.dart';
import 'drafts_service.dart';

/// `recordings.*` and `GET /recordings/{id}`: a dictation's audio, kept with
/// the unsent draft as the phone keeps it (core's [ComposerRecordingStore]).
///
/// The window sends the audio as it records, a second at a time; each
/// `recordings.append` answers once its audio is committed, so a crash of
/// the window or of this daemon loses at most the second in flight. The
/// draft's recordings are listed beside the composer until it is sent
/// (then the window discards them) or until each is discarded.
///
/// A temporary or read-only chat keeps no draft, and so no recordings: the
/// window then keeps the audio itself for as long as it transcribes it.
final class RecordingsService {
  RecordingsService({
    required DraftsService drafts,
    required DictationService dictation,
  }) : _drafts = drafts,
       _dictation = dictation;

  final DraftsService _drafts;
  final DictationService _dictation;
  final Map<String, _Open> _open = <String, _Open>{};

  /// 16 kHz mono 16-bit: 32 bytes a millisecond.
  static int durationMs(int byteCount) => byteCount ~/ 32;

  Future<RecordingList> list(RecordingTarget target) async {
    final context = await _drafts.contextFor(target.chatId, target.folderId);
    final store = context.store;
    if (store == null) return const RecordingList(stored: false);
    return RecordingList(recordings: await _rows(store, context));
  }

  Future<List<RecordingDto>> _rows(
    ComposerDraftStore store,
    ComposerDraftContext context,
  ) async {
    final rows = await store.recordings
        .watch(context.scope, context.chatId)
        .first;
    return <RecordingDto>[
      for (final ComposerRecording row in rows)
        RecordingDto(
          id: row.id,
          createdAt: row.createdAt,
          byteCount: row.byteCount,
          durationMs: durationMs(row.byteCount),
        ),
    ];
  }

  /// Starts a recording for [target]'s draft, owned by window [sessionId]
  /// (its recordings close when it goes).
  Future<RecordingStarted> begin(
    RecordingTarget target, {
    required String sessionId,
  }) async {
    final context = await _drafts.contextFor(target.chatId, target.folderId);
    final store = context.store;
    if (store == null) return const RecordingStarted(stored: false);
    final id = const Uuid().v4();
    final ComposerRecordingWriter writer;
    try {
      writer = await store.recordings.begin(
        id: id,
        scope: context.scope,
        chatId: context.chatId,
        // `append` reports a failed write itself.
        onFailure: () {},
      );
    } on StateError {
      // The chat was deleted meanwhile: nothing to keep it under.
      return const RecordingStarted(stored: false);
    }
    _open[id] = _Open(store.recordings, writer, sessionId);
    return RecordingStarted(id: id);
  }

  /// Commits [chunk]'s audio, and any a failed write held back: an empty
  /// chunk just tries those again.
  Future<RecordingSaved> append(RecordingChunk chunk) async {
    final open = _open[chunk.id] ?? (throw _notOpen(chunk.id));
    final Uint8List pcm;
    try {
      pcm = base64Decode(chunk.pcm);
    } on FormatException {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'the audio is not base64',
      );
    }
    if (pcm.length.isOdd) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'incomplete 16-bit samples',
      );
    }
    open.writer.add(pcm);
    try {
      await open.writer.flush();
    } on Object catch (error) {
      DebugLogger.warning(
        'recording-write-failed',
        scope: 'daemon/recordings',
        data: <String, Object?>{'error': error.runtimeType.toString()},
      );
      throw RpcError(
        code: ConduitErrorCodes.serverError,
        debugMessage: 'the recording could not be saved: $error',
        retryable: true,
      );
    }
    return RecordingSaved(id: chunk.id, savedBytes: open.writer.savedBytes);
  }

  /// Ends recording [ref]; one with nothing in it is not kept.
  Future<RecordingSaved> close(RecordingRef ref) async {
    final open = _open.remove(ref.id) ?? (throw _notOpen(ref.id));
    return _close(ref.id, open);
  }

  Future<RecordingSaved> _close(String id, _Open open) async {
    try {
      await open.writer.close();
    } on Object {
      // What was committed stays; the rest is lost with the window.
    }
    if (open.writer.savedBytes == 0) {
      await open.store.discard(id);
      return RecordingSaved(id: id, discarded: true);
    }
    return RecordingSaved(id: id, savedBytes: open.writer.savedBytes);
  }

  /// Closes what window [sessionId] left recording: it crashed or quit, and
  /// what it sent is kept for its next launch.
  Future<void> closeOwnedBy(String sessionId) async {
    final ids = <String>[
      for (final MapEntry(:key, :value) in _open.entries)
        if (value.sessionId == sessionId) key,
    ];
    for (final id in ids) {
      final open = _open.remove(id);
      if (open != null) await _close(id, open);
    }
  }

  Future<RecordingList> discard(RecordingRef ref) async {
    final context = await _drafts.contextFor(ref.chatId, ref.folderId);
    final store = context.store;
    if (store == null) return const RecordingList(stored: false);
    final open = _open.remove(ref.id);
    if (open != null) {
      try {
        await open.writer.close();
      } on Object {
        // Discarded either way.
      }
    }
    await store.recordings.discard(ref.id);
    return RecordingList(recordings: await _rows(store, context));
  }

  /// Recording [ref] as 16 kHz mono WAV.
  Future<Uint8List> wav(RecordingRef ref) async {
    final context = await _drafts.contextFor(ref.chatId, ref.folderId);
    final store = context.store;
    if (store == null) throw _missing(ref.id);
    // Only what this draft holds: an id from another draft reads nothing.
    final known = await _rows(store, context);
    if (!known.any((r) => r.id == ref.id)) throw _missing(ref.id);
    final pcm = await store.recordings.readPcm(ref.id);
    if (pcm.isEmpty) throw _missing(ref.id);
    return pcm16Wav(pcm);
  }

  Future<VoiceTranscript> transcribe(RecordingTranscribe request) async {
    // The account it was asked under: its audio goes to no other's backend.
    final session = _dictation.session();
    final wav = await this.wav(
      RecordingRef(
        id: request.id,
        chatId: request.chatId,
        folderId: request.folderId,
      ),
    );
    final transcript = await _dictation.transcribe(
      wav,
      contentType: 'audio/wav',
      engine: request.engine,
      modelId: request.modelId,
      session: session,
    );
    if (transcript.text.trim().isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no speech was heard in it',
      );
    }
    return transcript;
  }

  static RpcError _notOpen(String id) => RpcError(
    code: ConduitErrorCodes.notFound,
    args: <String, String>{'id': id},
    debugMessage: 'no recording is open with that id',
  );

  static RpcError _missing(String id) => RpcError(
    code: ConduitErrorCodes.notFound,
    args: <String, String>{'id': id},
    debugMessage: 'no such recording',
  );
}

final class _Open {
  _Open(this.store, this.writer, this.sessionId);

  final ComposerRecordingStore store;
  final ComposerRecordingWriter writer;
  final String sessionId;
}
