import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/services/video_attachment_cache.dart';
import 'package:conduit/features/chat/widgets/enhanced_attachment.dart';
import 'package:conduit/features/chat/widgets/enhanced_image_attachment.dart';
import 'package:conduit/features/chat/widgets/enhanced_video_attachment.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Answers the Files API info request with [info].
class _FileInfoApiService extends ApiService {
  _FileInfoApiService(this.info)
    : super(
        serverConfig: const ServerConfig(
          id: 'test-server',
          name: 'Test Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final Map<String, dynamic> info;

  @override
  Future<Map<String, dynamic>> getFileInfo(
    String fileId, {
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async => info;
}

/// Fails any playback fetch: nothing here should load a video.
class _NoFetchVideoCache extends VideoAttachmentCache {
  @override
  Future<File> fetchForPlayback({
    required VideoDownloadClaim claim,
    required String url,
    required String cacheIdentity,
    required String extension,
    required VideoTransport Function(String url) transport,
    required bool Function() isCurrent,
  }) => throw StateError('unexpected video fetch');
}

Future<void> _pumpAttachment(
  WidgetTester tester,
  Map<String, dynamic> info,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiServiceProvider.overrideWithValue(_FileInfoApiService(info)),
        videoAttachmentCacheProvider.overrideWithValue(_NoFetchVideoCache()),
      ],
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: EnhancedAttachment(attachmentId: 'file-1'),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a Files API video declared in meta plays inline', (
    tester,
  ) async {
    await _pumpAttachment(tester, const {
      'id': 'file-1',
      'filename': 'render',
      'meta': {'content_type': 'video/mp4', 'size': 2048},
    });

    final video = tester.widget<EnhancedVideoAttachment>(
      find.byType(EnhancedVideoAttachment),
    );
    check(video.contentType).equals('video/mp4');
    check(video.sizeBytes).equals(2048);
  });

  testWidgets('a declared video type wins over an image file name', (
    tester,
  ) async {
    await _pumpAttachment(tester, const {
      'id': 'file-1',
      'filename': 'render.png',
      'meta': {'content_type': 'video/mp4'},
    });

    expect(find.byType(EnhancedImageAttachment), findsNothing);
    expect(find.byType(EnhancedVideoAttachment), findsOneWidget);
  });
}
