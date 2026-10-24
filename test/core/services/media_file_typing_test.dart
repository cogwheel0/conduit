import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/utils/file_utils.dart';
import 'package:conduit_core/services/streaming_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('inferFileTypeFromUrl', () {
    test('classifies video extensions', () {
      check(inferFileTypeFromUrl('https://x/out.mp4?token=1')).equals('video');
      check(inferFileTypeFromUrl('/api/files/clip.WEBM')).equals('video');
    });

    test('classifies extensionless file ids as file', () {
      check(
        inferFileTypeFromUrl(
          '/api/v1/files/22ee5ec2-9a94-4a89-af99-f371e905269e/content',
        ),
      ).equals('file');
    });
  });

  group('isVideoFile / isImageFile', () {
    test('content_type video wins over generic type', () {
      final file = {
        'type': 'file',
        'content_type': 'video/mp4',
        'url': 'https://ai.fingaz.info/api/v1/files/abc/content',
      };
      check(isVideoFile(file)).isTrue();
      check(isImageFile(file)).isFalse();
    });

    test('legacy image entries remain images', () {
      final file = {'type': 'image', 'url': 'https://x/generated'};
      check(isImageFile(file)).isTrue();
      check(isVideoFile(file)).isFalse();
    });

    test('filename extension marks video when content_type missing', () {
      final file = {
        'url': 'https://ai.fingaz.info/api/v1/files/abc/content',
        'filename': 'MiniMax_H3_00031_.mp4',
      };
      check(isVideoFile(file)).isTrue();
      check(isImageFile(file)).isFalse();
    });
  });

  group('extractFilesFromResult media typing', () {
    test('mp4 tool output is typed as video, not image', () {
      final files = debugExtractFilesFromResult({
        'url':
            'https://ai.fingaz.info/api/v1/files/22ee5ec2-9a94-4a89-af99-f371e905269e/content',
        'content_type': 'video/mp4',
      });
      check(files.single['type']).equals('video');
    });

    test('filename hint types extensionless video urls', () {
      final files = debugExtractFilesFromResult({
        'files': [
          {
            'url': 'https://ai.fingaz.info/api/v1/files/abc/content',
            'filename': 'moss_clip.mp4',
          },
        ],
      });
      check(files.single['type']).equals('video');
    });

    test('falls back to extension inference for plain urls', () {
      final files = debugExtractFilesFromResult([
        'https://cdn.example.com/clip.mp4',
        'https://cdn.example.com/photo.png',
      ]);
      check(files.map((file) => file['type']).toList()).deepEquals([
        'video',
        'image',
      ]);
    });

    test('extensionless urls keep the legacy image default', () {
      final files = debugExtractFilesFromResult([
        'https://ai.fingaz.info/api/v1/files/22ee5ec2-9a94-4a89-af99-f371e905269e/content',
      ]);
      check(files.single['type']).equals('image');
    });

    test('declared image type stays image', () {
      final files = debugExtractFilesFromResult([
        {'type': 'image', 'url': 'https://example.com/generated'},
      ]);
      check(files.single['type']).equals('image');
    });
  });
}
