import 'package:checks/checks.dart';
import 'package:conduit/features/notes/widgets/audio_player_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('audioDownloadTempFileNameForTesting', () {
    test('removes path traversal from server-controlled components', () {
      final fileName = audioDownloadTempFileNameForTesting(
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
        audioDownloadTempFileNameForTesting(
          fileId: 'file-1',
          serverFileName: 'recording.opus',
          timestamp: 7,
        ),
      ).equals('audio_file-1_7.opus');
      check(
        audioDownloadTempFileNameForTesting(
          fileId: 'file-1',
          serverFileName: 'recording.m4a/../../escape.bad-extension',
          timestamp: 7,
        ),
      ).equals('audio_file-1_7.m4a');
    });

    test('bounds the file id and handles an empty id', () {
      final bounded = audioDownloadTempFileNameForTesting(
        fileId: 'a' * 1000,
        serverFileName: 'recording.wav',
        timestamp: 9,
      );

      check(bounded).equals('audio_${'a' * 64}_9.wav');
      check(
        audioDownloadTempFileNameForTesting(
          fileId: '',
          serverFileName: 'recording',
          timestamp: 9,
        ),
      ).equals('audio_file_9.m4a');
    });
  });
}
