import 'dart:async';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/widgets/enhanced_attachment.dart';
import 'package:conduit/features/chat/widgets/enhanced_image_attachment.dart';
import 'package:conduit/features/chat/widgets/user_message_bubble.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/skeleton_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

void main() {
  Widget buildHarness(
    ChatMessage message, {
    List<Override> overrides = const [],
  }) {
    return ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: UserMessageBubble(
              message: message,
              isUser: true,
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders attached note cards from message files', (
    WidgetTester tester,
  ) async {
    final message = ChatMessage(
      id: 'user-1',
      role: 'user',
      content: '',
      timestamp: DateTime.utc(2026, 3, 28, 10),
      files: const [
        <String, dynamic>{
          'type': 'note',
          'id': 'note-1',
          'name': 'Sprint Plan',
        },
      ],
    );

    await tester.pumpWidget(buildHarness(message));
    await tester.pump();

    expect(find.text('Sprint Plan'), findsOneWidget);
    expect(find.byIcon(Icons.sticky_note_2_outlined), findsOneWidget);
  });

  testWidgets('uses the redesigned rounded user bubble surface', (
    WidgetTester tester,
  ) async {
    final message = ChatMessage(
      id: 'user-2',
      role: 'user',
      content: 'Short user prompt',
      timestamp: DateTime.utc(2026, 3, 28, 10),
    );

    await tester.pumpWidget(buildHarness(message));
    await tester.pump();

    final bubble = tester.widget<Container>(
      find.byKey(const Key('user-message-bubble-surface')),
    );
    final decoration = bubble.decoration! as BoxDecoration;

    expect(bubble.padding, const EdgeInsets.all(Spacing.sm + Spacing.xs));
    expect(
      decoration.borderRadius,
      const BorderRadius.only(
        topLeft: Radius.circular(AppBorderRadius.chatBubble),
        topRight: Radius.circular(AppBorderRadius.chatBubble),
        bottomLeft: Radius.circular(AppBorderRadius.chatBubble),
        bottomRight: Radius.circular(AppBorderRadius.md),
      ),
    );
    expect(decoration.border, isNotNull);
  });

  testWidgets('wrapped user text uses longest-line width basis', (
    WidgetTester tester,
  ) async {
    const content =
        'This user message is long enough to wrap to another line in the bubble.';
    final message = ChatMessage(
      id: 'user-3',
      role: 'user',
      content: content,
      timestamp: DateTime.utc(2026, 3, 28, 10),
    );

    await tester.pumpWidget(buildHarness(message));
    await tester.pump();

    final textWidget = tester.widget<Text>(find.text(content));
    expect(textWidget.textWidthBasis, TextWidthBasis.longestLine);
  });

  testWidgets('legacy non-image attachment ids stay on generic file cards', (
    WidgetTester tester,
  ) async {
    final infoCompleter = Completer<Map<String, dynamic>>();
    final api = _FakeAttachmentInfoApiService(
      onGetFileInfo: (_) => infoCompleter.future,
    );
    final message = ChatMessage(
      id: 'user-file-1',
      role: 'user',
      content: '',
      timestamp: DateTime.utc(2026, 3, 28, 10),
      attachmentIds: const ['legacy-file-id'],
    );

    await tester.pumpWidget(
      buildHarness(
        message,
        overrides: [apiServiceProvider.overrideWithValue(api)],
      ),
    );

    expect(find.byType(EnhancedAttachment), findsOneWidget);
    expect(find.byType(EnhancedImageAttachment), findsNothing);
    expect(find.byType(SkeletonLoader), findsOneWidget);

    infoCompleter.complete({
      'filename': 'brief.pdf',
      'content_type': 'application/pdf',
      'size': 1024,
    });
    await tester.pump();

    expect(find.text('brief.pdf'), findsOneWidget);
    expect(find.byType(EnhancedImageAttachment), findsNothing);
  });
}

class _FakeAttachmentInfoApiService extends ApiService {
  _FakeAttachmentInfoApiService({required this.onGetFileInfo})
    : super(
        serverConfig: const ServerConfig(
          id: 'test-server',
          name: 'Test Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final Future<Map<String, dynamic>> Function(String fileId) onGetFileInfo;

  @override
  Future<Map<String, dynamic>> getFileInfo(String fileId) {
    return onGetFileInfo(fileId);
  }
}
