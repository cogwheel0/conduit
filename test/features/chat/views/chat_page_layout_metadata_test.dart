import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/views/chat_bottom_anchor_controller.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/hermes/services/hermes_session_provenance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
        scrollDelta: -4,
      ),
      isFalse,
    );
    expect(
      controller.shouldDetachForUserScrollAway(
        nearBottom: false,
        scrollDelta: -36,
      ),
      isTrue,
    );
    // Scrolling toward the bottom must not break the sticky latch.
    expect(
      controller.shouldDetachForUserScrollAway(
        nearBottom: false,
        scrollDelta: 36,
      ),
      isFalse,
    );

    controller.detachByUser();
    expect(controller.isAnchoredToBottom, isFalse);
  });

  test(
    'bottom anchor controller re-pins after detached programmatic scroll',
    () {
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
    },
  );

  test(
    'bottom anchor controller never detaches near bottom or when unanchored',
    () {
      final controller = ChatBottomAnchorController(
        showThreshold: 300,
        hideThreshold: 150,
      );

      controller.updateAnchor(
        hasScrollableContent: true,
        distanceFromBottom: 24,
      );
      controller.prepareForStickyContentChange(wantsPinToTop: false);

      // nearBottom short-circuits regardless of delta.
      expect(
        controller.shouldDetachForUserScrollAway(
          nearBottom: true,
          scrollDelta: 999,
        ),
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
    },
  );

  test(
    'bottom anchor controller keeps sticky pending when correction is mid-flight',
    () {
      final controller = ChatBottomAnchorController(
        showThreshold: 300,
        hideThreshold: 150,
      );

      controller.updateAnchor(
        hasScrollableContent: true,
        distanceFromBottom: 24,
      );
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
    },
  );

  test(
    'bottom anchor controller releases latch when sticky correction never reaches bottom',
    () {
      final controller = ChatBottomAnchorController(
        showThreshold: 300,
        hideThreshold: 150,
      );

      controller.updateAnchor(
        hasScrollableContent: true,
        distanceFromBottom: 24,
      );
      expect(
        controller.prepareForStickyContentChange(wantsPinToTop: false),
        isTrue,
      );

      // The final correction attempt is still far from the bottom: the latch must
      // clear so button visibility falls back to distance-based logic.
      controller.verifyStickyCorrection(
        nearBottom: false,
        isFinalAttempt: true,
      );

      expect(
        controller.shouldShowScrollToBottom(
          currentlyShowing: false,
          hasScrollableContent: true,
          distanceFromBottom: 320,
        ),
        isTrue,
      );
    },
  );

  test(
    'bottom anchor controller hysteresis keeps the button shown across the band',
    () {
      final controller = ChatBottomAnchorController(
        showThreshold: 300,
        hideThreshold: 150,
      );

      // Detach so the button is currently visible.
      controller.updateAnchor(
        hasScrollableContent: true,
        distanceFromBottom: 320,
      );

      // Already showing: in the 150-300 band the button stays shown (the hide
      // check uses hideThreshold, not showThreshold).
      expect(
        controller.shouldShowScrollToBottom(
          currentlyShowing: true,
          hasScrollableContent: true,
          distanceFromBottom: 200,
        ),
        isTrue,
      );

      // Already showing: at/under hideThreshold the button hides.
      expect(
        controller.shouldShowScrollToBottom(
          currentlyShowing: true,
          hasScrollableContent: true,
          distanceFromBottom: 100,
        ),
        isFalse,
      );

      // Contrast: a hidden button does not appear yet in the same band (the show
      // check uses showThreshold).
      expect(
        controller.shouldShowScrollToBottom(
          currentlyShowing: false,
          hasScrollableContent: true,
          distanceFromBottom: 200,
        ),
        isFalse,
      );
    },
  );

  test('bottom anchor controller re-anchors when content is not scrollable', () {
    final controller = ChatBottomAnchorController(
      showThreshold: 300,
      hideThreshold: 150,
    );

    // Detach first so the re-anchor is observable.
    controller.updateAnchor(
      hasScrollableContent: true,
      distanceFromBottom: 320,
    );
    expect(controller.isAnchoredToBottom, isFalse);

    // Even with a large distance, a non-scrollable list counts as nearBottom:
    // re-anchor, clear the sticky latch, and report anchored.
    expect(
      controller.updateAnchor(
        hasScrollableContent: false,
        distanceFromBottom: 320,
      ),
      isTrue,
    );
    expect(controller.isAnchoredToBottom, isTrue);

    // The latch was cleared, so a subsequent scroll away detaches immediately.
    expect(
      controller.updateAnchor(
        hasScrollableContent: true,
        distanceFromBottom: 320,
      ),
      isFalse,
    );

    // The button stays hidden whenever content is not scrollable.
    expect(
      controller.shouldShowScrollToBottom(
        currentlyShowing: false,
        hasScrollableContent: false,
        distanceFromBottom: 320,
      ),
      isFalse,
    );
  });

  test(
    'bottom anchor controller re-anchors when the final attempt is near bottom',
    () {
      final controller = ChatBottomAnchorController(
        showThreshold: 300,
        hideThreshold: 150,
      );

      controller.updateAnchor(
        hasScrollableContent: true,
        distanceFromBottom: 24,
      );
      controller.prepareForStickyContentChange(wantsPinToTop: false);
      // Detach so only the nearBottom branch can re-anchor (the isFinalAttempt
      // branch never sets isAnchoredToBottom back to true).
      controller.detachByUser();
      expect(controller.isAnchoredToBottom, isFalse);

      controller.verifyStickyCorrection(nearBottom: true, isFinalAttempt: true);

      // nearBottom wins over isFinalAttempt: re-anchored, not merely latch-dropped.
      expect(controller.isAnchoredToBottom, isTrue);
    },
  );

  test(
    'bottom anchor waits for movement, keeps a small drag, and detaches past the threshold',
    () {
      final controller = ChatBottomAnchorController(
        showThreshold: 300,
        hideThreshold: 150,
        userScrollAwayThreshold: 24,
      );

      controller.updateAnchor(
        hasScrollableContent: true,
        distanceFromBottom: 24,
      );
      expect(
        controller.prepareForStickyContentChange(wantsPinToTop: false),
        isTrue,
      );

      // User begins dragging during the sticky correction. A small (sub-threshold)
      // drag must NOT detach: updateAnchor keeps the anchor while the latch holds,
      // deferring the break to shouldDetachForUserScrollAway's threshold check.
      controller.isUserInteractingWithScroll = true;
      expect(
        controller.updateAnchor(
          hasScrollableContent: true,
          distanceFromBottom: 320,
        ),
        isTrue,
      );
      expect(controller.isAnchoredToBottom, isTrue);
      // Drag-start / directional notifications carry no delta. They must not
      // synthesize movement and detach before the user's actual drag is measured.
      expect(
        controller.shouldDetachForUserScrollAway(
          nearBottom: false,
          scrollDelta: null,
        ),
        isFalse,
      );
      expect(
        controller.shouldDetachForUserScrollAway(
          nearBottom: false,
          scrollDelta: -4,
        ),
        isFalse,
      );

      // But the scroll-to-bottom button still surfaces while interacting (the
      // distance-based hysteresis is not suppressed during a drag).
      expect(
        controller.shouldShowScrollToBottom(
          currentlyShowing: false,
          hasScrollableContent: true,
          distanceFromBottom: 320,
        ),
        isTrue,
      );

      // A drag past userScrollAwayThreshold breaks the latch via the scroll
      // handler, after which updateAnchor reports detached.
      expect(
        controller.shouldDetachForUserScrollAway(
          nearBottom: false,
          scrollDelta: -40,
        ),
        isTrue,
      );
      controller.detachByUser();
      expect(controller.isAnchoredToBottom, isFalse);
      expect(
        controller.updateAnchor(
          hasScrollableContent: true,
          distanceFromBottom: 320,
        ),
        isFalse,
      );
    },
  );

  test(
    'bottom anchor controller keeps the button hidden when the latch holds even if currently showing',
    () {
      final controller = ChatBottomAnchorController(
        showThreshold: 300,
        hideThreshold: 150,
      );

      controller.updateAnchor(
        hasScrollableContent: true,
        distanceFromBottom: 24,
      );
      expect(
        controller.prepareForStickyContentChange(wantsPinToTop: false),
        isTrue,
      );

      // Latch armed: even with the button already visible and a large distance,
      // the sticky latch short-circuits visibility to hidden.
      expect(
        controller.shouldShowScrollToBottom(
          currentlyShowing: true,
          hasScrollableContent: true,
          distanceFromBottom: 320,
        ),
        isFalse,
      );

      // Once the latch clears, the same call falls through to the hysteresis
      // branch and reports the button shown.
      controller.verifyStickyCorrection(
        nearBottom: false,
        isFinalAttempt: true,
      );
      expect(
        controller.shouldShowScrollToBottom(
          currentlyShowing: true,
          hasScrollableContent: true,
          distanceFromBottom: 320,
        ),
        isTrue,
      );
    },
  );

  test(
    'scroll update classifier handles touch and pointer input but ignores programmatic updates',
    () {
      expect(
        debugShouldTreatScrollUpdateAsUserDrivenForTesting(
          hasDragDetails: true,
          isUserInteractingWithScroll: false,
        ),
        isTrue,
        reason: 'touch updates carry drag details',
      );
      expect(
        debugShouldTreatScrollUpdateAsUserDrivenForTesting(
          hasDragDetails: false,
          isUserInteractingWithScroll: true,
        ),
        isTrue,
        reason: 'wheel/trackpad updates follow a user-direction notification',
      );
      expect(
        debugShouldTreatScrollUpdateAsUserDrivenForTesting(
          hasDragDetails: false,
          isUserInteractingWithScroll: false,
        ),
        isFalse,
        reason: 'programmatic updates have neither user signal',
      );
    },
  );

  test(
    'live turn only uses smooth bottom-follow while the response is running',
    () {
      final running = ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: 'Partial',
        timestamp: DateTime(2024, 1, 1),
        isStreaming: true,
      );

      expect(
        debugShouldSmoothFollowLiveTurnSizeChangeForTesting([running]),
        isTrue,
      );
      expect(
        debugShouldSmoothFollowLiveTurnSizeChangeForTesting([
          running.copyWith(metadata: const {'responseDone': true}),
        ]),
        isFalse,
        reason: 'responseDone is settled even before isStreaming flips',
      );
      expect(
        debugShouldSmoothFollowLiveTurnSizeChangeForTesting([
          running.copyWith(isStreaming: false, followUps: const ['Ask next']),
        ]),
        isFalse,
        reason:
            'follow-up insertion must preserve the bottom without animation',
      );
    },
  );

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

  test('long assistant responses estimate beyond the old 2400 clamp', () {
    final longContent = List<String>.filled(
      400,
      'This is a sentence in a long streamed response.',
    ).join(' ');
    final summary = debugBuildChatListLayoutSummaryForTesting([
      ChatMessage(
        id: 'assistant-long',
        role: 'assistant',
        content: longContent,
        timestamp: DateTime(2026),
      ),
    ]);

    // The pathological 2400 cap made tall rows estimate far below their real
    // height, producing a large scroll-offset correction (jump that skipped the
    // prompt) on first reveal during upward scroll.
    expect(summary.single.estimatedExtent, greaterThan(2400));
  });

  test('a generated data-uri image does not over-estimate row extent', () {
    final base64Payload = List<String>.filled(20000, 'A').join();
    final summary = debugBuildChatListLayoutSummaryForTesting([
      ChatMessage(
        id: 'assistant-image',
        role: 'assistant',
        content: '![](data:image/png;base64,$base64Payload)',
        timestamp: DateTime(2026),
      ),
    ]);

    // The huge base64 payload must be excluded from the line estimate so the
    // raised clamp ceiling can't inflate an image to image-as-text height.
    expect(summary.single.estimatedExtent, lessThan(2000));
  });

  test('a raw standalone base64 image line estimates its rendered height', () {
    final base64Payload = List<String>.filled(20000, 'A').join();
    final summary = debugBuildChatListLayoutSummaryForTesting([
      ChatMessage(
        id: 'assistant-raw-image',
        role: 'assistant',
        content: 'Here is the image:\n\ndata:image/png;base64,$base64Payload',
        timestamp: DateTime(2026),
      ),
    ]);

    // A raw base64 line (no markdown wrapper) is rendered as an image, so it
    // must add a per-image height term rather than estimating as ~one line of
    // text (which would under-estimate and re-introduce the scroll jump).
    final extent = summary.single.estimatedExtent;
    expect(extent, greaterThan(220));
    expect(extent, lessThan(2000));
  });

  test('image markup inside a fenced code block counts as verbatim text', () {
    final base64Payload = List<String>.filled(20000, 'A').join();
    final codeSample =
        '```\n![alt](https://example.com/x.png)\ndata:image/png;base64,$base64Payload\n```';
    final summary = debugBuildChatListLayoutSummaryForTesting([
      ChatMessage(
        id: 'assistant-code',
        role: 'assistant',
        content: codeSample,
        timestamp: DateTime(2026),
      ),
    ]);

    // The code block renders its content (including the base64) verbatim, so the
    // estimate must reflect that large text height — not strip the base64 and
    // treat the markup as a couple of small images (which would under-estimate).
    expect(summary.single.estimatedExtent, greaterThan(2400));
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

  test('layout metadata resolves an Open WebUI direct wire model id', () {
    final registry = DirectModelRegistry();
    final directModel = registry
        .replaceProfileModels(
          DirectConnectionProfile(
            id: 'server-profile',
            name: 'Server connection',
            adapterKey: kOpenAiCompatibleAdapterKey,
            baseUrl: 'https://provider.example/v1',
            modelIdPrefix: 'server-prefix',
          ),
          [DirectRemoteModel(id: 'model', name: 'Provider model')],
          source: DirectModelSource.openWebUi,
          openWebUiUrlIndex: 2,
        )
        .single;
    final messages = <ChatMessage>[
      ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: 'Visible response',
        timestamp: DateTime(2026),
        model: 'server-prefix.model',
      ),
    ];

    final summary = debugBuildChatListLayoutSummaryForTesting(
      messages,
      models: <Model>[
        directModel,
        const Model(id: 'server-prefix.model', name: 'Server collision'),
      ],
      directModelRegistry: registry,
    );

    expect(summary.single.displayModelName, 'server-prefix.Provider model');
  });

  test('layout cache refreshes when direct model bindings change', () {
    final registry = DirectModelRegistry();
    final directModel = registry
        .replaceProfileModels(
          DirectConnectionProfile(
            id: 'server-profile',
            name: 'Server connection',
            adapterKey: kOpenAiCompatibleAdapterKey,
            baseUrl: 'https://provider.example/v1',
            modelIdPrefix: 'server-prefix',
          ),
          [DirectRemoteModel(id: 'model', name: 'Provider model')],
          source: DirectModelSource.openWebUi,
          openWebUiUrlIndex: 2,
        )
        .single;
    final models = <Model>[
      directModel,
      const Model(id: 'server-prefix.model', name: 'Server collision'),
    ];
    final messages = <ChatMessage>[
      ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: 'Visible response',
        timestamp: DateTime(2026),
        model: 'server-prefix.model',
      ),
    ];
    final cache = debugCreateChatListStableLayoutCacheForTesting();

    expect(
      debugResolveChatListStableLayoutCacheForTesting(
        cache,
        messages,
        models: models,
        directModelRegistry: registry,
      ).single.displayModelName,
      'server-prefix.Provider model',
    );
    expect(
      debugResolveChatListStableLayoutCacheForTesting(
        cache,
        messages,
        models: models,
        directModelRegistry: registry,
      ).single.displayModelName,
      'server-prefix.Provider model',
    );

    registry.removeProfile('server-profile');

    expect(
      debugResolveChatListStableLayoutCacheForTesting(
        cache,
        messages,
        models: models,
        directModelRegistry: registry,
      ).single.displayModelName,
      'Server collision',
    );
  });

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
    // Two short turns can leave the second prompt pinned beyond the real
    // (phantom-free) scroll range. Ending the first drag must not force this
    // offset to zero, which would jump back to the first message (#560).
    expect(
      debugCanRemovePinToTopPhantomWithoutViewportJumpForTesting(
        currentOffset: 500,
        maxScrollExtent: 800,
        phantomExtent: 800,
      ),
      isFalse,
    );
    expect(
      debugScrollOffsetAfterRemovingPinToTopPhantomForTesting(
        currentOffset: 500,
        maxScrollExtent: 800,
        phantomExtent: 800,
      ),
      0,
    );

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

  test('long scrolls animate only their final viewport', () {
    expect(
      debugScrollAnimationStartOffsetForTesting(
        currentOffset: 0,
        targetOffset: 2000,
        viewportDimension: 600,
        minScrollExtent: 0,
        maxScrollExtent: 2000,
      ),
      1400,
    );
    expect(
      debugScrollAnimationStartOffsetForTesting(
        currentOffset: 2000,
        targetOffset: 200,
        viewportDimension: 600,
        minScrollExtent: 0,
        maxScrollExtent: 2000,
      ),
      800,
    );
  });

  test('nearby scroll targets animate from the current position', () {
    expect(
      debugScrollAnimationStartOffsetForTesting(
        currentOffset: 900,
        targetOffset: 1300,
        viewportDimension: 600,
        minScrollExtent: 0,
        maxScrollExtent: 2000,
      ),
      900,
    );
  });

  test(
    'refresh ignores native Hermes and direct-local id collisions',
    () async {
      final workerManager = WorkerManager();
      final api = _GatedConversationRefreshApi(workerManager);
      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      addTearDown(workerManager.dispose);
      const rawId = 'local:hermes_refresh-collision';
      final native = markNativeHermesConversation(
        _refreshConversation(rawId, 'Native Hermes'),
      );
      container.read(activeConversationProvider.notifier).set(native);

      await refreshActiveOpenWebUiConversation(container);

      check(api.fetches).equals(0);
      check(
        identical(container.read(activeConversationProvider), native),
      ).isTrue();
      check(
        isNativeHermesConversation(container.read(activeConversationProvider)),
      ).isTrue();

      final direct = _refreshConversation(rawId, 'Temporary direct').copyWith(
        metadata: const <String, dynamic>{'backend': kDirectChatBackend},
      );
      container.read(activeConversationProvider.notifier).set(direct);

      await refreshActiveOpenWebUiConversation(container);

      check(api.fetches).equals(0);
      check(
        identical(container.read(activeConversationProvider), direct),
      ).isTrue();
    },
  );

  test('stale refresh cannot replace a same-id active generation', () async {
    final workerManager = WorkerManager();
    final api = _GatedConversationRefreshApi(workerManager);
    final container = ProviderContainer(
      overrides: [apiServiceProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    addTearDown(workerManager.dispose);
    const rawId = 'server-refresh-id';
    final original = withChatStorageProvenance(
      _refreshConversation(rawId, 'Original'),
      ChatStorageKind.openWebUi,
    );
    container.read(activeConversationProvider.notifier).set(original);

    final refresh = refreshActiveOpenWebUiConversation(container);
    await api.started.future.timeout(const Duration(seconds: 1));
    final replacement = withChatStorageProvenance(
      _refreshConversation(rawId, 'Replacement'),
      ChatStorageKind.openWebUi,
    );
    container.read(activeConversationProvider.notifier).set(replacement);
    api.response.complete(_refreshConversation(rawId, 'Stale response'));
    await refresh;

    check(
      identical(container.read(activeConversationProvider), replacement),
    ).isTrue();
  });

  test('refresh replaces an unchanged OpenWebUI conversation', () async {
    final workerManager = WorkerManager();
    final api = _GatedConversationRefreshApi(workerManager);
    final container = ProviderContainer(
      overrides: [apiServiceProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    addTearDown(workerManager.dispose);
    const rawId = 'server-refresh-success';
    final original = withChatStorageProvenance(
      _refreshConversation(rawId, 'Original'),
      ChatStorageKind.openWebUi,
    );
    container.read(activeConversationProvider.notifier).set(original);

    final refresh = refreshActiveOpenWebUiConversation(container);
    await api.started.future.timeout(const Duration(seconds: 1));
    api.response.complete(_refreshConversation(rawId, 'Refreshed'));
    await refresh;

    final refreshed = container.read(activeConversationProvider)!;
    check(api.fetches).equals(1);
    check(refreshed.title).equals('Refreshed');
    check(chatStorageKindOf(refreshed)).equals(ChatStorageKind.openWebUi);
  });

  test('refresh rejects a response for a different conversation id', () async {
    final workerManager = WorkerManager();
    final api = _GatedConversationRefreshApi(workerManager);
    final container = ProviderContainer(
      overrides: [apiServiceProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    addTearDown(workerManager.dispose);
    const rawId = 'server-refresh-mismatch';
    final original = withChatStorageProvenance(
      _refreshConversation(rawId, 'Original'),
      ChatStorageKind.openWebUi,
    );
    container.read(activeConversationProvider.notifier).set(original);

    final refresh = refreshActiveOpenWebUiConversation(container);
    await api.started.future.timeout(const Duration(seconds: 1));
    api.response.complete(_refreshConversation('different-id', 'Wrong row'));
    await refresh;

    check(
      identical(container.read(activeConversationProvider), original),
    ).isTrue();
  });

  test('refresh exposes API errors for the caller to report', () async {
    final workerManager = WorkerManager();
    final api = _GatedConversationRefreshApi(workerManager);
    final container = ProviderContainer(
      overrides: [apiServiceProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    addTearDown(workerManager.dispose);
    const rawId = 'server-refresh-error';
    final original = withChatStorageProvenance(
      _refreshConversation(rawId, 'Original'),
      ChatStorageKind.openWebUi,
    );
    container.read(activeConversationProvider.notifier).set(original);

    final refresh = refreshActiveOpenWebUiConversation(container);
    await api.started.future.timeout(const Duration(seconds: 1));
    api.response.completeError(StateError('refresh failed'));

    await expectLater(refresh, throwsA(isA<StateError>()));
    check(
      identical(container.read(activeConversationProvider), original),
    ).isTrue();
  });
}

Conversation _refreshConversation(String id, String title) => Conversation(
  id: id,
  title: title,
  createdAt: DateTime(2024),
  updatedAt: DateTime(2024),
);

final class _GatedConversationRefreshApi extends ApiService {
  _GatedConversationRefreshApi(WorkerManager workerManager)
    : super(
        serverConfig: const ServerConfig(
          id: 'refresh-server',
          name: 'Refresh server',
          url: 'https://refresh.example',
        ),
        workerManager: workerManager,
      );

  final started = Completer<void>();
  final response = Completer<Conversation>();
  int fetches = 0;

  @override
  Future<Conversation> getConversation(String id) {
    fetches++;
    if (!started.isCompleted) started.complete();
    return response.future;
  }
}
