/// Videos in an assistant message's files must never reach the image
/// renderer, which throws on video bytes, and must not download until the
/// user taps Play.
library;

import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/services/video_attachment_cache.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/chat/widgets/enhanced_image_attachment.dart';
import 'package:conduit/features/chat/widgets/enhanced_video_attachment.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _InactiveTts extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

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

Future<_RecordingVideoCache> _pumpMessage(
  WidgetTester tester,
  List<Map<String, dynamic>> files,
) async {
  final cache = _RecordingVideoCache();
  final message = ChatMessage(
    id: 'assistant-video',
    role: 'assistant',
    content: '',
    timestamp: DateTime(2026, 1, 1),
    isStreaming: false,
    metadata: const {'responseDone': true},
    files: files,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiServiceProvider.overrideWithValue(null),
        textToSpeechControllerProvider.overrideWith(_InactiveTts.new),
        streamingHapticsEnabledProvider.overrideWithValue(false),
        videoAttachmentCacheProvider.overrideWithValue(cache),
      ],
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AssistantMessageWidget(
            message: message,
            isStreaming: false,
            showFollowUps: false,
            animateOnMount: false,
            onCopy: () {},
            onRegenerate: () {},
            onDelete: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return cache;
}

void main() {
  testWidgets('a video saved as an image renders as a video', (tester) async {
    // Tool output saved before videos had their own type.
    final cache = await _pumpMessage(tester, const [
      {'type': 'image', 'url': 'https://cdn.example.com/out/clip.mp4'},
    ]);

    expect(find.byType(EnhancedImageAttachment), findsNothing);
    expect(find.byType(EnhancedVideoAttachment), findsOneWidget);
    check(cache.fetches).isEmpty();
  });

  testWidgets('a video/mp4 file renders as a video', (tester) async {
    final cache = await _pumpMessage(tester, const [
      {
        'type': 'video',
        'url': 'https://owui.example.com/api/v1/files/generated-1/content',
        'content_type': 'video/mp4',
        'filename': 'render.mp4',
      },
      {'type': 'image', 'url': 'https://cdn.example.com/out/still.png'},
    ]);

    expect(find.byType(EnhancedVideoAttachment), findsOneWidget);
    final images = tester.widgetList<EnhancedImageAttachment>(
      find.byType(EnhancedImageAttachment),
    );
    check(
      images.map((image) => image.attachmentId).toList(),
    ).deepEquals(['https://cdn.example.com/out/still.png']);
    check(cache.fetches).isEmpty();
  });
}
