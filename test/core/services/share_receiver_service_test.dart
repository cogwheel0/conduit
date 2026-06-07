import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'package:conduit/core/services/share_receiver_service.dart';
import 'package:conduit/core/services/share_staging_cleanup.dart';
import 'package:conduit/features/chat/services/file_attachment_service.dart';

void main() {
  group('SharedPayload', () {
    test('parses native payload maps and filters invalid file paths', () {
      final payload = SharedPayload.fromMap({
        'id': 'share-1',
        'text': 'hello',
        'filePaths': ['/tmp/a.txt', '', 42, '/tmp/b.txt'],
      });

      expect(payload.id, 'share-1');
      expect(payload.text, 'hello');
      expect(payload.filePaths, ['/tmp/a.txt', '/tmp/b.txt']);
      expect(payload.toMap(), {
        'id': 'share-1',
        'text': 'hello',
        'filePaths': ['/tmp/a.txt', '/tmp/b.txt'],
      });
    });

    test('ignores malformed native payloads', () {
      const payload = SharedPayload();

      expect(SharedPayload.fromMap(null).hasAnything, isFalse);
      expect(SharedPayload.fromMap('bad').hasAnything, isFalse);
      expect(payload.toMap(), {'filePaths': <String>[]});
    });

    test('maps shared text and URLs into composer text', () {
      final payload = SharedPayload.fromSharedMediaFiles([
        SharedMediaFile(
          path: '  hello from another app  ',
          type: SharedMediaType.text,
          mimeType: 'text/plain',
        ),
        SharedMediaFile(
          path: 'https://example.com/article',
          type: SharedMediaType.url,
        ),
      ]);

      expect(
        payload.text,
        'hello from another app\nhttps://example.com/article',
      );
      expect(payload.filePaths, isEmpty);
    });

    test('maps shared files, photos, and videos into file paths', () {
      final payload = SharedPayload.fromSharedMediaFiles([
        SharedMediaFile(
          path: 'file:///tmp/shared%20photo.jpg',
          type: SharedMediaType.image,
          mimeType: 'image/jpeg',
        ),
        SharedMediaFile(
          path: '/tmp/movie.mp4',
          type: SharedMediaType.video,
          mimeType: 'video/mp4',
        ),
        SharedMediaFile(
          path: '/tmp/doc.pdf',
          type: SharedMediaType.file,
          mimeType: 'application/pdf',
        ),
      ]);

      expect(payload.text, isNull);
      expect(payload.filePaths, [
        '/tmp/shared photo.jpg',
        '/tmp/movie.mp4',
        '/tmp/doc.pdf',
      ]);
    });

    test('merges Android multi-file share text into composer text', () {
      final payload = SharedPayload.fromSharedMediaFiles([
        SharedMediaFile(
          path: '/tmp/photo.jpg',
          type: SharedMediaType.image,
          mimeType: 'image/jpeg',
        ),
        SharedMediaFile(
          path: '/tmp/document.pdf',
          type: SharedMediaType.file,
          mimeType: 'application/pdf',
        ),
      ], extraText: '  shared caption  ');

      expect(payload.text, 'shared caption');
      expect(payload.filePaths, ['/tmp/photo.jpg', '/tmp/document.pdf']);
    });

    test('deduplicates iOS messages and malformed media values', () {
      final payload = SharedPayload.fromSharedMediaFiles([
        SharedMediaFile(
          path: '/tmp/one.jpg',
          type: SharedMediaType.image,
          message: 'caption',
        ),
        SharedMediaFile(
          path: '/tmp/two.jpg',
          type: SharedMediaType.image,
          message: 'caption',
        ),
        SharedMediaFile(path: '', type: SharedMediaType.file),
        SharedMediaFile(path: ' ', type: SharedMediaType.text),
        SharedMediaFile(path: '/tmp/two.jpg', type: SharedMediaType.image),
      ]);

      expect(payload.text, 'caption');
      expect(payload.filePaths, ['/tmp/one.jpg', '/tmp/two.jpg']);
    });

    test('deletes ignored Android video thumbnails from cache root', () async {
      final thumbnail = File(
        p.join(
          Directory.systemTemp.path,
          'conduit-share-thumbnail-${DateTime.now().microsecondsSinceEpoch}.png',
        ),
      );
      await thumbnail.writeAsBytes([1, 2, 3]);
      addTearDown(() async {
        if (await thumbnail.exists()) {
          await thumbnail.delete();
        }
      });

      final payload = SharedPayload.fromSharedMediaFiles([
        SharedMediaFile(
          path: '/tmp/movie.mp4',
          thumbnail: thumbnail.path,
          type: SharedMediaType.video,
          mimeType: 'video/mp4',
        ),
      ]);

      expect(payload.filePaths, ['/tmp/movie.mp4']);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await thumbnail.exists(), isFalse);
    });
  });

  group('shared attachment validation', () {
    test('returns valid staged files', () async {
      final root = await Directory.systemTemp.createTemp(
        'conduit_share_receiver_valid_',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final file = File(
        p.join(
          root.path,
          'shared-intents',
          '123e4567-e89b-12d3-a456-426614174000-small.txt',
        ),
      );
      await file.create(recursive: true);
      await file.writeAsString('hello');

      final attachments = await validSharedAttachmentsForTest([file.path]);

      expect(attachments, hasLength(1));
      expect(attachments.single.file.path, file.path);
      expect(attachments.single.displayName, p.basename(file.path));
      expect(await file.exists(), isTrue);
    });

    test('rejects and deletes oversized staged files', () async {
      final root = await Directory.systemTemp.createTemp(
        'conduit_share_receiver_oversized_',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final file = File(
        p.join(
          root.path,
          'shared-intents',
          '123e4567-e89b-12d3-a456-426614174000-big.bin',
        ),
      );
      await file.create(recursive: true);
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(20 * 1024 * 1024 + 1);
      await handle.close();

      final attachments = await validSharedAttachmentsForTest([file.path]);

      expect(attachments, isEmpty);
      expect(await file.exists(), isFalse);
    });

    test('rejects and deletes files over the share count cap', () async {
      final root = await Directory.systemTemp.createTemp(
        'conduit_share_receiver_count_',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final files = <File>[];
      for (var i = 0; i < 7; i++) {
        final file = File(
          p.join(
            root.path,
            'shared-intents',
            '123e4567-e89b-12d3-a456-426614174000-$i.txt',
          ),
        );
        await file.create(recursive: true);
        await file.writeAsString('hello $i');
        files.add(file);
      }

      final attachments = await validSharedAttachmentsForTest(
        files.map((file) => file.path).toList(),
      );

      expect(attachments, hasLength(6));
      expect(await files[5].exists(), isTrue);
      expect(await files[6].exists(), isFalse);
    });

    test('copies plugin cache-root files into owned staging', () async {
      final file = File(
        p.join(
          Directory.systemTemp.path,
          'conduit-share-plugin-cache-root-${DateTime.now().microsecondsSinceEpoch}.txt',
        ),
      );
      await file.writeAsString('hello from cache root');
      addTearDown(() async {
        if (await file.exists()) {
          await file.delete();
        }
      });

      final attachments = await validSharedAttachmentsForTest([file.path]);

      expect(attachments, hasLength(1));
      final stagedPath = attachments.single.file.path;
      expect(isShareStagingPath(stagedPath), isTrue);
      expect(p.basename(p.dirname(stagedPath)), shareStagingDirectoryName);
      expect(await File(stagedPath).readAsString(), 'hello from cache root');
      expect(await file.exists(), isFalse);
      await deleteShareStagingFile(stagedPath);
    });
  });

  group('share staging cleanup', () {
    test('does not treat arbitrary temp files as share staging', () async {
      final file = File(
        p.join(
          Directory.systemTemp.path,
          'conduit-not-share-${DateTime.now().microsecondsSinceEpoch}.txt',
        ),
      );
      await file.writeAsString('keep me');
      addTearDown(() async {
        if (await file.exists()) {
          await file.delete();
        }
      });

      expect(isShareStagingPath(file.path), isFalse);

      await deleteShareStagingFile(file.path);

      expect(await file.exists(), isTrue);
    });
  });

  group('shared payload processing', () {
    test('consumes invalid file-only payloads instead of retrying', () async {
      final root = await Directory.systemTemp.createTemp(
        'conduit_share_receiver_missing_',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final container = ProviderContainer(
        overrides: [fileAttachmentServiceProvider.overrideWithValue(Object())],
      );
      addTearDown(container.dispose);

      final missingPath = p.join(
        root.path,
        'shared-intents',
        '123e4567-e89b-12d3-a456-426614174000-missing.txt',
      );

      final result = await processSharedPayloadForTest(
        container,
        SharedPayload(id: 'stale', filePaths: [missingPath]),
      );

      expect(result, SharedPayloadProcessResult.consumed);
      expect(container.read(attachedFilesProvider), isEmpty);
    });
  });
}
