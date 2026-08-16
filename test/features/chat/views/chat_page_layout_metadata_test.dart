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
import 'package:conduit/features/chat/views/chat_turn_render_state.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/hermes/services/hermes_session_provenance.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('message cache shrinks for streaming and virtualized rows', () {
    check(debugChatMessageScrollCachePixels(streaming: false)).equals(600);
    check(debugChatMessageScrollCachePixels(streaming: true)).equals(120);
    check(
      debugChatMessageScrollCachePixels(
        streaming: false,
        hasVirtualizedRows: true,
      ),
    ).equals(300);
    check(
      debugChatMessageScrollCachePixels(
        streaming: true,
        hasVirtualizedRows: true,
      ),
    ).equals(120);
  });

  testWidgets(
    'assistant row state survives the live-tail to history transition',
    (tester) async {
      var mounts = 0;
      var disposals = 0;

      Widget build({required bool includeRunningFooter}) {
        return MaterialApp(
          home: Column(
            children: [
              debugBuildAssistantTimelineSlotForTesting(
                assistantRow: _LifecycleProbe(
                  key: const ValueKey('assistant-row'),
                  onMount: () => mounts += 1,
                  onDispose: () => disposals += 1,
                ),
              ),
              if (includeRunningFooter)
                const SizedBox(key: ValueKey('running-footer')),
            ],
          ),
        );
      }

      await tester.pumpWidget(build(includeRunningFooter: true));
      check(mounts).equals(1);
      check(disposals).equals(0);

      await tester.pumpWidget(build(includeRunningFooter: false));

      check(mounts).equals(1);
      check(disposals).equals(0);
    },
  );

  test('bottom anchor controller separates anchored and detached states', () {
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

  test('explicit bottom request re-arms live content anchoring', () {
    final controller =
        ChatBottomAnchorController(showThreshold: 300, hideThreshold: 150)
          ..detachByUser()
          ..isUserInteractingWithScroll = true;

    controller.requestBottomAnchor();

    expect(controller.isAnchoredToBottom, isTrue);
    expect(controller.isUserInteractingWithScroll, isFalse);
    expect(controller.isUserDetachedFromBottom, isFalse);
    expect(
      controller.shouldKeepAnchoredOnContentSizeChange(wantsPinToTop: false),
      isTrue,
    );
  });

  test('older paging requires navigation, history, and an oldest row', () {
    check(
      debugShouldLoadOlderPageForTesting(
        hasUserScrolled: true,
        hasOlder: true,
        isLoadingOlder: false,
        anyOldestLoadedRowVisible: true,
      ),
    ).isTrue();
    check(
      debugShouldLoadOlderPageForTesting(
        hasUserScrolled: false,
        hasOlder: true,
        isLoadingOlder: false,
        anyOldestLoadedRowVisible: true,
      ),
    ).isFalse();
    check(
      debugShouldLoadOlderPageForTesting(
        hasUserScrolled: true,
        hasOlder: false,
        isLoadingOlder: false,
        anyOldestLoadedRowVisible: true,
      ),
    ).isFalse();
    check(
      debugShouldLoadOlderPageForTesting(
        hasUserScrolled: true,
        hasOlder: true,
        isLoadingOlder: true,
        anyOldestLoadedRowVisible: true,
      ),
    ).isFalse();
    check(
      debugShouldLoadOlderPageForTesting(
        hasUserScrolled: true,
        hasOlder: true,
        isLoadingOlder: false,
        anyOldestLoadedRowVisible: false,
      ),
    ).isFalse();
  });

  test('deferred chat mutations are fenced to the scheduled conversation', () {
    expect(
      debugShouldApplyDeferredConversationMutationForTesting(
        isMounted: true,
        scheduledConversationId: 'chat-a',
        activeConversationId: 'chat-a',
        scheduledGeneration: 7,
        activeGeneration: 7,
      ),
      isTrue,
    );
    expect(
      debugShouldApplyDeferredConversationMutationForTesting(
        isMounted: true,
        scheduledConversationId: 'chat-a',
        activeConversationId: 'chat-b',
        scheduledGeneration: 7,
        activeGeneration: 7,
      ),
      isFalse,
    );
    expect(
      debugShouldApplyDeferredConversationMutationForTesting(
        isMounted: false,
        scheduledConversationId: 'chat-a',
        activeConversationId: 'chat-a',
        scheduledGeneration: 7,
        activeGeneration: 7,
      ),
      isFalse,
    );
    expect(
      debugShouldApplyDeferredConversationMutationForTesting(
        isMounted: true,
        scheduledConversationId: null,
        activeConversationId: null,
        scheduledGeneration: 7,
        activeGeneration: 7,
      ),
      isFalse,
    );
    expect(
      debugShouldApplyDeferredConversationMutationForTesting(
        isMounted: true,
        scheduledConversationId: 'chat-a',
        activeConversationId: 'chat-a',
        scheduledGeneration: 7,
        activeGeneration: 9,
      ),
      isFalse,
    );
  });

  test('temporary-chat save blocks composer and send submission', () {
    expect(
      debugCanSubmitChatMessageForTesting(
        isLoadingConversation: false,
        isSavingTemporary: false,
        isPreparingMessageSend: false,
      ),
      isTrue,
    );
    expect(
      debugCanSubmitChatMessageForTesting(
        isLoadingConversation: false,
        isSavingTemporary: true,
        isPreparingMessageSend: false,
      ),
      isFalse,
    );
    expect(
      debugCanSubmitChatMessageForTesting(
        isLoadingConversation: true,
        isSavingTemporary: false,
        isPreparingMessageSend: false,
      ),
      isFalse,
    );
    expect(
      debugCanSubmitChatMessageForTesting(
        isLoadingConversation: false,
        isSavingTemporary: false,
        isPreparingMessageSend: true,
      ),
      isFalse,
    );
  });

  test('older send cleanup cannot release a newer send admission', () {
    final guard = ChatMessageSendAdmissionGuard();
    final firstSend = guard.tryAcquire();
    expect(firstSend, isNotNull);
    expect(guard.isHeld, isTrue);
    expect(guard.tryAcquire(), isNull);

    expect(guard.release(firstSend!), isTrue);
    final secondSend = guard.tryAcquire();
    expect(secondSend, isNotNull);

    expect(guard.release(firstSend), isFalse);
    expect(guard.isHeld, isTrue);
    expect(guard.release(secondSend!), isTrue);
    expect(guard.isHeld, isFalse);
  });

  test('screen context is consumed only by its accepted send', () {
    check(
      debugShouldConsumeScreenContextForTesting(
        sendDispatched: false,
        submittedContext: 'screen-a',
        currentContext: 'screen-a',
      ),
    ).isFalse();
    check(
      debugShouldConsumeScreenContextForTesting(
        sendDispatched: true,
        submittedContext: 'screen-a',
        currentContext: 'screen-b',
      ),
    ).isFalse();
    check(
      debugShouldConsumeScreenContextForTesting(
        sendDispatched: true,
        submittedContext: 'screen-a',
        currentContext: 'screen-a',
      ),
    ).isTrue();
  });

  test('pending screen context retries after non-consumption', () {
    check(
      debugShouldRetryScreenContextForTesting(
        sendDispatched: false,
        submittedContext: 'screen-a',
        currentContext: 'screen-a',
        sendAdmissionHeld: false,
        isSavingTemporary: false,
        isLoadingConversation: false,
      ),
    ).isTrue();
    check(
      debugShouldRetryScreenContextForTesting(
        sendDispatched: true,
        submittedContext: 'screen-a',
        currentContext: 'screen-b',
        sendAdmissionHeld: false,
        isSavingTemporary: false,
        isLoadingConversation: false,
      ),
    ).isTrue();
    check(
      debugShouldRetryScreenContextForTesting(
        sendDispatched: true,
        submittedContext: 'screen-a',
        currentContext: 'screen-a',
        sendAdmissionHeld: false,
        isSavingTemporary: false,
        isLoadingConversation: false,
      ),
    ).isFalse();
    check(
      debugShouldRetryScreenContextForTesting(
        sendDispatched: false,
        submittedContext: 'screen-a',
        currentContext: 'screen-a',
        sendAdmissionHeld: true,
        isSavingTemporary: false,
        isLoadingConversation: false,
      ),
    ).isFalse();
  });

  test('undispatched screen context retries use bounded backoff', () {
    check(debugScreenContextRetryDelayForTesting(completedRetries: 0))
        .equals(const Duration(milliseconds: 250));
    check(debugScreenContextRetryDelayForTesting(completedRetries: 1))
        .equals(const Duration(milliseconds: 500));
    check(debugScreenContextRetryDelayForTesting(completedRetries: 2))
        .equals(const Duration(seconds: 1));
    check(debugScreenContextRetryDelayForTesting(completedRetries: 3)).isNull();
  });

  test('latest button follows free-scroll ownership, not stale metrics', () {
    check(
      debugShouldExposeScrollToLatestForTesting(
        hasScrollableContent: false,
        pinAutoFollowing: true,
        freeScrolling: false,
        bottomAnchorDetached: false,
        currentlyShowing: false,
        distanceFromLatest: 100,
      ),
    ).isFalse();
    check(
      debugShouldExposeScrollToLatestForTesting(
        hasScrollableContent: true,
        pinAutoFollowing: true,
        freeScrolling: false,
        bottomAnchorDetached: false,
        currentlyShowing: false,
        distanceFromLatest: 100,
      ),
    ).isFalse();
    check(
      debugShouldExposeScrollToLatestForTesting(
        hasScrollableContent: true,
        pinAutoFollowing: false,
        freeScrolling: true,
        bottomAnchorDetached: true,
        currentlyShowing: false,
        distanceFromLatest: 48,
      ),
    ).isFalse();
    check(
      debugShouldExposeScrollToLatestForTesting(
        hasScrollableContent: true,
        pinAutoFollowing: false,
        freeScrolling: true,
        bottomAnchorDetached: true,
        currentlyShowing: false,
        distanceFromLatest: 49,
      ),
    ).isTrue();
    check(
      debugShouldExposeScrollToLatestForTesting(
        hasScrollableContent: true,
        pinAutoFollowing: false,
        freeScrolling: false,
        bottomAnchorDetached: false,
        currentlyShowing: false,
        distanceFromLatest: 100,
      ),
    ).isFalse();
    check(
      debugShouldExposeScrollToLatestForTesting(
        hasScrollableContent: true,
        pinAutoFollowing: false,
        freeScrolling: true,
        bottomAnchorDetached: true,
        currentlyShowing: true,
        distanceFromLatest: 12,
      ),
    ).isFalse();
    check(
      debugShouldExposeScrollToLatestForTesting(
        hasScrollableContent: true,
        pinAutoFollowing: true,
        freeScrolling: true,
        bottomAnchorDetached: true,
        currentlyShowing: false,
        distanceFromLatest: 100,
      ),
    ).isFalse();
    check(
      debugShouldExposeScrollToLatestForTesting(
        hasScrollableContent: true,
        pinAutoFollowing: false,
        freeScrolling: true,
        bottomAnchorDetached: false,
        currentlyShowing: false,
        distanceFromLatest: 100,
      ),
    ).isTrue();
  });

  test('latest button remains eligible while the composer is expanded', () {
    check(
      debugShouldRenderScrollToLatestForTesting(
        requested: true,
        hasScrollableContent: true,
        hasMessages: true,
      ),
    ).isTrue();
    check(
      debugShouldRenderScrollToLatestForTesting(
        requested: false,
        hasScrollableContent: true,
        hasMessages: true,
      ),
    ).isFalse();
    check(
      debugShouldRenderScrollToLatestForTesting(
        requested: true,
        hasScrollableContent: false,
        hasMessages: true,
      ),
    ).isFalse();
    check(
      debugShouldRenderScrollToLatestForTesting(
        requested: true,
        hasScrollableContent: true,
        hasMessages: false,
      ),
    ).isFalse();
  });

  test('only the first turn settles its pin without animation', () {
    expect(
      debugShouldSettlePinImmediatelyForTesting(transcriptWasEmpty: true),
      isTrue,
    );
    expect(
      debugShouldSettlePinImmediatelyForTesting(transcriptWasEmpty: false),
      isFalse,
    );
    expect(
      debugShouldHideTranscriptForInitialPinForTesting(
        settleImmediately: true,
        positionSettled: false,
      ),
      isTrue,
    );
    expect(
      debugShouldHideTranscriptForInitialPinForTesting(
        settleImmediately: true,
        positionSettled: true,
      ),
      isFalse,
    );
    expect(
      debugShouldHideTranscriptForInitialPinForTesting(
        settleImmediately: false,
        positionSettled: false,
      ),
      isFalse,
    );
  });

  test('deep-history pin prepositions once after the controller attaches', () {
    check(
      debugShouldPrepositionPinnedTurnForTesting(
        hasClients: false,
        targetRowMounted: false,
        prepositionAttempted: false,
      ),
    ).isFalse();
    check(
      debugShouldPrepositionPinnedTurnForTesting(
        hasClients: true,
        targetRowMounted: false,
        prepositionAttempted: false,
      ),
    ).isTrue();
    check(
      debugShouldPrepositionPinnedTurnForTesting(
        hasClients: true,
        targetRowMounted: false,
        prepositionAttempted: true,
      ),
    ).isFalse();
    check(
      debugShouldPrepositionPinnedTurnForTesting(
        hasClients: true,
        targetRowMounted: true,
        prepositionAttempted: false,
      ),
    ).isFalse();
  });

  test('first conversation binding preserves the active turn pin', () {
    check(
      debugShouldPreservePinnedFirstTurnForConversationBindingForTesting(
        pinActive: true,
        previousConversationId: null,
        nextConversationId: 'openwebui:local:new-chat',
      ),
    ).isTrue();
    check(
      debugShouldPreservePinnedFirstTurnForConversationBindingForTesting(
        pinActive: false,
        previousConversationId: null,
        nextConversationId: 'openwebui:local:new-chat',
      ),
    ).isFalse();
    check(
      debugShouldPreservePinnedFirstTurnForConversationBindingForTesting(
        pinActive: true,
        previousConversationId: 'openwebui:old-chat',
        nextConversationId: 'openwebui:new-chat',
      ),
    ).isFalse();
    check(
      debugShouldPreservePinnedFirstTurnForConversationBindingForTesting(
        pinActive: true,
        previousConversationId: null,
        nextConversationId: null,
      ),
    ).isFalse();
  });

  test('bottom anchor controller hysteresis keeps the button shown across the band', () {
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
  });

  test(
    'bottom anchor controller preserves explicit short-content detachment',
    () {
      final controller = ChatBottomAnchorController(
        showThreshold: 300,
        hideThreshold: 150,
      );

      controller.detachByUser();
      expect(controller.isAnchoredToBottom, isFalse);

      // The button threshold can classify a short conversation as having no
      // scrollable content even after the user deliberately scrolls away.
      expect(
        controller.updateAnchor(
          hasScrollableContent: false,
          distanceFromBottom: 200,
        ),
        isFalse,
      );
      expect(controller.isAnchoredToBottom, isFalse);

      // Returning within the hide threshold explicitly reattaches.
      expect(
        controller.updateAnchor(
          hasScrollableContent: false,
          distanceFromBottom: 100,
        ),
        isTrue,
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
    },
  );

  testWidgets('layout metadata keeps archived assistant rows at zero extent', (
    tester,
  ) async {
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

    const archivedKey = ValueKey<String>('archived-assistant-placeholder');
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            const SizedBox(height: 20),
            debugBuildArchivedAssistantPlaceholderForTesting(key: archivedKey),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
    expect(tester.getSize(find.byKey(archivedKey)).height, 0);
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

  test(
    'layout cache skips structural signature work for an identical list',
    () {
      final cache = debugCreateChatListStableLayoutCacheForTesting();
      final registry = DirectModelRegistry();
      final messages = <ChatMessage>[
        ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          content: 'Stable response',
          timestamp: DateTime(2026),
        ),
      ];

      debugResolveChatListStableLayoutCacheForTesting(
        cache,
        messages,
        models: null,
        directModelRegistry: registry,
      );
      debugResolveChatListStableLayoutCacheForTesting(
        cache,
        messages,
        models: null,
        directModelRegistry: registry,
      );

      check(debugChatListStableLayoutSignatureBuildCountForTesting(cache))
          .equals(1);

      debugResolveChatListStableLayoutCacheForTesting(
        cache,
        List<ChatMessage>.of(messages),
        models: null,
        directModelRegistry: registry,
      );
      check(debugChatListStableLayoutSignatureBuildCountForTesting(cache))
          .equals(2);
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

  test('markdown prewarm candidates prioritize exact visible message IDs', () {
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
      visibleMessageIds: const ['assistant-3', 'assistant-4'],
      maxCount: 3,
    );

    // Reverse-visible seeds come first, then outward neighbors with forward
    // indices preferred before backward indices.
    expect(indices, <int>[4, 3, 5]);

    final cappedVisibleSeeds =
        debugSelectMarkdownPrewarmCandidateIndicesForTesting(
          messages,
          visibleMessageIds: const [
            'assistant-2',
            'assistant-3',
            'assistant-4',
          ],
          maxCount: 2,
        );
    expect(cappedVisibleSeeds, <int>[4, 3]);
  });

  test('markdown prewarm expands from visible rows to adjacent rows', () {
    final messages = List<ChatMessage>.generate(6, (index) {
      return ChatMessage(
        id: 'assistant-$index',
        role: 'assistant',
        content: 'Visible response $index',
        timestamp: DateTime(2026),
      );
    });

    final indices = debugSelectMarkdownPrewarmCandidateIndicesForTesting(
      messages,
      visibleMessageIds: const ['assistant-4'],
      maxCount: 3,
    );

    // Reverse-visible seeds come first, then outward neighbors with forward
    // indices preferred before backward indices.
    expect(indices, <int>[4, 5, 3]);
  });

  test('markdown prewarm returns no candidates without visible IDs', () {
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
      visibleMessageIds: const [],
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
      visibleMessageIds: const ['assistant-1', 'assistant-2'],
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

  test('message content growth preserves bottom anchor when already pinned', () {
    final shouldKeepBottomAnchored =
        debugShouldKeepConversationBottomAnchoredOnContentSizeChangeForTesting(
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

  test('message content growth does not jump when user left the bottom', () {
    final shouldKeepBottomAnchored =
        debugShouldKeepConversationBottomAnchoredOnContentSizeChangeForTesting(
          isAnchoredToBottom: false,
          isUserInteractingWithScroll: false,
          wantsPinToTop: false,
        );

    expect(shouldKeepBottomAnchored, isFalse);
  });

  test('pin-to-top reserves only the measured unused viewport', () {
    // Mirrors T3 Code's anchoredEndSpace contract: the synthetic tail is the
    // viewport remainder below the anchored turn, not a full-screen spacer.
    expect(
      resolveChatAnchoredEndSpaceExtent(
        availableExtent: 700,
        contentExtentFromAnchor: 260,
      ),
      440,
    );
    expect(
      resolveChatAnchoredEndSpaceExtent(
        availableExtent: 700,
        contentExtentFromAnchor: 600,
      ),
      100,
    );
    expect(
      resolveChatAnchoredEndSpaceExtent(
        availableExtent: 700,
        contentExtentFromAnchor: 760,
      ),
      0,
    );
  });

  test('manual navigation cancels follow without discarding the anchor', () {
    final state = debugPinStateAfterManualNavigationForTesting();

    expect(state.anchorActive, isTrue);
    expect(state.autoFollowing, isFalse);
    expect(state.userMessageId, 'user-message');
  });

  test('streaming follow never replaces an active pin-to-top anchor', () {
    check(
      debugShouldFollowStreamingForTesting(
        hasRunningTurn: true,
        isAnchoredToBottom: false,
        isUserInteracting: false,
        isExplicitNavigationInFlight: false,
        wantsPinToTop: true,
        followLatestRequested: false,
        pinnedEndSpaceExhausted: true,
      ),
    ).isFalse();
    check(
      debugShouldFollowStreamingForTesting(
        hasRunningTurn: true,
        isAnchoredToBottom: true,
        isUserInteracting: false,
        isExplicitNavigationInFlight: false,
        wantsPinToTop: true,
        followLatestRequested: true,
        pinnedEndSpaceExhausted: false,
      ),
    ).isFalse();
  });

  test('an active pin never transfers to per-chunk footer following', () {
    check(
      debugShouldFollowStreamingForTesting(
        hasRunningTurn: true,
        isAnchoredToBottom: false,
        isUserInteracting: false,
        isExplicitNavigationInFlight: false,
        wantsPinToTop: true,
        followLatestRequested: true,
        pinnedEndSpaceExhausted: true,
      ),
    ).isFalse();
    check(
      debugShouldFollowStreamingForTesting(
        hasRunningTurn: true,
        isAnchoredToBottom: false,
        isUserInteracting: false,
        isExplicitNavigationInFlight: false,
        wantsPinToTop: true,
        followLatestRequested: false,
        pinnedEndSpaceExhausted: true,
      ),
    ).isFalse();
  });

  test('streaming follow yields immediately to manual navigation', () {
    check(
      debugShouldFollowStreamingForTesting(
        hasRunningTurn: true,
        isAnchoredToBottom: true,
        isUserInteracting: true,
        isExplicitNavigationInFlight: false,
        wantsPinToTop: false,
        followLatestRequested: true,
        pinnedEndSpaceExhausted: true,
      ),
    ).isFalse();
  });

  test('streaming maintenance waits for explicit latest navigation', () {
    check(
      debugShouldFollowStreamingForTesting(
        hasRunningTurn: true,
        isAnchoredToBottom: false,
        isUserInteracting: false,
        isExplicitNavigationInFlight: true,
        wantsPinToTop: false,
        followLatestRequested: true,
        pinnedEndSpaceExhausted: true,
      ),
    ).isFalse();
  });

  test('only the current explicit navigation completion clears its fence', () {
    check(
      debugCompletionOwnsExplicitLatestNavigationForTesting(
        completedGeneration: null,
        currentGeneration: 3,
      ),
    ).isFalse();
    check(
      debugCompletionOwnsExplicitLatestNavigationForTesting(
        completedGeneration: 2,
        currentGeneration: 3,
      ),
    ).isFalse();
    check(
      debugCompletionOwnsExplicitLatestNavigationForTesting(
        completedGeneration: 3,
        currentGeneration: 3,
      ),
    ).isTrue();
  });

  test('pin lifecycle releases only for manual drag and latest', () {
    check(
      debugShouldReleasePinnedTurnForManualNavigationForTesting(
        pinActive: true,
        userDragStarted: false,
        latestRequested: true,
      ),
    ).isTrue();
    check(
      debugShouldReleasePinnedTurnForManualNavigationForTesting(
        pinActive: true,
        userDragStarted: true,
        latestRequested: false,
      ),
    ).isTrue();
    check(
      debugShouldReleasePinnedTurnForManualNavigationForTesting(
        pinActive: true,
        userDragStarted: true,
        latestRequested: true,
      ),
    ).isTrue();
    check(
      debugShouldReleasePinnedTurnForManualNavigationForTesting(
        pinActive: false,
        userDragStarted: true,
        latestRequested: false,
      ),
    ).isFalse();
    check(
      debugShouldReleasePinnedTurnForManualNavigationForTesting(
        pinActive: false,
        userDragStarted: false,
        latestRequested: true,
      ),
    ).isFalse();
  });

  test('terminal lifecycle retires pin support without manual navigation', () {
    check(
      debugShouldRetirePinnedTurnForLifecycleForTesting(
        pinActive: true,
        assistantPhase: ChatTurnPhase.running,
      ),
    ).isFalse();
    check(
      debugShouldRetirePinnedTurnForLifecycleForTesting(
        pinActive: true,
        assistantPhase: ChatTurnPhase.completed,
      ),
    ).isTrue();
    check(
      debugShouldRetirePinnedTurnForLifecycleForTesting(
        pinActive: true,
        assistantPhase: ChatTurnPhase.failed,
      ),
    ).isTrue();
    check(
      debugShouldRetirePinnedTurnForLifecycleForTesting(
        pinActive: true,
        assistantPhase: null,
      ),
    ).isTrue();
    check(
      debugShouldRetirePinnedTurnForLifecycleForTesting(
        pinActive: false,
        assistantPhase: ChatTurnPhase.completed,
      ),
    ).isFalse();
  });

  test('a user interaction fences both deferred pin-release continuations', () {
    check(
      debugShouldContinuePinReleaseForTesting(
        pinActive: false,
        isUserInteracting: false,
        releaseGeneration: 7,
        currentGeneration: 7,
      ),
    ).isTrue();
    check(
      debugShouldContinuePinReleaseForTesting(
        pinActive: false,
        isUserInteracting: true,
        releaseGeneration: 7,
        currentGeneration: 7,
      ),
    ).isFalse();
    check(
      debugShouldContinuePinReleaseForTesting(
        pinActive: true,
        isUserInteracting: false,
        releaseGeneration: 7,
        currentGeneration: 7,
      ),
    ).isFalse();
    check(
      debugShouldContinuePinReleaseForTesting(
        pinActive: false,
        isUserInteracting: false,
        releaseGeneration: 7,
        currentGeneration: 8,
      ),
    ).isFalse();
  });

  test('unmounted pinned latest never collapses to the physical footer', () {
    check(
      debugResolveLatestPresentationDistanceForTesting(
        pinnedTurnActive: true,
        userDetached: true,
        pinnedDistance: null,
        physicalLatestDistance: 0,
      ),
    ).equals(double.infinity);
    check(
      debugResolveLatestPresentationDistanceForTesting(
        pinnedTurnActive: true,
        userDetached: true,
        pinnedDistance: 96,
        physicalLatestDistance: 0,
      ),
    ).equals(96);
    check(
      debugResolveLatestPresentationDistanceForTesting(
        pinnedTurnActive: false,
        userDetached: true,
        pinnedDistance: null,
        physicalLatestDistance: 0,
      ),
    ).equals(0);
  });

  test('a real drag exposes latest for a scrollable pinned turn', () {
    check(
      debugShouldExposePinnedLatestOnDragForTesting(
        pinnedTurnActive: true,
        hasScrollableContent: true,
      ),
    ).isTrue();
    check(
      debugShouldExposePinnedLatestOnDragForTesting(
        pinnedTurnActive: true,
        hasScrollableContent: false,
      ),
    ).isFalse();
    check(
      debugShouldExposePinnedLatestOnDragForTesting(
        pinnedTurnActive: false,
        hasScrollableContent: true,
      ),
    ).isFalse();
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
      check(identical(container.read(activeConversationProvider), native))
          .isTrue();
      check(
        isNativeHermesConversation(container.read(activeConversationProvider)),
      ).isTrue();

      final direct = _refreshConversation(rawId, 'Temporary direct').copyWith(
        metadata: const <String, dynamic>{'backend': kDirectChatBackend},
      );
      container.read(activeConversationProvider.notifier).set(direct);

      await refreshActiveOpenWebUiConversation(container);

      check(api.fetches).equals(0);
      check(identical(container.read(activeConversationProvider), direct))
          .isTrue();
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

    check(identical(container.read(activeConversationProvider), replacement))
        .isTrue();
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

    check(identical(container.read(activeConversationProvider), original))
        .isTrue();
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
    check(identical(container.read(activeConversationProvider), original))
        .isTrue();
  });
}

class _LifecycleProbe extends StatefulWidget {
  const _LifecycleProbe({
    super.key,
    required this.onMount,
    required this.onDispose,
  });

  final VoidCallback onMount;
  final VoidCallback onDispose;

  @override
  State<_LifecycleProbe> createState() => _LifecycleProbeState();
}

class _LifecycleProbeState extends State<_LifecycleProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
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
