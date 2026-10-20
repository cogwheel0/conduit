import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/features/notes/services/note_audio_download.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('noteAudioTempFileName', () {
    test('removes path traversal from server-controlled components', () {
      final fileName = noteAudioTempFileName(
        fileId: r'../folder\audio:id',
        serverFileName: r'voice.m4a\..\..\payload',
        timestamp: 42,
      );

      check(fileName).equals('audio____folder_audio_id_42.m4a');
      check(path.posix.basename(fileName)).equals(fileName);
      check(path.windows.basename(fileName)).equals(fileName);
      check(fileName.contains('..')).isFalse();
    });

    test('keeps only short alphanumeric extensions', () {
      check(
        noteAudioTempFileName(
          fileId: 'file-1',
          serverFileName: 'recording.opus',
          timestamp: 7,
        ),
      ).equals('audio_file-1_7.opus');
      check(
        noteAudioTempFileName(
          fileId: 'file-1',
          serverFileName: 'recording.m4a/../../escape.bad-extension',
          timestamp: 7,
        ),
      ).equals('audio_file-1_7.m4a');
    });

    test('bounds the file id and handles an empty id', () {
      final bounded = noteAudioTempFileName(
        fileId: 'a' * 1000,
        serverFileName: 'recording.wav',
        timestamp: 9,
      );

      check(bounded).equals('audio_${'a' * 64}_9.wav');
      check(
        noteAudioTempFileName(
          fileId: '',
          serverFileName: 'recording',
          timestamp: 9,
        ),
      ).equals('audio_file_9.m4a');
    });
  });

  group('fetchNoteAudio', () {
    test('reads the file name and the content', () async {
      final api = _AudioApi(
        info: <String, dynamic>{'filename': 'talk.wav'},
        adapter: _BytesAdapter(Uint8List.fromList(utf8.encode('RIFFxxxx'))),
      );

      final download = await fetchNoteAudio(api, 'file-1');

      check(download.fileName).equals('talk.wav');
      check(download.bytes).deepEquals(utf8.encode('RIFFxxxx'));
    });

    test('falls back to an m4a name when the server sends none', () async {
      final api = _AudioApi(
        info: <String, dynamic>{},
        adapter: _BytesAdapter(Uint8List(4)),
      );

      check((await fetchNoteAudio(api, 'file-1')).fileName).equals('audio.m4a');
    });
  });
}

class _AudioApi extends ApiService {
  _AudioApi({required this.info, required HttpClientAdapter adapter})
    : _dio = Dio()..httpClientAdapter = adapter,
      super(
        serverConfig: const ServerConfig(
          id: 'server-1',
          name: 'Test',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final Map<String, dynamic> info;
  final Dio _dio;

  // The real client rejects requests that carry no token.
  @override
  Dio get dio => _dio;

  @override
  Future<Map<String, dynamic>> getFileInfo(
    String fileId, {
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async => info;
}

class _BytesAdapter implements HttpClientAdapter {
  _BytesAdapter(this.bytes);

  final Uint8List bytes;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromBytes(bytes, 200);
  }

  @override
  void close({bool force = false}) {}
}
