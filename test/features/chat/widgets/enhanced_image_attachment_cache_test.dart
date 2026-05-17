import 'dart:async';

import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/widgets/enhanced_image_attachment.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(debugResetImageAttachmentCaches);
  tearDown(debugResetImageAttachmentCaches);

  test('resolved image cache evicts the least recently used entry', () {
    for (var index = 0; index < 80; index += 1) {
      debugSeedResolvedImageAttachment(
        'image-$index',
        'data:image/png;base64,AA==',
      );
    }

    expect(debugResolvedImageAttachmentCount(), 80);

    debugSeedResolvedImageAttachment('image-0', 'data:image/png;base64,AA==');
    debugSeedResolvedImageAttachment('image-80', 'data:image/png;base64,AA==');

    expect(debugResolvedImageAttachmentCount(), 80);
    expect(debugHasResolvedImageAttachment('image-0'), isTrue);
    expect(debugHasResolvedImageAttachment('image-1'), isFalse);
    expect(debugHasResolvedImageAttachment('image-80'), isTrue);
  });

  test(
    'cached resolved image data decodes without refetching through the api',
    () async {
      final workerManager = WorkerManager(maxConcurrentTasks: 1);
      addTearDown(workerManager.dispose);
      const attachmentId = 'cached-image';
      const pngDataUrl =
          'data:image/png;base64,'
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF9sAAAAASUVORK5CYII=';

      debugSeedResolvedImageAttachment(attachmentId, pngDataUrl);
      expect(debugHasDecodedImageAttachment(attachmentId), isFalse);

      await debugDecodeCachedResolvedImageAttachment(
        attachmentId: attachmentId,
        workerManager: workerManager,
      );

      expect(debugHasDecodedImageAttachment(attachmentId), isTrue);
    },
  );

  test(
    'invalid cached image data maps to the localized decode error',
    () async {
      final workerManager = WorkerManager(maxConcurrentTasks: 1);
      addTearDown(workerManager.dispose);
      const attachmentId = 'invalid-image';
      debugSeedResolvedImageAttachment(attachmentId, 'data:image/png;base64');
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      final error = await debugDecodeCachedResolvedImageAttachmentError(
        attachmentId: attachmentId,
        workerManager: workerManager,
        l10n: l10n,
      );

      expect(error, l10n.failedToDecodeImage);
    },
  );

  test(
    'invalid image loads fail closed without leaking async cleanup errors',
    () async {
      final workerManager = WorkerManager(maxConcurrentTasks: 1);
      addTearDown(workerManager.dispose);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final zoneErrors = <Object>[];
      String? error;

      await runZonedGuarded(
        () async {
          error = await debugLoadImageAttachmentError(
            attachmentId: 'data:image/png;base64',
            workerManager: workerManager,
            l10n: l10n,
          );
          await Future<void>.delayed(Duration.zero);
        },
        (error, stackTrace) {
          zoneErrors.add(error);
        },
      );

      expect(error, l10n.failedToDecodeImage);
      expect(zoneErrors, isEmpty);
    },
  );
}
