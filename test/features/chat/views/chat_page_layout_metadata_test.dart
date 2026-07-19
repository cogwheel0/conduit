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
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

void main() {
  testWidgets(
    'managed timeline keeps its trailing edge pinned during live growth',
    (tester) async {
      final scrollController = ScrollController();
      final listController = ListController()
        ..stickTarget = const StickTarget.bottom();
      final liveHeight = ValueNotifier<double>(180);
      final composerSpacerHeight = ValueNotifier<double>(60);
      var metricsNotifications = 0;
      addTearDown(scrollController.dispose);
      addTearDown(listController.dispose);
      addTearDown(liveHeight.dispose);
      addTearDown(composerSpacerHeight.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 320,
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: (_) {
                  metricsNotifications += 1;
                  return false;
                },
                child: CustomScrollView(
                  controller: scrollController,
                  slivers: [
                    const SliverToBoxAdapter(child: SizedBox(height: 420)),
                    SuperSliverList(
                      listController: listController,
                      delegate: SliverChildListDelegate.fixed([
                        ValueListenableBuilder<double>(
                          valueListenable: liveHeight,
                          builder: (context, height, _) => SizedBox(
                            key: const ValueKey('live-turn'),
                            height: height,
                          ),
                        ),
                        ValueListenableBuilder<double>(
                          valueListenable: composerSpacerHeight,
                          builder: (context, height, _) => SizedBox(
                            key: const ValueKey('composer-spacer'),
                            height: height,
                          ),
                        ),
                      ]),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
      await tester.pump();
      final offsetBeforeGrowth = scrollController.offset;
      final metricsBeforeGrowth = metricsNotifications;

      liveHeight.value += 72;
      await tester.pump();

      check(scrollController.offset).isCloseTo(offsetBeforeGrowth + 72, 0.01);
      check(
        scrollController.offset,
      ).isCloseTo(scrollController.position.maxScrollExtent, 0.01);
      check(scrollController.position.isScrollingNotifier.value).isFalse();
      check(metricsNotifications).isGreaterThan(metricsBeforeGrowth);

      final offsetBeforeComposerGrowth = scrollController.offset;
      composerSpacerHeight.value += 36;
      await tester.pump();

      check(
        scrollController.offset,
      ).isCloseTo(offsetBeforeComposerGrowth + 36, 0.01);
      check(
        scrollController.offset,
      ).isCloseTo(scrollController.position.maxScrollExtent, 0.01);
      check(scrollController.position.isScrollingNotifier.value).isFalse();

      listController.stickTarget = null;
      scrollController.jumpTo(scrollController.offset - 100);
      await tester.pump();
      final detachedOffset = scrollController.offset;

      liveHeight.value += 40;
      await tester.pump();

      check(scrollController.offset).isCloseTo(detachedOffset, 0.01);
      check(
        scrollController.position.maxScrollExtent - scrollController.offset,
      ).isGreaterThan(100);

      final maxExtentBeforeDetachedComposerGrowth =
          scrollController.position.maxScrollExtent;
      composerSpacerHeight.value += 24;
      await tester.pump();

      check(scrollController.offset).isCloseTo(detachedOffset, 0.01);
      check(
        scrollController.position.maxScrollExtent,
      ).isCloseTo(maxExtentBeforeDetachedComposerGrowth + 24, 0.01);
    },
  );

  testWidgets('bottom scroll settles against response and composer growth', (
    tester,
  ) async {
    final scrollController = ScrollController();
    final liveHeight = ValueNotifier<double>(240);
    final composerHeight = ValueNotifier<double>(72);
    final settler = ChatBottomScrollSettler();
    final anchor = ChatBottomAnchorController(
      showThreshold: 300,
      hideThreshold: 150,
    )..detachByUser();
    var settled = false;
    addTearDown(scrollController.dispose);
    addTearDown(liveHeight.dispose);
    addTearDown(composerHeight.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 320,
          child: CustomScrollView(
            controller: scrollController,
            slivers: [
              const SliverToBoxAdapter(child: SizedBox(height: 640)),
              SliverToBoxAdapter(
                child: ValueListenableBuilder<double>(
                  valueListenable: liveHeight,
                  builder: (context, height, _) => SizedBox(height: height),
                ),
              ),
              SliverToBoxAdapter(
                child: ValueListenableBuilder<double>(
                  valueListenable: composerHeight,
                  builder: (context, height, _) => SizedBox(height: height),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final initialBottom = scrollController.position.maxScrollExtent;
    check(anchor.isAnchoredToBottom).isFalse();

    final settleFuture = settler.animateToLatestBottom(
      initialBottom: initialBottom,
      animateTo: (target) => scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.linear,
      ),
      canSettle: () => true,
      rearmBottomAnchor: anchor.requestBottomAnchor,
      latestBottom: () => scrollController.position.maxScrollExtent,
      currentOffset: () => scrollController.offset,
      jumpTo: scrollController.jumpTo,
      onSettled: () => settled = true,
      correctionEpsilon: 1,
    );
    await tester.pump(const Duration(milliseconds: 100));

    liveHeight.value += 180;
    composerHeight.value += 48;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();
    await settleFuture;

    check(settled).isTrue();
    check(anchor.isAnchoredToBottom).isTrue();
    check(
      scrollController.offset,
    ).isCloseTo(scrollController.position.maxScrollExtent, 0.01);
  });

  testWidgets('user interaction cancels a pending bottom settle', (
    tester,
  ) async {
    final scrollController = ScrollController();
    final settler = ChatBottomScrollSettler();
    var userIsInteracting = false;
    var rearmCount = 0;
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 320,
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification &&
                  notification.dragDetails != null) {
                userIsInteracting = true;
                settler.cancel();
              }
              return false;
            },
            child: CustomScrollView(
              controller: scrollController,
              slivers: const [
                SliverToBoxAdapter(child: SizedBox(height: 1400)),
              ],
            ),
          ),
        ),
      ),
    );

    final settleFuture = settler.animateToLatestBottom(
      initialBottom: scrollController.position.maxScrollExtent,
      animateTo: (target) => scrollController.animateTo(
        target,
        duration: const Duration(seconds: 2),
        curve: Curves.linear,
      ),
      canSettle: () => !userIsInteracting,
      rearmBottomAnchor: () => rearmCount += 1,
      latestBottom: () => scrollController.position.maxScrollExtent,
      currentOffset: () => scrollController.offset,
      jumpTo: scrollController.jumpTo,
      onSettled: () {},
      correctionEpsilon: 1,
    );
    await tester.pump(const Duration(milliseconds: 80));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 120));
    await tester.pump();
    await settleFuture;
    final interruptedOffset = scrollController.offset;
    await tester.pump(const Duration(milliseconds: 300));

    check(userIsInteracting).isTrue();
    check(rearmCount).equals(0);
    check(scrollController.offset).isCloseTo(interruptedOffset, 0.01);
    check(
      scrollController.offset,
    ).isLessThan(scrollController.position.maxScrollExtent);
  });

  testWidgets(
    'managed timeline remaps the trailing spacer extent when a row is appended',
    (tester) async {
      final listController = ListController();
      final itemExtents = ValueNotifier<List<double>>([100, 100, 100, 100, 60]);
      addTearDown(listController.dispose);
      addTearDown(itemExtents.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            height: 120,
            child: ValueListenableBuilder<List<double>>(
              valueListenable: itemExtents,
              builder: (context, extents, _) => CustomScrollView(
                scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                slivers: [
                  SuperSliverList(
                    listController: listController,
                    extentEstimation: (index, _) => extents[index ?? 0],
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => SizedBox(height: extents[index]),
                      childCount: extents.length,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      const previousKeys = ['a', 'b', 'c', 'd', 'spacer'];
      itemExtents.value = [100, 100, 100, 100, 240, 60];
      await tester.pump();

      // The delegate count grew at the tail, but the keyed row was inserted
      // before the composer spacer.
      reconcileManagedTimelineExtentsForTesting(
        controller: listController,
        previousKeys: previousKeys,
        nextKeys: const ['a', 'b', 'c', 'd', 'new-row', 'spacer'],
      );

      check(listController.extentForIndex(4).$1).equals(240);
      check(listController.extentForIndex(5).$1).equals(60);
    },
  );

  testWidgets('managed timeline refreshes an off-screen spacer estimate', (
    tester,
  ) async {
    final listController = ListController();
    final itemExtents = ValueNotifier<List<double>>([100, 100, 100, 100, 60]);
    addTearDown(listController.dispose);
    addTearDown(itemExtents.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 120,
          child: ValueListenableBuilder<List<double>>(
            valueListenable: itemExtents,
            builder: (context, extents, _) => CustomScrollView(
              scrollCacheExtent: const ScrollCacheExtent.pixels(0),
              slivers: [
                SuperSliverList(
                  listController: listController,
                  extentEstimation: (index, _) => extents[index ?? 0],
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => SizedBox(height: extents[index]),
                    childCount: extents.length,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    itemExtents.value = [100, 100, 100, 100, 140];
    await tester.pump();
    refreshManagedTimelineExtentForTesting(
      controller: listController,
      index: 4,
    );

    check(listController.extentForIndex(4).$1).equals(140);
  });

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
    expect(
      controller.shouldKeepAnchoredOnContentSizeChange(wantsPinToTop: false),
      isTrue,
    );
  });

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

      check(
        debugChatListStableLayoutSignatureBuildCountForTesting(cache),
      ).equals(1);

      debugResolveChatListStableLayoutCacheForTesting(
        cache,
        List<ChatMessage>.of(messages),
        models: null,
        directModelRegistry: registry,
      );
      check(
        debugChatListStableLayoutSignatureBuildCountForTesting(cache),
      ).equals(2);
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

  test(
    'pin-to-top anchors the prompt until real content fills the viewport',
    () {
      final positioning = resolveChatPinStickTargetForTesting(
        anchorIndex: 4,
        anchorAlignment: 0.16,
        isAutoFollowing: true,
        isUserInteracting: false,
        isPositionSettled: false,
        anchoredEndSpaceExtent: 0,
      );
      final reservedSpace = resolveChatPinStickTargetForTesting(
        anchorIndex: 4,
        anchorAlignment: 0.16,
        isAutoFollowing: true,
        isUserInteracting: false,
        isPositionSettled: true,
        anchoredEndSpaceExtent: 220,
      );
      final overflowing = resolveChatPinStickTargetForTesting(
        anchorIndex: 4,
        anchorAlignment: 0.16,
        isAutoFollowing: true,
        isUserInteracting: false,
        isPositionSettled: true,
        anchoredEndSpaceExtent: 0,
      );

      expect(positioning?.isBottom, isFalse);
      expect(positioning?.index, 4);
      expect(positioning?.alignment, 0.16);
      expect(reservedSpace?.isBottom, isFalse);
      expect(overflowing?.isBottom, isTrue);
    },
  );

  test('pin-to-top layout corrections stop on the first user gesture', () {
    final target = resolveChatPinStickTargetForTesting(
      anchorIndex: 4,
      anchorAlignment: 0.16,
      isAutoFollowing: false,
      isUserInteracting: true,
      isPositionSettled: true,
      anchoredEndSpaceExtent: 0,
    );

    expect(target, isNull);
  });

  test('manual navigation cancels follow without discarding the anchor', () {
    final state = debugPinStateAfterManualNavigationForTesting();

    expect(state.anchorActive, isTrue);
    expect(state.autoFollowing, isFalse);
    expect(state.userMessageId, 'user-message');
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
