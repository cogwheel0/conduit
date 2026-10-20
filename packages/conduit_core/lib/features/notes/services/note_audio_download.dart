import 'package:dio/dio.dart';

import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';

const _defaultAudioExtension = '.m4a';
const _maxAudioTempFileIdLength = 64;
final _safeAudioExtension = RegExp(r'^\.[A-Za-z0-9]{1,10}$');
final _unsafeAudioTempFileIdCharacter = RegExp(r'[^A-Za-z0-9_-]');

/// The temporary file name a downloaded server recording is written under:
/// `audio_<file id>_<timestamp><extension>`. The id and the extension are
/// server-controlled, so path separators, `..` and odd extensions never reach
/// the file system: the id keeps `[A-Za-z0-9_-]` (at most 64 characters) and
/// the extension must be a short alphanumeric one (else `.m4a`).
String noteAudioTempFileName({
  required String fileId,
  required String serverFileName,
  required int timestamp,
}) {
  final basename = serverFileName.replaceAll(r'\', '/').split('/').last;
  final extensionStart = basename.lastIndexOf('.');
  final candidateExtension = extensionStart > 0
      ? basename.substring(extensionStart)
      : _defaultAudioExtension;
  final extension = _safeAudioExtension.hasMatch(candidateExtension)
      ? candidateExtension
      : _defaultAudioExtension;

  final sanitizedFileId = fileId.replaceAll(
    _unsafeAudioTempFileIdCharacter,
    '_',
  );
  final nonEmptyFileId = sanitizedFileId.isEmpty ? 'file' : sanitizedFileId;
  final boundedFileId = nonEmptyFileId.length > _maxAudioTempFileIdLength
      ? nonEmptyFileId.substring(0, _maxAudioTempFileIdLength)
      : nonEmptyFileId;
  return 'audio_${boundedFileId}_$timestamp$extension';
}

/// A recording downloaded from the server.
class NoteAudioDownload {
  const NoteAudioDownload({required this.fileName, required this.bytes});

  /// The name the server holds it under (used for the temp file's extension).
  final String fileName;
  final List<int> bytes;
}

/// Downloads the server file [fileId] (its info, then its content) for
/// playback.
Future<NoteAudioDownload> fetchNoteAudio(
  ApiService api,
  String fileId, {
  CancelToken? cancelToken,
}) async {
  final Map<String, dynamic> fileInfo = await api.getFileInfo(
    fileId,
    cancelToken: cancelToken,
  );
  final String fileName = fileInfo['filename'] as String? ?? 'audio.m4a';

  final Response<dynamic> response = await api.dio.get(
    '/api/v1/files/$fileId/content',
    options: Options(responseType: ResponseType.bytes),
    cancelToken: cancelToken,
  );
  final Object? responseData = response.data;
  if (responseData is! List<int>) {
    throw StateError(
      'Unexpected audio response type: ${responseData.runtimeType}',
    );
  }
  DebugLogger.log(
    'audio-download-ready',
    scope: 'notes/audio/player',
    data: {'bytes': responseData.length},
  );
  return NoteAudioDownload(fileName: fileName, bytes: responseData);
}
