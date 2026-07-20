import 'dart:async';

import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/chat/providers/assistant_response_builder_provider.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/queued_completion_provider.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/chat/widgets/enhanced_attachment.dart';
import 'package:conduit/features/chat/widgets/enhanced_image_attachment.dart';
import 'package:conduit/features/chat/widgets/follow_up_suggestions.dart';
import 'package:conduit/features/chat/widgets/streaming_status_widget.dart';
import 'package:conduit/features/chat/widgets/sources/openwebui_sources.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/chat_action_button.dart';
import 'package:conduit/shared/widgets/markdown/streaming_markdown_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestTextToSpeechController extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

class _RecordingTextToSpeechController extends TextToSpeechController {
  _RecordingTextToSpeechController(this.onToggle);

  final VoidCallback onToggle;

  @override
  TextToSpeechState build() =>
      const TextToSpeechState(initialized: true, available: true);

  @override
  Future<void> toggleForMessage({
    required String messageId,
    required String text,
  }) async {
    onToggle();
  }
}

class _CountingTextToSpeechController extends TextToSpeechController {
  _CountingTextToSpeechController(this.onBuild);

  final VoidCallback onBuild;

  @override
  TextToSpeechState build() {
    onBuild();
    return const TextToSpeechState();
  }
}

Widget _buildHarness(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

Widget _buildAssistantHarness(
  ChatMessage message, {
  bool showFollowUps = false,
  bool isStreaming = false,
  bool? isChatStreaming,
  bool disableAnimations = false,
  VoidCallback? onCopy,
  VoidCallback? onRegenerate,
  FutureOr<void> Function(String suggestion)? onFollowUpSelected,
}) {
  return ProviderScope(
    overrides: [
      textToSpeechControllerProvider.overrideWith(
        _TestTextToSpeechController.new,
      ),
      streamingHapticsEnabledProvider.overrideWithValue(false),
      if (isChatStreaming != null)
        isChatStreamingProvider.overrideWithValue(isChatStreaming),
    ],
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
      home: Scaffold(
        body: AssistantMessageWidget(
          message: message,
          isStreaming: isStreaming,
          showFollowUps: showFollowUps,
          animateOnMount: false,
          modelName: message.model,
          onCopy: onCopy ?? () {},
          onRegenerate: onRegenerate ?? () {},
          onDelete: () {},
          onFollowUpSelected: onFollowUpSelected,
        ),
      ),
    ),
  );
}

bool _hasInProgressFadeAncestor(WidgetTester tester, Finder childFinder) {
  final fadeFinder = find.ancestor(
    of: childFinder,
    matching: find.byType(FadeTransition),
  );
  return tester
      .widgetList<FadeTransition>(fadeFinder)
      .any((fade) => fade.opacity.value < 1);
}

Future<void> _tapVersionControl(
  WidgetTester tester, {
  required IconData visibleIcon,
  required String overflowLabel,
}) async {
  final visibleFinder = find.byIcon(visibleIcon);
  if (visibleFinder.evaluate().isNotEmpty) {
    await tester.tap(visibleFinder);
    await tester.pumpAndSettle();
    return;
  }

  await tester.tap(find.byIcon(Icons.more_horiz_rounded));
  await tester.pumpAndSettle();
  await tester.tap(find.text(overflowLabel));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('source chip opens a details bottom sheet', (tester) async {
    const sources = <ChatSourceReference>[
      ChatSourceReference(
        title: 'OpenAI Research',
        snippet: 'A first source summary for the sheet.',
      ),
      ChatSourceReference(
        title: 'API Docs',
        snippet: 'A second source summary for the sheet.',
      ),
    ];

    await tester.pumpWidget(
      _buildHarness(
        const Center(child: OpenWebUISourcesWidget(sources: sources)),
      ),
    );

    expect(find.text('2 Sources'), findsOneWidget);

    await tester.tap(find.text('2 Sources'));
    await tester.pumpAndSettle();

    expect(find.text('OpenAI Research'), findsOneWidget);
    expect(find.text('A first source summary for the sheet.'), findsOneWidget);
    expect(find.text('API Docs'), findsOneWidget);
    expect(find.text('A second source summary for the sheet.'), findsOneWidget);
  });

  testWidgets('assistant footer caps inline actions and overflows extras', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'assistant-message',
      role: 'assistant',
      content: 'Listen to this response.',
      timestamp: DateTime(2024, 1, 1),
      sources: const [
        ChatSourceReference(
          title: 'Source A',
          snippet: 'Source details shown in the bottom sheet.',
        ),
      ],
      usage: const {'total_tokens': 24},
      versions: [
        ChatMessageVersion(
          id: 'assistant-message-v1',
          content: 'Older version',
          timestamp: DateTime(2023, 12, 31),
        ),
      ],
    );

    await tester.pumpWidget(_buildAssistantHarness(message));
    await tester.pumpAndSettle();

    expect(find.text('1 Source'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
    expect(find.byIcon(Icons.content_copy), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);

    final refreshPosition = tester.getTopLeft(find.byIcon(Icons.refresh));
    final sourcePosition = tester.getTopLeft(find.text('1 Source'));
    final versionPosition = tester.getTopLeft(find.text('2/2'));
    final overflowPosition = tester.getTopLeft(
      find.byIcon(Icons.more_horiz_rounded),
    );

    expect(sourcePosition.dx, greaterThan(refreshPosition.dx));
    expect(versionPosition.dx, greaterThan(sourcePosition.dx));
    expect(overflowPosition.dx, greaterThan(sourcePosition.dx));
    expect(overflowPosition.dx, greaterThan(versionPosition.dx));

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Prev'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    expect(find.text('Info'), findsOneWidget);
  });

  testWidgets('assistant header follows the active version model', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'assistant-message',
      role: 'assistant',
      content: 'Current version',
      timestamp: DateTime(2024, 1, 1),
      model: 'Model B',
      versions: [
        ChatMessageVersion(
          id: 'assistant-message-v1',
          content: 'Older version',
          timestamp: DateTime(2023, 12, 31),
          model: 'Model A',
        ),
      ],
    );

    await tester.pumpWidget(_buildAssistantHarness(message));
    await tester.pumpAndSettle();

    expect(find.text('Model B'), findsOneWidget);

    await _tapVersionControl(
      tester,
      visibleIcon: Icons.chevron_left,
      overflowLabel: 'Prev',
    );

    expect(find.text('Model A'), findsOneWidget);
    expect(find.text('Model B'), findsNothing);

    await _tapVersionControl(
      tester,
      visibleIcon: Icons.chevron_right,
      overflowLabel: 'Next',
    );

    expect(find.text('Model B'), findsOneWidget);
    expect(find.text('Model A'), findsNothing);
  });

  testWidgets('archived version stays settled when the live version resumes', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'assistant-version-resume',
      role: 'assistant',
      content: 'Current version',
      timestamp: DateTime(2024, 1, 1),
      versions: [
        ChatMessageVersion(
          id: 'assistant-version-resume-v1',
          content: 'Older version',
          timestamp: DateTime(2023, 12, 31),
        ),
      ],
    );

    await tester.pumpWidget(_buildAssistantHarness(message));
    await tester.pumpAndSettle();
    await _tapVersionControl(
      tester,
      visibleIcon: Icons.chevron_left,
      overflowLabel: 'Prev',
    );

    await tester.pumpWidget(
      _buildAssistantHarness(
        message.copyWith(isStreaming: true),
        isStreaming: true,
      ),
    );
    await tester.pump();

    expect(find.text('Older version'), findsOneWidget);
    expect(find.byIcon(Icons.content_copy), findsOneWidget);
    expect(
      tester
          .widget<StreamingMarkdownWidget>(find.byType(StreamingMarkdownWidget))
          .isStreaming,
      isFalse,
    );
  });

  testWidgets('pending-only finished statuses do not leave an empty gap', (
    tester,
  ) async {
    final baseline = ChatMessage(
      id: 'assistant-baseline',
      role: 'assistant',
      content: 'Visible response body',
      timestamp: DateTime(2024, 1, 1),
    );
    final pendingOnly = baseline.copyWith(
      id: 'assistant-pending',
      statusHistory: const [
        ChatStatusUpdate(description: 'Searching...', done: false),
      ],
    );

    await tester.pumpWidget(_buildAssistantHarness(baseline));
    await tester.pumpAndSettle();
    final baselineDy = tester.getTopLeft(find.text('Visible response body')).dy;

    await tester.pumpWidget(_buildAssistantHarness(pendingOnly));
    await tester.pumpAndSettle();

    expect(find.byType(StreamingStatusWidget), findsNothing);
    expect(find.text('Searching...'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Visible response body')).dy,
      closeTo(baselineDy, 0.001),
    );
  });

  testWidgets('finished nullable-done statuses remain visible', (tester) async {
    final message = ChatMessage(
      id: 'assistant-nullable-status',
      role: 'assistant',
      content: 'Visible response body',
      timestamp: DateTime(2024, 1, 1),
      statusHistory: const [
        ChatStatusUpdate(description: 'Generating image...'),
      ],
    );

    await tester.pumpWidget(_buildAssistantHarness(message));
    await tester.pumpAndSettle();

    expect(find.text('Generating image...'), findsOneWidget);
    expect(find.byType(StreamingStatusWidget), findsOneWidget);
  });

  testWidgets('follow-ups update in place without size transitions', (
    tester,
  ) async {
    final baseline = ChatMessage(
      id: 'assistant-follow-ups',
      role: 'assistant',
      content: 'Visible response body',
      timestamp: DateTime(2024, 1, 1),
    );

    await tester.pumpWidget(
      _buildAssistantHarness(baseline, showFollowUps: true),
    );
    await tester.pumpAndSettle();

    expect(find.byType(FollowUpSuggestionBar), findsNothing);

    await tester.pumpWidget(
      _buildAssistantHarness(
        baseline.copyWith(followUps: const ['Ask again']),
        showFollowUps: true,
      ),
    );
    await tester.pump();

    expect(find.byType(SizeTransition), findsNothing);
    expect(find.byType(FollowUpSuggestionBar), findsOneWidget);
    expect(find.text('Ask again'), findsOneWidget);

    await tester.pumpWidget(
      _buildAssistantHarness(
        baseline.copyWith(followUps: const ['Try another angle']),
        showFollowUps: true,
      ),
    );
    await tester.pump();

    expect(find.byType(SizeTransition), findsNothing);
    expect(find.byType(FollowUpSuggestionBar), findsOneWidget);
    expect(find.text('Ask again'), findsNothing);
    expect(find.text('Try another angle'), findsOneWidget);
  });

  testWidgets('follow-up selection delegates to the page send path', (
    tester,
  ) async {
    final selected = <String>[];
    final message = ChatMessage(
      id: 'assistant-follow-up-selection',
      role: 'assistant',
      content: 'Visible response body',
      timestamp: DateTime(2024, 1, 1),
      followUps: const ['  Ask again  '],
    );

    await tester.pumpWidget(
      _buildAssistantHarness(
        message,
        showFollowUps: true,
        onFollowUpSelected: selected.add,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ask again'));
    await tester.pump();

    expect(selected, const ['Ask again']);
  });

  testWidgets('follow-ups stay visible through transient empty snapshots', (
    tester,
  ) async {
    final baseline = ChatMessage(
      id: 'assistant-follow-ups',
      role: 'assistant',
      content: 'Visible response body',
      timestamp: DateTime(2024, 1, 1),
    );

    await tester.pumpWidget(
      _buildAssistantHarness(
        baseline.copyWith(followUps: const ['Ask again']),
        showFollowUps: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(FollowUpSuggestionBar), findsOneWidget);
    expect(find.text('Ask again'), findsOneWidget);

    await tester.pumpWidget(
      _buildAssistantHarness(baseline, showFollowUps: true),
    );
    await tester.pump();

    expect(find.byType(FollowUpSuggestionBar), findsOneWidget);
    expect(find.text('Ask again'), findsOneWidget);
    expect(find.byType(SizeTransition), findsNothing);

    await tester.pumpWidget(
      _buildAssistantHarness(
        baseline.copyWith(followUps: const ['Try another angle']),
        showFollowUps: true,
      ),
    );
    await tester.pump();

    expect(find.byType(FollowUpSuggestionBar), findsOneWidget);
    expect(find.text('Ask again'), findsNothing);
    expect(find.text('Try another angle'), findsOneWidget);
  });

  testWidgets('completed response-done metadata shows enabled footer actions', (
    tester,
  ) async {
    var copyTapCount = 0;
    var regenerateTapCount = 0;
    final message = ChatMessage(
      id: 'assistant-response-done',
      role: 'assistant',
      content: 'Visible response body',
      timestamp: DateTime(2024, 1, 1),
      isStreaming: false,
      metadata: const {'responseDone': true},
      followUps: const ['Ask again'],
    );

    await tester.pumpWidget(
      _buildAssistantHarness(
        message,
        isStreaming: false,
        isChatStreaming: false,
        showFollowUps: true,
        onCopy: () => copyTapCount += 1,
        onRegenerate: () => regenerateTapCount += 1,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('actions')), findsOneWidget);
    expect(find.byIcon(Icons.content_copy), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(find.byType(FollowUpSuggestionBar), findsOneWidget);
    expect(find.text('Ask again'), findsOneWidget);
    expect(
      tester
          .widget<FollowUpSuggestionBar>(find.byType(FollowUpSuggestionBar))
          .isBusy,
      isFalse,
    );

    await tester.tap(find.byIcon(Icons.content_copy));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();

    expect(copyTapCount, 1);
    expect(regenerateTapCount, 1);
  });

  testWidgets(
    'response-done metadata shows actions before the stream flag clears',
    (tester) async {
      final message = ChatMessage(
        id: 'assistant-response-done-streaming',
        role: 'assistant',
        content: 'Visible response body',
        timestamp: DateTime(2024, 1, 1),
        isStreaming: true,
        metadata: const {'responseDone': true},
        followUps: const ['Ask again'],
      );

      await tester.pumpWidget(
        _buildAssistantHarness(
          message,
          isStreaming: true,
          isChatStreaming: true,
          showFollowUps: true,
          onCopy: () {},
          onRegenerate: () {},
        ),
      );
      await tester.pumpAndSettle();

      // `responseDone` is a settled UI state: the action row and follow-ups
      // appear even though the transport `isStreaming` flag has not flipped yet.
      expect(find.byKey(const ValueKey('actions')), findsOneWidget);
      expect(find.byType(FollowUpSuggestionBar), findsOneWidget);
    },
  );

  testWidgets('errored streaming message shows the action footer and error', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'assistant-errored-streaming',
      role: 'assistant',
      content: 'Partial answer',
      timestamp: DateTime(2024, 1, 1),
      isStreaming: true,
      error: const ChatMessageError(content: 'boom'),
    );

    await tester.pumpWidget(
      _buildAssistantHarness(message, isStreaming: true, isChatStreaming: true),
    );
    await tester.pumpAndSettle();

    // error -> failed phase takes precedence over the still-set isStreaming
    // flag: the action row and error banner surface.
    expect(find.byKey(const ValueKey('actions')), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);
  });

  testWidgets('a turn that fails mid-stream reveals the action footer', (
    tester,
  ) async {
    final streaming = ChatMessage(
      id: 'assistant-fail-midstream',
      role: 'assistant',
      content: 'Partial',
      timestamp: DateTime(2024, 1, 1),
      isStreaming: true,
    );

    await tester.pumpWidget(
      _buildAssistantHarness(
        streaming,
        isStreaming: true,
        isChatStreaming: true,
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('actions')), findsNothing);

    // An error appears while the transport flag is still streaming: the phase
    // flips to failed without an isStreaming/responseDone change, so the settle
    // refresh must still surface the action row.
    final failed = streaming.copyWith(
      error: const ChatMessageError(content: 'boom'),
    );
    await tester.pumpWidget(
      _buildAssistantHarness(failed, isStreaming: true, isChatStreaming: true),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('actions')), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);
  });

  testWidgets('starting a new stream clears stale footer actions immediately', (
    tester,
  ) async {
    final completed = ChatMessage(
      id: 'assistant-reused-for-streaming',
      role: 'assistant',
      content: 'Finished answer',
      timestamp: DateTime(2024, 1, 1),
    );

    await tester.pumpWidget(_buildAssistantHarness(completed));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('actions')), findsOneWidget);

    final streaming = completed.copyWith(content: '', isStreaming: true);
    await tester.pumpWidget(
      _buildAssistantHarness(streaming, isStreaming: true),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('actions')), findsNothing);

    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byKey(const ValueKey('actions')), findsNothing);
  });

  testWidgets('streaming assistant skips hidden action provider work', (
    tester,
  ) async {
    var ttsBuilds = 0;
    final message = ChatMessage(
      id: 'assistant-streaming-footer',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2024, 1, 1),
      isStreaming: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          textToSpeechControllerProvider.overrideWith(
            () => _CountingTextToSpeechController(() => ttsBuilds += 1),
          ),
          isChatStreamingProvider.overrideWithValue(false),
        ],
        child: _buildHarness(
          AssistantMessageWidget(
            message: message,
            isStreaming: true,
            animateOnMount: false,
            modelName: message.model,
            onCopy: () {},
            onRegenerate: () {},
            onDelete: () {},
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(ttsBuilds, 0);
  });

  testWidgets('streaming assistant suppresses actions until completion', (
    tester,
  ) async {
    final streaming = ChatMessage(
      id: 'assistant-streaming-footer-fade',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2024, 1, 1),
      isStreaming: true,
    );

    await tester.pumpWidget(
      _buildAssistantHarness(streaming, isStreaming: true),
    );
    await tester.pump();

    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byKey(const ValueKey('actions')), findsNothing);

    final done = streaming.copyWith(
      content: 'Done',
      isStreaming: false,
      metadata: const {'responseDone': true},
    );
    await tester.pumpWidget(_buildAssistantHarness(done, isStreaming: false));
    await tester.pump();

    final actionsFinder = find.byKey(const ValueKey('actions'));
    expect(actionsFinder, findsOneWidget);
    expect(_hasInProgressFadeAncestor(tester, actionsFinder), isFalse);
  });

  testWidgets('streaming body fades in once when first content arrives', (
    tester,
  ) async {
    ChatMessage streamingMessage(String content) => ChatMessage(
      id: 'assistant-streaming-fade',
      role: 'assistant',
      content: content,
      timestamp: DateTime(2024, 1, 1),
      isStreaming: true,
    );

    await tester.pumpWidget(
      _buildAssistantHarness(streamingMessage(''), isStreaming: true),
    );
    await tester.pump();

    // The fade wrapper is always present (its type stays stable to avoid
    // tearing down the markdown subtree at streaming boundaries), but it is
    // fully opaque while there is no content to fade in.
    final initialFadeFinder = find.byKey(
      const ValueKey('assistant-streaming-content-fade'),
    );
    expect(initialFadeFinder, findsOneWidget);
    expect(tester.widget<FadeTransition>(initialFadeFinder).opacity.value, 1);

    await tester.pumpWidget(
      _buildAssistantHarness(streamingMessage('Hello'), isStreaming: true),
    );
    await tester.pump();
    await tester.pump();

    final fadeFinder = find.byKey(
      const ValueKey('assistant-streaming-content-fade'),
    );
    expect(fadeFinder, findsOneWidget);
    expect(
      tester.widget<FadeTransition>(fadeFinder).opacity.value,
      lessThan(1),
    );

    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 1);

    await tester.pumpWidget(
      _buildAssistantHarness(
        streamingMessage('Hello again'),
        isStreaming: true,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 1);
  });

  testWidgets('streaming body fades when first content is present on mount', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'assistant-streaming-initial-fade',
      role: 'assistant',
      content: 'Already streaming',
      timestamp: DateTime(2024, 1, 1),
      isStreaming: true,
    );

    await tester.pumpWidget(_buildAssistantHarness(message, isStreaming: true));
    await tester.pump();

    final fadeFinder = find.byKey(
      const ValueKey('assistant-streaming-content-fade'),
    );
    expect(fadeFinder, findsOneWidget);
    expect(
      tester.widget<FadeTransition>(fadeFinder).opacity.value,
      lessThan(1),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 1);
  });

  testWidgets('completed response-done metadata enables copy', (tester) async {
    var copyTapCount = 0;
    final message = ChatMessage(
      id: 'assistant-response-done-copy',
      role: 'assistant',
      content: 'Visible response body',
      timestamp: DateTime(2024, 1, 1),
      isStreaming: false,
      metadata: const {'responseDone': true},
    );

    await tester.pumpWidget(
      _buildAssistantHarness(
        message,
        isStreaming: false,
        isChatStreaming: false,
        onCopy: () => copyTapCount += 1,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.content_copy), findsOneWidget);

    await tester.tap(find.byIcon(Icons.content_copy));
    await tester.pump();

    expect(copyTapCount, 1);
  });

  testWidgets(
    'completed response-done metadata renders long plain content with final body mode',
    (tester) async {
      final message = ChatMessage(
        id: 'assistant-response-done-body',
        role: 'assistant',
        content: List<String>.generate(13, (index) => 'Line $index').join('\n'),
        timestamp: DateTime(2024, 1, 1),
        isStreaming: false,
        metadata: const {'responseDone': true},
      );

      await tester.pumpWidget(
        _buildAssistantHarness(message, isStreaming: false),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SelectionArea), findsOneWidget);
    },
  );

  testWidgets(
    'completed response-done metadata passes final body mode to custom builders',
    (tester) async {
      final message = ChatMessage(
        id: 'assistant-response-done-builder',
        role: 'assistant',
        content: 'Visible response body',
        timestamp: DateTime(2024, 1, 1),
        isStreaming: false,
        metadata: const {'responseDone': true},
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            textToSpeechControllerProvider.overrideWith(
              _TestTextToSpeechController.new,
            ),
            assistantResponseBuilderProvider.overrideWith(
              (ref) => (context, response) {
                return Text('builder-streaming:${response.isStreaming}');
              },
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: AssistantMessageWidget(
                message: message,
                isStreaming: false,
                showFollowUps: false,
                animateOnMount: false,
                modelName: message.model,
                onCopy: () {},
                onRegenerate: () {},
                onDelete: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('builder-streaming:false'), findsOneWidget);
    },
  );

  testWidgets('completed response-done metadata enables tts', (tester) async {
    final message = ChatMessage(
      id: 'assistant-response-done-tts',
      role: 'assistant',
      content: 'Visible response body',
      timestamp: DateTime(2024, 1, 1),
      isStreaming: false,
      metadata: const {'responseDone': true},
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          textToSpeechControllerProvider.overrideWith(
            () => _RecordingTextToSpeechController(() {}),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AssistantMessageWidget(
              message: message,
              isStreaming: false,
              showFollowUps: false,
              animateOnMount: false,
              modelName: message.model,
              onCopy: () {},
              onRegenerate: () {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.volume_up), findsOneWidget);
    final ttsButton = tester.widget<ChatActionButton>(
      find.ancestor(
        of: find.byIcon(Icons.volume_up),
        matching: find.byType(ChatActionButton),
      ),
    );
    expect(ttsButton.onTap, isNotNull);
  });

  testWidgets(
    'completed response-done metadata re-enables attachment animations',
    (tester) async {
      final message = ChatMessage(
        id: 'assistant-response-done-attachment',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2024, 1, 1),
        isStreaming: false,
        metadata: const {'responseDone': true},
        attachmentIds: const ['attachment-1'],
      );

      await tester.pumpWidget(
        _buildAssistantHarness(message, isStreaming: false),
      );
      await tester.pumpAndSettle();

      expect(find.byType(EnhancedAttachment), findsOneWidget);
      expect(
        tester
            .widget<EnhancedAttachment>(find.byType(EnhancedAttachment))
            .disableAnimation,
        isFalse,
      );
    },
  );

  testWidgets('existing attachment elements survive additions to the grid', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'assistant-growing-attachments',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2024, 1, 1),
      isStreaming: false,
      metadata: const {'responseDone': true},
      attachmentIds: const ['attachment-1', 'attachment-2'],
    );

    await tester.pumpWidget(_buildAssistantHarness(message));
    await tester.pump();
    final firstAttachment = tester.element(
      find.byKey(const ValueKey('attachment_attachment-1')),
    );

    await tester.pumpWidget(
      _buildAssistantHarness(
        message.copyWith(
          attachmentIds: const ['attachment-1', 'attachment-2', 'attachment-3'],
        ),
      ),
    );
    await tester.pump();

    expect(
      identical(
        tester.element(find.byKey(const ValueKey('attachment_attachment-1'))),
        firstAttachment,
      ),
      isTrue,
    );
  });

  testWidgets('reduced motion preserves generated image reveal', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'assistant-reduced-motion-generated-image',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2024, 1, 1),
      isStreaming: false,
      metadata: const {'responseDone': true},
      files: const [
        {'type': 'image', 'url': 'https://example.com/generated.png'},
      ],
    );

    await tester.pumpWidget(
      _buildAssistantHarness(message, disableAnimations: true),
    );
    await tester.pump();

    expect(find.byType(EnhancedImageAttachment), findsOneWidget);
    expect(
      tester
          .widget<EnhancedImageAttachment>(find.byType(EnhancedImageAttachment))
          .disableAnimation,
      isFalse,
    );
  });

  testWidgets('completed response-done metadata enables regenerate', (
    tester,
  ) async {
    var regenerateTapCount = 0;
    final message = ChatMessage(
      id: 'assistant-response-done-regenerate',
      role: 'assistant',
      content: 'Visible response body',
      timestamp: DateTime(2024, 1, 1),
      isStreaming: false,
      metadata: const {'responseDone': true},
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
          isChatStreamingProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AssistantMessageWidget(
              message: message,
              isStreaming: false,
              showFollowUps: false,
              animateOnMount: false,
              modelName: message.model,
              onCopy: () {},
              onRegenerate: () => regenerateTapCount += 1,
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.refresh), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();

    expect(regenerateTapCount, 1);
  });

  testWidgets('queued offline placeholder shows retry and cancel actions', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'queued-assistant',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2024, 1, 1),
      isStreaming: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
          queuedCompletionInfoForMessageProvider(
            'queued-assistant',
          ).overrideWith(
            (ref) => Stream<QueuedCompletionInfo?>.value(
              const QueuedCompletionInfo(
                databaseOwner: Object(),
                seq: 42,
                chatId: 'chat-1',
                scopedChatId: 'chat-1',
                assistantMessageId: 'queued-assistant',
                phase: QueuedCompletionPhase.pending,
                isOffline: true,
                lastError: 'offline',
                nextAttemptAt: 123,
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AssistantMessageWidget(
              message: message,
              isStreaming: true,
              showFollowUps: false,
              animateOnMount: false,
              modelName: message.model,
              onCopy: () {},
              onRegenerate: () {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Queued offline'), findsOneWidget);
    expect(
      find.text('This response will start when the server is reachable.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.byIcon(Icons.content_copy), findsNothing);
  });

  testWidgets('failed queued completion keeps partial content and recovery', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'partial-assistant',
      role: 'assistant',
      content: 'Partial answer',
      timestamp: DateTime(2024, 1, 1),
      isStreaming: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
          queuedCompletionInfoForMessageProvider(
            'partial-assistant',
          ).overrideWith(
            (ref) => Stream<QueuedCompletionInfo?>.value(
              const QueuedCompletionInfo(
                databaseOwner: Object(),
                seq: 43,
                chatId: 'chat-1',
                scopedChatId: 'chat-1',
                assistantMessageId: 'partial-assistant',
                phase: QueuedCompletionPhase.failed,
                isOffline: false,
                lastError: 'boom',
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AssistantMessageWidget(
              message: message,
              isStreaming: true,
              showFollowUps: false,
              animateOnMount: false,
              modelName: message.model,
              onCopy: () {},
              onRegenerate: () {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Partial answer'), findsOneWidget);
    expect(find.text('Send failed'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.byIcon(Icons.content_copy), findsNothing);
  });

  testWidgets('pending queued completion keeps partial content and recovery', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'pending-partial-assistant',
      role: 'assistant',
      content: 'Partial pending answer',
      timestamp: DateTime(2024, 1, 1),
      isStreaming: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
          queuedCompletionInfoForMessageProvider(
            'pending-partial-assistant',
          ).overrideWith(
            (ref) => Stream<QueuedCompletionInfo?>.value(
              const QueuedCompletionInfo(
                databaseOwner: Object(),
                seq: 44,
                chatId: 'chat-1',
                scopedChatId: 'chat-1',
                assistantMessageId: 'pending-partial-assistant',
                phase: QueuedCompletionPhase.pending,
                isOffline: true,
                lastError: 'offline',
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AssistantMessageWidget(
              message: message,
              isStreaming: true,
              showFollowUps: false,
              animateOnMount: false,
              modelName: message.model,
              onCopy: () {},
              onRegenerate: () {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Partial pending answer'), findsOneWidget);
    expect(find.text('Queued offline'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.byIcon(Icons.content_copy), findsNothing);
  });
}
