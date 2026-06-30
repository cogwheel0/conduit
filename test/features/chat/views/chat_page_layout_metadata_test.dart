import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/views/chat_bottom_anchor_controller.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bottom anchor controller separates sticky and detached states', () {
    final controller = ChatBottomAnchorController(
      showThreshold: 300,
      hideThreshold: 150,
    );

    expect(
      controller.updateAnchor(
        hasScrollableContent: true,
        distanceFromBottom: 24,
      ),
      isTrue,
    );
    expect(
      controller.shouldKeepAnchoredOnContentSizeChange(wantsPinToTop: false),
      isTrue,
    );

    controller.updateAnchor(
      hasScrollableContent: true,
      distanceFromBottom: 320,
    );

    expect(controller.isAnchoredToBottom, isFalse);
    expect(
      controller.shouldShowScrollToBottom(
        currentlyShowing: false,
        hasScrollableContent: true,
        distanceFromBottom: 320,
      ),
      isTrue,
    );
    expect(
      controller.shouldKeepAnchoredOnContentSizeChange(wantsPinToTop: false),
      isFalse,
    );
  });

  test('bottom anchor controller keeps sticky content growth verified', () {
    final controller = ChatBottomAnchorController(
      showThreshold: 300,
      hideThreshold: 150,
    );

    controller.updateAnchor(hasScrollableContent: true, distanceFromBottom: 24);

    expect(
      controller.prepareForStickyContentChange(wantsPinToTop: false),
      isTrue,
    );
    expect(
      controller.updateAnchor(
        hasScrollableContent: true,
        distanceFromBottom: 320,
      ),
      isTrue,
    );
    expect(
      controller.shouldShowScrollToBottom(
        currentlyShowing: false,
        hasScrollableContent: true,
        distanceFromBottom: 320,
      ),
      isFalse,
    );

    controller.verifyStickyCorrection(nearBottom: true);
    expect(controller.isAnchoredToBottom, isTrue);
  });

  test('bottom anchor controller detaches on intentional user scroll away', () {
    final controller = ChatBottomAnchorController(
      showThreshold: 300,
      hideThreshold: 150,
    );

    controller.updateAnchor(hasScrollableContent: true, distanceFromBottom: 24);
    controller.prepareForStickyContentChange(wantsPinToTop: false);

    expect(
      controller.shouldDetachForUserScrollAway(
        nearBottom: false,
        scrollDelta: 4,
      ),
      isFalse,
    );
    expect(
      controller.shouldDetachForUserScrollAway(
        nearBottom: false,
        scrollDelta: 36,
      ),
      isTrue,
    );

    controller.detachByUser();
    expect(controller.isAnchoredToBottom, isFalse);
  });

  test('bottom anchor controller re-pins after detached programmatic scroll', () {
    final controller = ChatBottomAnchorController(
      showThreshold: 300,
      hideThreshold: 150,
    );

    controller.updateAnchor(
      hasScrollableContent: true,
      distanceFromBottom: 320,
    );
    controller.isUserInteractingWithScroll = true;
    expect(controller.isAnchoredToBottom, isFalse);

    controller.resetForDetachedScroll();

    expect(controller.isAnchoredToBottom, isTrue);
    expect(controller.isUserInteractingWithScroll, isFalse);
    // The sticky latch was cleared, so a subsequent scroll away detaches.
    expect(
      controller.updateAnchor(
        hasScrollableContent: true,
        distanceFromBottom: 320,
      ),
      isFalse,
    );
  });

  test('bottom anchor controller never detaches near bottom or when unanchored', () {
    final controller = ChatBottomAnchorController(
      showThreshold: 300,
      hideThreshold: 150,
    );

    controller.updateAnchor(hasScrollableContent: true, distanceFromBottom: 24);
    controller.prepareForStickyContentChange(wantsPinToTop: false);

    // nearBottom short-circuits regardless of delta.
    expect(
      controller.shouldDetachForUserScrollAway(nearBottom: true, scrollDelta: 999),
      isFalse,
    );

    // Unanchored short-circuits regardless of delta.
    controller.detachByUser();
    expect(controller.isAnchoredToBottom, isFalse);
    expect(
      controller.shouldDetachForUserScrollAway(
        nearBottom: false,
        scrollDelta: 999,
      ),
      isFalse,
    );
  });

  test('bottom anchor controller keeps sticky pending when correction is mid-flight', () {
    final controller = ChatBottomAnchorController(
      showThreshold: 300,
      hideThreshold: 150,
    );

    controller.updateAnchor(hasScrollableContent: true, distanceFromBottom: 24);
    controller.prepareForStickyContentChange(wantsPinToTop: false);

    // A non-final correction that has not reached the bottom is a no-op: the
    // latch stays set so the scroll-to-bottom button remains hidden.
    controller.verifyStickyCorrection(nearBottom: false);

    expect(controller.isAnchoredToBottom, isTrue);
    expect(
      controller.shouldShowScrollToBottom(
        currentlyShowing: false,
        hasScrollableContent: true,
        distanceFromBottom: 320,
      ),
      isFalse,
    );
  });

  test('bottom anchor controller releases latch when sticky correction never reaches bottom', () {
    final controller = ChatBottomAnchorController(
      showThreshold: 300,
      hideThreshold: 150,
    );

    controller.updateAnchor(hasScrollableContent: true, distanceFromBottom: 24);
    expect(
      controller.prepareForStickyContentChange(wantsPinToTop: false),
      isTrue,
    );

    // The final correction attempt is still far from the bottom: the latch must
    // clear so button visibility falls back to distance-based logic.
    controller.verifyStickyCorrection(nearBottom: false, isFinalAttempt: true);

    expect(
      controller.shouldShowScrollToBottom(
        currentlyShowing: false,
        hasScrollableContent: true,
        distanceFromBottom: 320,
      ),
      isTrue,
    );
  });

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
    'layout metadata uses Open WebUI modelName before model lookup loads',
    () {
      final messages = <ChatMessage>[
        ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          content: 'Visible response',
          timestamp: DateTime(2026),
          model: 'openai/gpt-4o',
          metadata: const {'modelName': 'GPT-4o'},
        ),
      ];

      final summary = debugBuildChatListLayoutSummaryForTesting(messages);

      expect(summary.single.displayModelName, 'GPT-4o');
    },
  );

  test('layout signature ignores streaming content-only changes', () {
    final streamingMessage = ChatMessage(
      id: 'assistant-streaming',
      role: 'assistant',
      content: 'Short draft',
      timestamp: DateTime(2026),
      model: 'model-a',
      isStreaming: true,
      attachmentIds: const ['attachment-1'],
      statusHistory: const [ChatStatusUpdate(description: 'Searching')],
      followUps: const ['Ask next'],
    );
    final updatedStreamingMessage = streamingMessage.copyWith(
      content: 'A much longer draft that should not invalidate layout metadata',
    );

    final initialSignature = debugBuildChatListStableLayoutSignatureForTesting([
      streamingMessage,
    ]);
    final updatedSignature = debugBuildChatListStableLayoutSignatureForTesting([
      updatedStreamingMessage,
    ]);

    expect(updatedSignature, initialSignature);
  });

  test('layout signature ignores streaming completion-only changes', () {
    final streamingMessage = ChatMessage(
      id: 'assistant-streaming',
      role: 'assistant',
      content: 'Final response',
      timestamp: DateTime(2026),
      model: 'model-a',
      isStreaming: true,
      attachmentIds: const ['attachment-1'],
      statusHistory: const [ChatStatusUpdate(description: 'Done')],
    );
    final completedMessage = streamingMessage.copyWith(isStreaming: false);

    final streamingSignature =
        debugBuildChatListStableLayoutSignatureForTesting([streamingMessage]);
    final completedSignature =
        debugBuildChatListStableLayoutSignatureForTesting([completedMessage]);

    expect(completedSignature, streamingSignature);
  });

  test('layout estimate ignores the streaming flag but reacts to completion '
      'content growth', () {
    final streamingMessage = ChatMessage(
      id: 'assistant-streaming',
      role: 'assistant',
      content: 'Final response with enough text to get a real height estimate.',
      timestamp: DateTime(2026),
      model: 'model-a',
      isStreaming: true,
    );
    // Flipping only the streaming flag must not change the estimate: the
    // estimator intentionally does not read message.isStreaming.
    final completedMessage = streamingMessage.copyWith(isStreaming: false);

    final streamingExtent = debugEstimateMessageListExtentForTesting([
      streamingMessage,
    ], index: 0);
    final completedExtent = debugEstimateMessageListExtentForTesting([
      completedMessage,
    ], index: 0);

    expect(completedExtent, streamingExtent);

    // Positive control: the real completion-driven layout shift is content
    // growing from a short stream to a full response. The estimator consumes
    // content length, so a longer completed body must produce a larger
    // extent. This proves the estimator is not inert and guards against the
    // stability assertion above passing vacuously.
    final grownMessage = completedMessage.copyWith(
      content:
          '${completedMessage.content}\n\n'
          'A substantially longer follow-up paragraph that adds several more '
          'lines of content so the estimated height must increase relative to '
          'the shorter streaming body above.',
    );
    final grownExtent = debugEstimateMessageListExtentForTesting([
      grownMessage,
    ], index: 0);

    expect(grownExtent, greaterThan(completedExtent));
  });

  test('layout signature changes for structural layout inputs', () {
    final baseMessage = ChatMessage(
      id: 'assistant-1',
      role: 'assistant',
      content: 'Final response',
      timestamp: DateTime(2026),
      model: 'model-a',
      attachmentIds: const ['attachment-1'],
      statusHistory: const [ChatStatusUpdate(description: 'Searching')],
      followUps: const ['Ask next'],
    );

    final withExtraFollowUp = baseMessage.copyWith(
      followUps: const ['Ask next', 'Dig deeper'],
    );
    final withExtraStatus = baseMessage.copyWith(
      statusHistory: const [
        ChatStatusUpdate(description: 'Searching'),
        ChatStatusUpdate(description: 'Summarizing'),
      ],
    );
    final archivedVariant = baseMessage.copyWith(
      metadata: const {'archivedVariant': true},
    );

    final baseSignature = debugBuildChatListStableLayoutSignatureForTesting([
      baseMessage,
    ]);

    expect(
      debugBuildChatListStableLayoutSignatureForTesting([withExtraFollowUp]),
      isNot(baseSignature),
    );
    expect(
      debugBuildChatListStableLayoutSignatureForTesting([withExtraStatus]),
      isNot(baseSignature),
    );
    expect(
      debugBuildChatListStableLayoutSignatureForTesting([archivedVariant]),
      isNot(baseSignature),
    );
  });

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

      expect(indices, <int>[1, 0]);
    },
  );

  test('markdown prewarm only returns rows intersecting the viewport', () {
    final messages = List<ChatMessage>.generate(6, (index) {
      return ChatMessage(
        id: 'assistant-$index',
        role: 'assistant',
        content: 'Visible response $index',
        timestamp: DateTime(2026),
      );
    });

    final summary = debugBuildChatListLayoutSummaryForTesting(messages);
    final targetRow = summary[4];
    final indices = debugSelectMarkdownPrewarmCandidateIndicesForTesting(
      messages,
      viewportTop: targetRow.leadingOffset + 1,
      viewportHeight: targetRow.estimatedExtent - 2,
      maxCount: 6,
    );

    expect(indices, <int>[4]);
  });

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

  test('keyboard inset shrink preserves bottom anchor when already pinned', () {
    final shouldKeepBottomAnchored =
        debugShouldKeepConversationBottomAnchoredOnInsetChangeForTesting(
          previousBottomInset: 320,
          nextBottomInset: 0,
          isAnchoredToBottom: true,
          isUserInteractingWithScroll: false,
          wantsPinToTop: false,
        );

    expect(shouldKeepBottomAnchored, isTrue);
  });

  test(
    'tiny keyboard inset changes do not trigger bottom anchor correction',
    () {
      final shouldKeepBottomAnchored =
          debugShouldKeepConversationBottomAnchoredOnInsetChangeForTesting(
            previousBottomInset: 320,
            nextBottomInset: 319.5,
            isAnchoredToBottom: true,
            isUserInteractingWithScroll: false,
            wantsPinToTop: false,
          );

      expect(shouldKeepBottomAnchored, isFalse);
    },
  );

  test('message list extent returns zero for null global fallback', () {
    final messages = <ChatMessage>[
      ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Short prompt',
        timestamp: DateTime(2026),
      ),
      ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content:
            'A much longer assistant response that should have a larger estimated extent.',
        timestamp: DateTime(2026),
      ),
    ];

    final extent = debugEstimateMessageListExtentForTesting(
      messages,
      index: null,
    );

    expect(extent, 0);
  });

  test('composer height growth preserves bottom anchor when already pinned', () {
    final shouldKeepBottomAnchored =
        debugShouldKeepConversationBottomAnchoredOnComposerHeightChangeForTesting(
          previousComposerHeight: 0,
          nextComposerHeight: 160,
          isAnchoredToBottom: true,
          isUserInteractingWithScroll: false,
          wantsPinToTop: false,
        );

    expect(shouldKeepBottomAnchored, isTrue);
  });

  test('message content growth preserves bottom anchor when already pinned', () {
    final shouldKeepBottomAnchored =
        debugShouldKeepConversationBottomAnchoredOnContentSizeChangeForTesting(
          isAnchoredToBottom: true,
          isUserInteractingWithScroll: false,
          wantsPinToTop: false,
        );

    expect(shouldKeepBottomAnchored, isTrue);
  });

  test('row extent invalidation resolves only changed message indices', () {
    final messages = <ChatMessage>[
      ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Question',
        timestamp: DateTime(2026),
      ),
      ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: 'Answer',
        timestamp: DateTime(2026),
      ),
      ChatMessage(
        id: 'assistant-2',
        role: 'assistant',
        content: 'Another answer',
        timestamp: DateTime(2026),
      ),
    ];

    final indices = debugMessageRowIndicesForIdsForTesting(messages, {
      'assistant-2',
      'missing-message',
      'user-1',
    });

    expect(indices, <int>[0, 2]);
  });

  test('row extent invalidation ignores stale message ids', () {
    final messages = <ChatMessage>[
      ChatMessage(
        id: 'current-user',
        role: 'user',
        content: 'Current question',
        timestamp: DateTime(2026),
      ),
      ChatMessage(
        id: 'current-assistant',
        role: 'assistant',
        content: 'Current answer',
        timestamp: DateTime(2026),
      ),
    ];

    final indices = debugMessageRowIndicesForIdsForTesting(messages, {
      'previous-user',
      'previous-assistant',
    });

    expect(indices, isEmpty);
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

  test('composer height change does not jump when user left the bottom', () {
    final shouldKeepBottomAnchored =
        debugShouldKeepConversationBottomAnchoredOnComposerHeightChangeForTesting(
          previousComposerHeight: 0,
          nextComposerHeight: 160,
          isAnchoredToBottom: false,
          isUserInteractingWithScroll: false,
          wantsPinToTop: false,
        );

    expect(shouldKeepBottomAnchored, isFalse);
  });

  test('message content growth does not jump when user left the bottom', () {
    final shouldKeepBottomAnchored =
        debugShouldKeepConversationBottomAnchoredOnContentSizeChangeForTesting(
          isAnchoredToBottom: false,
          isUserInteractingWithScroll: false,
          wantsPinToTop: false,
        );

    expect(shouldKeepBottomAnchored, isFalse);
  });

  test('pin-to-top user scroll keeps phantom until removal is stable', () {
    expect(
      debugCanRemovePinToTopPhantomWithoutViewportJumpForTesting(
        currentOffset: 920,
        maxScrollExtent: 1200,
        phantomExtent: 400,
      ),
      isFalse,
    );
    expect(
      debugScrollOffsetAfterRemovingPinToTopPhantomForTesting(
        currentOffset: 920,
        maxScrollExtent: 1200,
        phantomExtent: 400,
      ),
      800,
    );

    expect(
      debugCanRemovePinToTopPhantomWithoutViewportJumpForTesting(
        currentOffset: 760,
        maxScrollExtent: 1200,
        phantomExtent: 400,
      ),
      isTrue,
    );
    expect(
      debugScrollOffsetAfterRemovingPinToTopPhantomForTesting(
        currentOffset: 760,
        maxScrollExtent: 1200,
        phantomExtent: 400,
      ),
      760,
    );
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

  test('composer height growth ignores pin-to-top mode and manual scrolling', () {
    final whilePinnedToTop =
        debugShouldKeepConversationBottomAnchoredOnComposerHeightChangeForTesting(
          previousComposerHeight: 0,
          nextComposerHeight: 160,
          isAnchoredToBottom: true,
          isUserInteractingWithScroll: false,
          wantsPinToTop: true,
        );
    final whileUserScrolling =
        debugShouldKeepConversationBottomAnchoredOnComposerHeightChangeForTesting(
          previousComposerHeight: 0,
          nextComposerHeight: 160,
          isAnchoredToBottom: true,
          isUserInteractingWithScroll: true,
          wantsPinToTop: false,
        );

    expect(whilePinnedToTop, isFalse);
    expect(whileUserScrolling, isFalse);
  });

  test('message content growth ignores pin-to-top mode and manual scrolling', () {
    final whilePinnedToTop =
        debugShouldKeepConversationBottomAnchoredOnContentSizeChangeForTesting(
          isAnchoredToBottom: true,
          isUserInteractingWithScroll: false,
          wantsPinToTop: true,
        );
    final whileUserScrolling =
        debugShouldKeepConversationBottomAnchoredOnContentSizeChangeForTesting(
          isAnchoredToBottom: true,
          isUserInteractingWithScroll: true,
          wantsPinToTop: false,
        );

    expect(whilePinnedToTop, isFalse);
    expect(whileUserScrolling, isFalse);
  });
}
