import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:conduit/core/services/share_receiver_service.dart';
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
