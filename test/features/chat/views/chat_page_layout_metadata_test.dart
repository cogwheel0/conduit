import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('layout metadata keeps archived assistant rows at zero extent', () {
    final messages = <ChatMessage>[
      ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Hello there',
        timestamp: DateTime(2026),
      ),
      ChatMessage(
        id: 'assistant-archived',
        role: 'assistant',
        content: 'Old archived response',
        timestamp: DateTime(2026),
        metadata: const {'archivedVariant': true},
      ),
      ChatMessage(
        id: 'assistant-visible',
        role: 'assistant',
        content: 'Visible response',
        timestamp: DateTime(2026),
      ),
    ];

    final summary = debugBuildChatListLayoutSummaryForTesting(messages);

    expect(summary[1].isArchivedVariant, isTrue);
    expect(summary[1].estimatedExtent, 0);
    expect(summary[2].leadingOffset, summary[0].estimatedExtent);
  });

  test(
    'layout metadata only enables follow-ups for terminal assistant rows',
    () {
      final messages = <ChatMessage>[
        ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          content: 'First response',
          timestamp: DateTime(2026),
        ),
        ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Question',
          timestamp: DateTime(2026),
        ),
        ChatMessage(
          id: 'assistant-2',
          role: 'assistant',
          content: 'Final response',
          timestamp: DateTime(2026),
        ),
      ];

      final summary = debugBuildChatListLayoutSummaryForTesting(messages);

      expect(summary[0].showFollowUps, isFalse);
      expect(summary[1].showFollowUps, isFalse);
      expect(summary[2].showFollowUps, isTrue);
    },
  );

  test(
    'markdown prewarm candidates prioritize the visible viewport window',
    () {
      final messages = List<ChatMessage>.generate(8, (index) {
        return ChatMessage(
          id: 'assistant-$index',
          role: 'assistant',
          content: 'Short response $index',
          timestamp: DateTime(2026),
        );
      });

      final indices = debugSelectMarkdownPrewarmCandidateIndicesForTesting(
        messages,
        viewportTop: 0,
        viewportHeight: 220,
        maxCount: 3,
      );

      expect(indices, <int>[2, 1, 0]);
    },
  );

  test('markdown prewarm returns no candidates without viewport metrics', () {
    final messages = <ChatMessage>[
      ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: 'First assistant response',
        timestamp: DateTime(2026),
      ),
      ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'User question',
        timestamp: DateTime(2026),
      ),
      ChatMessage(
        id: 'assistant-2',
        role: 'assistant',
        content: 'Second assistant response',
        timestamp: DateTime(2026),
      ),
      ChatMessage(
        id: 'assistant-3',
        role: 'assistant',
        content: 'Third assistant response',
        timestamp: DateTime(2026),
      ),
    ];

    final indices = debugSelectMarkdownPrewarmCandidateIndicesForTesting(
      messages,
      viewportHeight: 0,
      maxCount: 2,
    );

    expect(indices, isEmpty);
  });

  test('markdown prewarm skips still-streaming assistant messages', () {
    final messages = <ChatMessage>[
      ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: 'Completed assistant response',
        timestamp: DateTime(2026),
      ),
      ChatMessage(
        id: 'assistant-2',
        role: 'assistant',
        content: 'Streaming assistant response',
        timestamp: DateTime(2026),
        isStreaming: true,
      ),
    ];

    final indices = debugSelectMarkdownPrewarmCandidateIndicesForTesting(
      messages,
      viewportTop: 0,
      viewportHeight: 300,
      maxCount: 2,
    );

    expect(indices, <int>[0]);
  });

  test('keyboard inset growth preserves bottom anchor when already pinned', () {
    final shouldKeepBottomAnchored =
        debugShouldKeepConversationBottomAnchoredOnInsetChangeForTesting(
          previousBottomInset: 0,
          nextBottomInset: 320,
          isAnchoredToBottom: true,
          isUserInteractingWithScroll: false,
          wantsPinToTop: false,
        );

    expect(shouldKeepBottomAnchored, isTrue);
  });

  test('keyboard inset growth does not jump when user left the bottom', () {
    final shouldKeepBottomAnchored =
        debugShouldKeepConversationBottomAnchoredOnInsetChangeForTesting(
          previousBottomInset: 0,
          nextBottomInset: 320,
          isAnchoredToBottom: false,
          isUserInteractingWithScroll: false,
          wantsPinToTop: false,
        );

    expect(shouldKeepBottomAnchored, isFalse);
  });

  test(
    'keyboard inset growth ignores pin-to-top mode and manual scrolling',
    () {
      final whilePinnedToTop =
          debugShouldKeepConversationBottomAnchoredOnInsetChangeForTesting(
            previousBottomInset: 0,
            nextBottomInset: 320,
            isAnchoredToBottom: true,
            isUserInteractingWithScroll: false,
            wantsPinToTop: true,
          );
      final whileUserScrolling =
          debugShouldKeepConversationBottomAnchoredOnInsetChangeForTesting(
            previousBottomInset: 0,
            nextBottomInset: 320,
            isAnchoredToBottom: true,
            isUserInteractingWithScroll: true,
            wantsPinToTop: false,
          );

      expect(whilePinnedToTop, isFalse);
      expect(whileUserScrolling, isFalse);
    },
  );

  test('clearing pin-to-top tracking preserves the active phantom sliver', () {
    final cleared = debugClearPinToTopTrackingForTesting(
      isActive: true,
      userMessageId: 'user-1',
      streamingMessageId: 'assistant-1',
    );

    expect(cleared.isActive, isTrue);
    expect(cleared.userMessageId, isNull);
    expect(cleared.streamingMessageId, isNull);
  });
}
