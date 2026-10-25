import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/services/video_attachment_cache.dart';
import 'package:conduit/features/chat/widgets/enhanced_video_attachment.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Records playback fetches and leaves each one loading.
class _RecordingVideoCache extends VideoAttachmentCache {
  final List<String> fetches = <String>[];

  @override
  Future<File> fetchForPlayback({
    required VideoDownloadClaim claim,
    required String url,
    required String cacheIdentity,
    required String extension,
    required VideoTransport Function(String url) transport,
    required bool Function() isCurrent,
  }) {
    fetches.add(url);
    return Completer<File>().future;
  }
}

Widget _harness(_RecordingVideoCache cache, Widget child) {
  return ProviderScope(
    overrides: [
      apiServiceProvider.overrideWithValue(null),
      videoAttachmentCacheProvider.overrideWithValue(cache),
    ],
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  const clip = 'https://cdn.example.com/out/clip.mp4';

  testWidgets('a video waits for Play before it downloads', (tester) async {
    final cache = _RecordingVideoCache();
    await tester.pumpWidget(
      _harness(
        cache,
        const EnhancedVideoAttachment(
          attachmentId: clip,
          sizeBytes: 3 * 1024 * 1024,
        ),
      ),
    );
    await tester.pump();

    check(cache.fetches).isEmpty();
    expect(find.text('clip.mp4'), findsOneWidget);
    expect(find.text('3.0 MB'), findsOneWidget);

    await tester.tap(find.byTooltip('Play'));
    await tester.pump();

    check(cache.fetches).deepEquals([clip]);
    // Loading replaces the Play button; another tap starts nothing.
    expect(find.byTooltip('Play'), findsNothing);
    await tester.tap(find.text('clip.mp4'));
    await tester.pump();
    check(cache.fetches).deepEquals([clip]);
  });

  testWidgets('tapping the card starts playback', (tester) async {
    final cache = _RecordingVideoCache();
    await tester.pumpWidget(
      _harness(
        cache,
        const EnhancedVideoAttachment(
          attachmentId: clip,
          filenameHint: 'Sunset',
        ),
      ),
    );
    await tester.pump();
    check(cache.fetches).isEmpty();

    await tester.tap(find.text('Sunset'));
    await tester.pump();
    check(cache.fetches).deepEquals([clip]);
  });
}
