import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/models/chat_transcript_window.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/chat/widgets/chat_timeline_viewport.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestTextToSpeechController extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

const _topContentInset = 32.0;

double _transcriptOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find.byKey(const ValueKey<String>('sliver-transcript-visibility')),
    )
    .opacity;

void _useFixedViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 600);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

void _viewportTest(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    _useFixedViewport(tester);
    await callback(tester);
  });
}

ChatTimelineViewportController _controller(WidgetTester tester) {
  final controller = ChatTimelineViewportController();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  return controller;
}

class _TrackedGesture {
  _TrackedGesture(this._gesture);

  final TestGesture _gesture;
  bool _released = false;

  Future<void> moveBy(Offset offset) => _gesture.moveBy(offset);

  Future<void> up() async {
    await _gesture.up();
    _released = true;
  }

  Future<void> cancel() async {
    if (_released) return;
    await _gesture.cancel();
    _released = true;
  }
}

class _MountedRowProbe extends StatefulWidget {
  const _MountedRowProbe({required this.messageId, required this.onMounted});

  final String messageId;
  final ValueChanged<String> onMounted;

  @override
  State<_MountedRowProbe> createState() => _MountedRowProbeState();
}

class _MountedRowProbeState extends State<_MountedRowProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMounted(widget.messageId);
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 52, child: Text(widget.messageId));
}

Future<_TrackedGesture> _startTrackedGesture(
  WidgetTester tester,
  Offset position,
) async {
  final tracked = _TrackedGesture(await tester.startGesture(position));
  addTearDown(() async {
    await tracked.cancel();
  });
  return tracked;
}

/// Advances bounded zero-duration frames used by initial-position retry tests.
Future<void> _pumpSettleFrames(
  WidgetTester tester, {
  int count = debugChatTimelineInitialPositionMaxAttempts + 2,
}) async {
  for (var frame = 0; frame < count; frame += 1) {
    await tester.pump();
  }
}

void main() {
  test(
    'viewport rejects simultaneous anchor maintenance and latest follow',
    () {
      final controller = ChatTimelineViewportController();
      addTearDown(controller.dispose);

      check(
        () => _viewport(
          controller: controller,
          ids: const <String>[],
          maintainVisibleAnchor: true,
          followLatest: true,
        ),
      ).throws<AssertionError>();
    },
  );

  _viewportTest('older center-sliver pages prepend without moving content', (
    tester,
  ) async {
    final controller = _controller(tester);
    var ids = List<String>.generate(50, (index) => 'message-${index + 50}');
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: ids,
              maintainVisibleAnchor: true,
              followLatest: false,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 420),
      900,
    );
    await tester.pumpAndSettle();
    check(controller.distanceFromLatest).isGreaterThan(0);
    final anchor = controller.captureTopVisibleAnchor(loadedCount: ids.length);
    check(anchor).isNotNull();
    final anchorId = anchor!.messageId;
    final before = controller.rowRect(anchorId)!.top;

    rebuild(() {
      ids = [...List<String>.generate(50, (index) => 'message-$index'), ...ids];
    });
    await tester.pump();
    await tester.pump();

    check(controller.rowRect(anchorId)!.top).isCloseTo(before, 1);
  });

  _viewportTest(
    'enabling free-scroll maintenance captures before same-frame insertion',
    (tester) async {
      final controller = _controller(tester);
      var ids = List<String>.generate(24, (index) => 'message-$index');
      var maintainVisibleAnchor = false;
      final mountCounts = <String, int>{};
      late StateSetter rebuild;

      await tester.pumpWidget(
        _viewportHost(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return _viewport(
                controller: controller,
                ids: ids,
                maintainVisibleAnchor: maintainVisibleAnchor,
                followLatest: false,
                rowBuilder: (context, index) => _MountedRowProbe(
                  messageId: ids[index],
                  onMounted: (id) => mountCounts.update(
                    id,
                    (count) => count + 1,
                    ifAbsent: () => 1,
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      check(await controller.jumpMessageToTop('message-16')).isTrue();
      await tester.pump();
      final before = controller.rowRect('message-16')!.top;

      rebuild(() {
        maintainVisibleAnchor = true;
        ids = [...ids.take(8), 'inserted-status', ...ids.skip(8)];
      });
      await tester.pump();
      await tester.pump();

      check(controller.rowRect('message-16')!.top).isCloseTo(before, 1);
      check(mountCounts['message-16']).equals(1);
    },
  );

  _viewportTest('viewport movement does not alter a free-scroll anchor', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(24, (index) => 'message-$index');
    var viewportTop = 0.0;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Stack(
              children: [
                Positioned(
                  top: viewportTop,
                  left: 0,
                  right: 0,
                  height: 500,
                  child: _viewport(
                    controller: controller,
                    ids: ids,
                    maintainVisibleAnchor: true,
                    followLatest: false,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    check(await controller.jumpMessageToTop('message-16')).isTrue();
    await tester.pump();
    final viewportBefore = tester
        .getTopLeft(find.byType(ChatTimelineViewport))
        .dy;
    final relativeBefore =
        controller.rowRect('message-16')!.top -
        (viewportBefore + _topContentInset);

    rebuild(() => viewportTop = 40);
    await tester.pump();
    await tester.pump();

    final viewportAfter = tester
        .getTopLeft(find.byType(ChatTimelineViewport))
        .dy;
    final relativeAfter =
        controller.rowRect('message-16')!.top -
        (viewportAfter + _topContentInset);
    check(relativeAfter).isCloseTo(relativeBefore, 1);
  });

  _viewportTest('identical viewport metrics notify only once', (tester) async {
    final controller = _controller(tester);
    var callbacks = 0;

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: const ['message'],
          onMetricsChanged: (_) => callbacks += 1,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final settledCallbacks = callbacks;
    check(settledCallbacks).isGreaterThan(0);

    controller.requestLayoutMaintenance();
    await tester.pump();
    await tester.pump();

    check(callbacks).equals(settledCallbacks);
  });

  _viewportTest('oldest threshold fires once per visibility edge', (
    tester,
  ) async {
    final controller = _controller(tester);
    var ids = List<String>.generate(4, (index) => 'message-$index');
    var thresholdCalls = 0;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: ids,
              onOldestThresholdReached: () => thresholdCalls += 1,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(thresholdCalls).equals(1);

    controller.requestLayoutMaintenance();
    controller.requestLayoutMaintenance();
    await tester.pump();
    await tester.pump();
    check(thresholdCalls).equals(1);

    rebuild(() {
      ids = [...List<String>.generate(20, (index) => 'older-$index'), ...ids];
    });
    await tester.pump();
    await tester.pump();
    check(thresholdCalls).equals(1);
    rebuild(() {
      ids = ids.skip(20).toList(growable: false);
    });
    await tester.pumpAndSettle();

    check(thresholdCalls).equals(2);
  });

  _viewportTest('growing live tail leaves a detached marker pixel-stable', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(24, (index) => 'message-$index');
    var tailHeight = 400.0;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: ids,
              maintainVisibleAnchor: true,
              followLatest: false,
              rowHeight: (id) => id == ids.last ? tailHeight : 52,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(await controller.jumpMessageToTop('message-16')).isTrue();
    await tester.pump();
    final before = controller.rowRect('message-16')!.top;
    final viewportTop = tester.getTopLeft(find.byType(ChatTimelineViewport)).dy;
    check(before).isCloseTo(viewportTop + _topContentInset, 1);

    rebuild(() => tailHeight = 900);
    await tester.pump();
    await tester.pump();

    check(controller.rowRect(ids.last)!.height).isCloseTo(900, 1);
    check(controller.rowRect('message-16')!.top).isCloseTo(before, 1);
  });

  _viewportTest('anchor capture prefers the long row intersecting the inset', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(16, (index) => 'message-$index');

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          initialAnchor: const ChatScrollAnchor(
            messageId: 'message-8',
            offsetWithinMessage: -600,
            loadedCount: 16,
          ),
          followLatest: false,
          rowHeight: (id) => id == 'message-8' ? 720 : 52,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final anchor = controller.captureTopVisibleAnchor(loadedCount: ids.length);
    final anchorChecks = check(anchor).isNotNull();
    anchorChecks
        .has((value) => value.messageId, 'messageId')
        .equals('message-8');
    final offsetChecks = anchorChecks.has(
      (value) => value.offsetWithinMessage,
      'offsetWithinMessage',
    );
    offsetChecks
      ..isGreaterThan(-605)
      ..isLessThan(-590);
  });

  _viewportTest(
    'real streaming assistant subscription leaves detached content stable',
    (tester) async {
      final providerContainer = ProviderContainer.test(
        overrides: [
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
          streamingHapticsEnabledProvider.overrideWithValue(false),
        ],
      );
      final controller = _controller(tester);
      final ids = [
        ...List<String>.generate(20, (index) => 'message-$index'),
        'assistant',
      ];
      var assistantMessage = ChatMessage(
        id: 'assistant',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
        model: 'test-model',
        isStreaming: true,
      );
      late StateSetter rebuild;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: providerContainer,
          child: _viewportHost(
            StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return _viewport(
                  controller: controller,
                  ids: ids,
                  maintainVisibleAnchor: true,
                  followLatest: false,
                  rowBuilder: (context, index) {
                    final id = ids[index];
                    if (id != 'assistant') {
                      return const SizedBox(height: 52);
                    }
                    return AssistantMessageWidget(
                      message: assistantMessage,
                      isStreaming:
                          assistantMessage.metadata?['responseDone'] != true,
                      showFollowUps: false,
                      animateOnMount: false,
                      suppressStreamingHaptics: true,
                      onDelete: () {},
                    );
                  },
                );
              },
            ),
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      check(await controller.jumpMessageToTop('message-12')).isTrue();
      await tester.pump();
      final before = controller.rowRect('message-12')!.top;
      final assistantBefore = controller.rowRect('assistant')!.height;

      final streamedContent = List<String>.generate(
        160,
        (index) => 'Streaming line $index with enough text to wrap.',
      ).join('\n\n');
      providerContainer
          .read(streamingContentProvider.notifier)
          .set(streamedContent);
      await tester.pumpAndSettle();

      check(
        controller.rowRect('assistant')!.height,
      ).isGreaterThan(assistantBefore);
      check(controller.rowRect('message-12')!.top).isCloseTo(before, 1);

      rebuild(() {
        assistantMessage = assistantMessage.copyWith(
          content: streamedContent,
          isStreaming: false,
          metadata: const {'responseDone': true},
        );
      });
      await tester.pumpAndSettle();
      check(controller.rowRect('message-12')!.top).isCloseTo(before, 1);
    },
  );

  _viewportTest(
    'expansion and insertion above the visible anchor are corrected',
    (tester) async {
      final controller = _controller(tester);
      var ids = List<String>.generate(30, (index) => 'message-$index');
      var expandedHeight = 52.0;
      late StateSetter rebuild;

      await tester.pumpWidget(
        _viewportHost(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return _viewport(
                controller: controller,
                ids: ids,
                maintainVisibleAnchor: true,
                followLatest: false,
                rowHeight: (id) => id == 'message-8' ? expandedHeight : 52,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      check(await controller.jumpMessageToTop('message-18')).isTrue();
      await tester.pump();
      final before = controller.rowRect('message-18')!.top;

      rebuild(() => expandedHeight = 240);
      await tester.pump();
      await tester.pump();
      check(controller.rowRect('message-18')!.top).isCloseTo(before, 1);

      rebuild(() {
        ids = [...ids.take(12), 'tool-status', ...ids.skip(12)];
      });
      await tester.pump();
      await tester.pump();
      check(controller.rowRect('message-18')!.top).isCloseTo(before, 1);

      rebuild(() {
        ids = ids.where((id) => id != 'message-0').toList(growable: false);
      });
      await tester.pump();
      await tester.pump();
      check(controller.rowRect('message-18')!.top).isCloseTo(before, 1);
    },
  );

  _viewportTest('pin end space contracts without moving the prompt', (
    tester,
  ) async {
    final controller = _controller(tester);
    const ids = ['user', 'tool', 'assistant'];
    var assistantHeight = 80.0;
    var pinEndSpace = -1.0;
    String? pinnedUserMessageId = 'user';
    final reportedPinSpaces = <double>[];
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: ids,
              pinnedUserMessageId: pinnedUserMessageId,
              pinAutomatic: true,
              followLatest: false,
              onPinEndSpaceChanged: (value) {
                pinEndSpace = value;
                reportedPinSpaces.add(value);
              },
              rowHeight: (id) => switch (id) {
                'user' => 64,
                'tool' => 48,
                _ => assistantHeight,
              },
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(pinEndSpace).isGreaterThan(0);
    check(await controller.jumpMessageToTop('user')).isTrue();
    await tester.pump();
    final promptTop = controller.rowRect('user')!.top;
    final originalSpace = pinEndSpace;

    rebuild(() => assistantHeight = 240);
    await tester.pump();
    await tester.pump();

    check(controller.rowRect('user')!.top).isCloseTo(promptTop, 1);
    check(pinEndSpace).isCloseTo(originalSpace - 160, 1);
    check(reportedPinSpaces).every((space) => space.isGreaterOrEqual(0));

    rebuild(() => pinnedUserMessageId = null);
    await tester.pump();
    await tester.pump();
    check(reportedPinSpaces.last).equals(0);
  });

  _viewportTest('missing pin geometry reports one terminal value', (
    tester,
  ) async {
    final controller = _controller(tester);
    final reportedPinSpaces = <double>[];

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: const ['assistant'],
          pinnedUserMessageId: 'missing-user',
          pinAutomatic: true,
          followLatest: false,
          onPinEndSpaceChanged: reportedPinSpaces.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    check(reportedPinSpaces).deepEquals([0]);
    controller.requestLayoutMaintenance();
    await tester.pumpAndSettle();
    check(reportedPinSpaces).deepEquals([0]);
  });

  _viewportTest('populated transcript keeps trailing notice in pin geometry', (
    tester,
  ) async {
    final controller = _controller(tester);
    var noticeHeight = 60.0;
    var pinEndSpace = 0.0;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: const ['user', 'assistant'],
              pinnedUserMessageId: 'user',
              pinAutomatic: true,
              followLatest: false,
              trailingContent: SizedBox(
                key: const ValueKey('server-warning-slot'),
                height: noticeHeight,
              ),
              onPinEndSpaceChanged: (value) => pinEndSpace = value,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(
      find.byKey(const ValueKey('server-warning-slot')).evaluate(),
    ).length.equals(1);
    final originalSpace = pinEndSpace;

    rebuild(() => noticeHeight = 140);
    await tester.pump();
    await tester.pump();

    check(pinEndSpace).isCloseTo(originalSpace - 80, 1);
  });

  _viewportTest('later pin movement is monotonic and has no second settle', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = [
      ...List<String>.generate(18, (index) => 'history-$index'),
      'user',
      'assistant',
    ];

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          pinnedUserMessageId: 'user',
          pinAutomatic: true,
          followLatest: false,
          rowHeight: (id) => id == 'assistant' ? 72 : 52,
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(await controller.jumpMessageToTop('history-8')).isTrue();
    await tester.pump();
    final positions = <double>[controller.rowRect('user')!.top];
    final navigation = controller.animateMessageToTop(
      'user',
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    for (var frame = 0; frame < 6; frame += 1) {
      await tester.pump(const Duration(milliseconds: 40));
      positions.add(controller.rowRect('user')!.top);
    }
    await tester.pumpAndSettle();
    await navigation;

    check(positions.last).isLessThan(positions.first - 1);
    for (var index = 1; index < positions.length; index += 1) {
      check(positions[index]).isLessOrEqual(positions[index - 1] + 0.5);
    }
    final settled = controller.rowRect('user')!.top;
    await tester.pump(const Duration(milliseconds: 250));
    check(controller.rowRect('user')!.top).isCloseTo(settled, 1);
  });

  _viewportTest('deep-history pin staging stays one viewport from latest', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(80, (index) => 'message-$index');

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          initialAnchor: const ChatScrollAnchor(
            messageId: 'message-4',
            offsetWithinMessage: 0,
            loadedCount: 80,
          ),
          followLatest: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    controller.prepositionOneViewportFromLatest();
    await tester.pump();
    await tester.pump();

    final metrics = controller.metrics!;
    check(metrics.distanceFromLatest).isCloseTo(metrics.viewportDimension, 1);
  });

  _viewportTest('saved intra-row pixel anchor restores exactly', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(20, (index) => 'message-$index');

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          initialAnchor: const ChatScrollAnchor(
            messageId: 'message-10',
            offsetWithinMessage: -23,
            loadedCount: 20,
          ),
          followLatest: false,
          rowHeight: (_) => 96,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final viewportTop = tester.getTopLeft(find.byType(ChatTimelineViewport)).dy;
    check(
      controller.rowRect('message-10')!.top - (viewportTop + _topContentInset),
    ).isCloseTo(-23, 1);
  });

  _viewportTest(
    'saved anchor restores after its empty fallback becomes visible',
    (tester) async {
      final controller = _controller(tester);
      var ids = <String>[];
      late StateSetter rebuild;

      await tester.pumpWidget(
        _viewportHost(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return _viewport(
                controller: controller,
                ids: ids,
                initialAnchor: const ChatScrollAnchor(
                  messageId: 'message-10',
                  offsetWithinMessage: -18,
                  loadedCount: 20,
                ),
                followLatest: false,
                rowHeight: (_) => 96,
              );
            },
          ),
        ),
      );
      await tester.pump();
      check(_transcriptOpacity(tester)).equals(0);

      await _pumpSettleFrames(tester);
      check(_transcriptOpacity(tester)).equals(1);

      rebuild(() {
        ids = List<String>.generate(20, (index) => 'message-$index');
      });
      await tester.pumpAndSettle();

      final viewportTop = tester
          .getTopLeft(find.byType(ChatTimelineViewport))
          .dy;
      check(
        controller.rowRect('message-10')!.top -
            (viewportTop + _topContentInset),
      ).isCloseTo(-18, 1);
      check(_transcriptOpacity(tester)).equals(1);
    },
  );

  _viewportTest(
    'saved anchor eventually reveals a permanently empty transcript',
    (tester) async {
      final controller = _controller(tester);

      await tester.pumpWidget(
        _viewportHost(
          _viewport(
            controller: controller,
            ids: const [],
            initialAnchor: const ChatScrollAnchor(
              messageId: 'missing',
              offsetWithinMessage: 0,
              loadedCount: 50,
            ),
            followLatest: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      check(_transcriptOpacity(tester)).equals(1);
    },
  );

  _viewportTest(
    'initially empty transcript settles at latest after late load',
    (tester) async {
      final controller = _controller(tester);
      var ids = <String>[];
      late StateSetter rebuild;

      await tester.pumpWidget(
        _viewportHost(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return _viewport(controller: controller, ids: ids);
            },
          ),
        ),
      );
      await _pumpSettleFrames(tester);

      rebuild(() {
        ids = List<String>.generate(30, (index) => 'message-$index');
      });
      await tester.pumpAndSettle();

      check(controller.distanceFromLatest).isCloseTo(0, 1);
    },
  );

  _viewportTest('center-row replacement preserves the visible pixel anchor', (
    tester,
  ) async {
    final controller = _controller(tester);
    var ids = List<String>.generate(20, (index) => 'message-$index');
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: ids,
              initialAnchor: const ChatScrollAnchor(
                messageId: 'message-10',
                offsetWithinMessage: 0,
                loadedCount: 20,
              ),
              followLatest: false,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = controller.rowRect('message-11')!.top;

    rebuild(() {
      ids = ids.where((id) => id != 'message-10').toList(growable: false);
    });
    await tester.pump();
    await tester.pump();

    check(controller.visibleMessageIds).contains('message-11');
    check(controller.rowRect('message-11')!.top).isCloseTo(before, 1);
  });

  _viewportTest('message navigation seeks rows outside the render cache', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(120, (index) => 'message-$index');

    await tester.pumpWidget(
      _viewportHost(
        _viewport(controller: controller, ids: ids, followLatest: false),
      ),
    );
    await tester.pumpAndSettle();
    check(controller.rowRect('message-2')).isNull();

    final animated = controller.animateMessageToTop(
      'message-2',
      duration: const Duration(milliseconds: 1),
      curve: Curves.linear,
    );
    await tester.pumpAndSettle();
    check(await animated).isTrue();
    final viewportTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
    check(
      controller.rowRect('message-2')!.top,
    ).isCloseTo(viewportTop + _topContentInset, 1);

    controller.jumpToLatest();
    await tester.pumpAndSettle();
    check(controller.rowRect('message-60')).isNull();
    final jumped = controller.jumpMessageToTop('message-60');
    await tester.pumpAndSettle();
    check(await jumped).isTrue();
    check(
      controller.rowRect('message-60')!.top,
    ).isCloseTo(viewportTop + _topContentInset, 1);
  });

  _viewportTest('failed off-cache navigation restores its entry offset', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(2000, (index) => 'message-$index');

    await tester.pumpWidget(
      _viewportHost(_viewport(controller: controller, ids: ids)),
    );
    await tester.pumpAndSettle();
    final entryOffset = controller.metrics!.pixels;

    final navigation = controller.jumpMessageToTop('message-0');
    await tester.pumpAndSettle();

    check(await navigation).isFalse();
    check(controller.metrics!.pixels).isCloseTo(entryOffset, 1);
  });

  _viewportTest('pointer-down restores an interrupted off-cache seek', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(2000, (index) => 'message-$index');

    await tester.pumpWidget(
      _viewportHost(_viewport(controller: controller, ids: ids)),
    );
    await tester.pumpAndSettle();
    final entryOffset = controller.metrics!.pixels;

    final navigation = controller.jumpMessageToTop('message-0');
    await tester.pump();
    check(controller.isProgrammaticNavigationActive).isTrue();

    final gesture = await _startTrackedGesture(
      tester,
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await tester.pump();

    check(controller.isProgrammaticNavigationActive).isFalse();
    check(controller.metrics!.pixels).isCloseTo(entryOffset, 1);
    await gesture.cancel();
    await tester.pumpAndSettle();
    check(await navigation).isFalse();
  });

  _viewportTest('explicit latest owns one animation and remains attached', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(30, (index) => 'message-$index');

    await tester.pumpWidget(
      _viewportHost(
        _viewport(controller: controller, ids: ids, followLatest: false),
      ),
    );
    await tester.pumpAndSettle();
    check(await controller.jumpMessageToTop('message-12')).isTrue();
    await tester.pump();
    final startingDistance = controller.distanceFromLatest;
    check(startingDistance).isGreaterThan(48);

    final navigation = controller.animateToLatest(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    var navigationDone = false;
    unawaited(navigation.then((_) => navigationDone = true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    check(controller.isProgrammaticNavigationActive).isTrue();
    final firstDistance = controller.distanceFromLatest;
    check(firstDistance).isLessThan(startingDistance);
    final supersedingNavigation = controller.animateToLatest(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    var supersedingNavigationDone = false;
    unawaited(
      supersedingNavigation.then((_) => supersedingNavigationDone = true),
    );
    await tester.pump();
    final supersedingDistances = <double>[controller.distanceFromLatest];
    for (var frame = 0; frame < 6; frame += 1) {
      await tester.pump(const Duration(milliseconds: 40));
      supersedingDistances.add(controller.distanceFromLatest);
    }
    for (var index = 1; index < supersedingDistances.length; index += 1) {
      check(
        supersedingDistances[index],
      ).isLessOrEqual(supersedingDistances[index - 1] + 0.5);
    }
    check(supersedingDistances.first).isLessOrEqual(firstDistance);
    await tester.pumpAndSettle();
    await tester.pump();

    check(navigationDone).isTrue();
    check(supersedingNavigationDone).isTrue();
    check(controller.distanceFromLatest).isCloseTo(0, 1);
    check(controller.isProgrammaticNavigationActive).isFalse();
  });

  _viewportTest('a real drag cancels programmatic navigation', (tester) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(30, (index) => 'message-$index');
    var pointerDowns = 0;
    var dragStarts = 0;
    var dragEnds = 0;

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          followLatest: false,
          onPointerDown: () => pointerDowns += 1,
          onUserDragStart: () => dragStarts += 1,
          onUserDragEnd: () => dragEnds += 1,
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(await controller.jumpMessageToTop('message-12')).isTrue();
    await tester.pump();

    final navigation = controller.animateToLatest(
      duration: const Duration(seconds: 1),
      curve: Curves.linear,
    );
    var navigationDone = false;
    unawaited(navigation.then((_) => navigationDone = true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    check(controller.isProgrammaticNavigationActive).isTrue();

    final gesture = await _startTrackedGesture(
      tester,
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await gesture.moveBy(const Offset(0, -32));
    await tester.pump();
    check(controller.isProgrammaticNavigationActive).isFalse();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    check(navigationDone).isTrue();
    check(pointerDowns).equals(1);
    check(dragStarts).equals(1);
    check(dragEnds).equals(1);
  });

  _viewportTest('initial settlement is excluded from paint and interaction', (
    tester,
  ) async {
    final controller = _controller(tester);
    var hidden = true;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: const ['user', 'assistant'],
              hideUntilSettled: hidden,
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    check(_transcriptOpacity(tester)).equals(0);
    final interaction = find.byKey(
      const ValueKey<String>('sliver-transcript-interaction'),
    );
    check(tester.widget<IgnorePointer>(interaction).ignoring).isTrue();

    rebuild(() => hidden = false);
    await tester.pump();
    check(_transcriptOpacity(tester)).equals(1);
    check(tester.widget<IgnorePointer>(interaction).ignoring).isFalse();
  });

  _viewportTest('composer padding alone is not real transcript overflow', (
    tester,
  ) async {
    final controller = _controller(tester);

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: const ['message'],
          // 32 (top inset) + 540 fits in 600; the 80px composer padding is
          // the only reason the scrollable exceeds the viewport.
          rowHeight: (_) => 540,
        ),
      ),
    );
    await tester.pumpAndSettle();

    check(controller.hasRealContentOverflow).isFalse();
  });

  _viewportTest('content taller than the viewport is real overflow', (
    tester,
  ) async {
    final controller = _controller(tester);

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: const ['message'],
          rowHeight: (_) => 900,
        ),
      ),
    );
    await tester.pumpAndSettle();

    check(controller.hasRealContentOverflow).isTrue();
  });

  _viewportTest(
    'trailing refresh needs a past-threshold drag and fires once per drag',
    (tester) async {
      final controller = _controller(tester);
      var refreshes = 0;

      await tester.pumpWidget(
        _viewportHost(
          _viewport(
            controller: controller,
            ids: const ['message'],
            onTrailingRefresh: () async {
              refreshes += 1;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Leave enough margin that touch slop or pixel rounding cannot turn this
      // into an accidental threshold-boundary test.
      const belowThreshold = debugChatTimelineTrailingRefreshThreshold - 12;
      const aboveThreshold = debugChatTimelineTrailingRefreshThreshold + 24;
      await tester.drag(
        find.byType(CustomScrollView),
        const Offset(0, -belowThreshold),
        touchSlopY: 0,
      );
      await tester.pumpAndSettle();
      check(refreshes).equals(0);

      await tester.drag(
        find.byType(CustomScrollView),
        const Offset(0, -aboveThreshold),
        touchSlopY: 0,
      );
      await tester.pumpAndSettle();
      check(refreshes).equals(1);

      await tester.drag(
        find.byType(CustomScrollView),
        const Offset(0, -aboveThreshold),
        touchSlopY: 0,
      );
      await tester.pumpAndSettle();
      check(refreshes).equals(2);
    },
  );

  _viewportTest('trailing refresh subtracts reversed overscroll', (
    tester,
  ) async {
    final controller = _controller(tester);
    var refreshes = 0;

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: const ['message'],
          onTrailingRefresh: () async {
            refreshes += 1;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await _startTrackedGesture(
      tester,
      tester.getCenter(find.byType(CustomScrollView)),
    );
    const belowThreshold = debugChatTimelineTrailingRefreshThreshold - 12;
    const reversingDrag = debugChatTimelineTrailingRefreshThreshold + 8;
    // The reversal overshoots past zero, so accumulated progress must clamp at
    // zero; the final remaining drag then crosses the threshold with margin.
    const remainingThresholdDrag =
        debugChatTimelineTrailingRefreshThreshold - belowThreshold + 8;
    await gesture.moveBy(const Offset(0, -belowThreshold));
    await tester.pump();
    await gesture.moveBy(const Offset(0, reversingDrag));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -belowThreshold));
    await tester.pump();
    check(refreshes).equals(0);

    await gesture.moveBy(const Offset(0, -remainingThresholdDrag));
    await tester.pump();
    check(refreshes).equals(1);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  _viewportTest('older loading clears stale trailing overscroll', (
    tester,
  ) async {
    final controller = _controller(tester);
    var loadingOlder = false;
    var refreshes = 0;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: const ['message'],
              isLoadingOlder: loadingOlder,
              onTrailingRefresh: () async {
                refreshes += 1;
              },
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await _startTrackedGesture(
      tester,
      tester.getCenter(find.byType(CustomScrollView)),
    );
    const partialDrag = debugChatTimelineTrailingRefreshThreshold - 12;
    await gesture.moveBy(const Offset(0, -partialDrag));
    await tester.pump();
    check(refreshes).equals(0);

    rebuild(() => loadingOlder = true);
    await tester.pump();
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    check(refreshes).equals(0);

    rebuild(() => loadingOlder = false);
    await tester.pump();
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    check(refreshes).equals(0);

    await gesture.moveBy(
      const Offset(0, -(debugChatTimelineTrailingRefreshThreshold - 20 + 4)),
    );
    await tester.pump();
    check(refreshes).equals(1);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  _viewportTest('refresh completion cannot re-arm the active drag', (
    tester,
  ) async {
    final controller = _controller(tester);
    var refreshes = 0;
    var completion = Completer<void>();

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: const ['message'],
          onTrailingRefresh: () {
            refreshes += 1;
            return completion.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await _startTrackedGesture(
      tester,
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await gesture.moveBy(
      const Offset(0, -(debugChatTimelineTrailingRefreshThreshold + 88)),
    );
    await tester.pump();
    check(refreshes).equals(1);

    completion.complete();
    await tester.pump();
    await gesture.moveBy(
      const Offset(0, -(debugChatTimelineTrailingRefreshThreshold + 28)),
    );
    await tester.pump();
    check(refreshes).equals(1);
    await gesture.up();
    await tester.pumpAndSettle();

    completion = Completer<void>();
    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, -(debugChatTimelineTrailingRefreshThreshold + 24)),
      touchSlopY: 0,
    );
    await tester.pump();
    completion.complete();
    check(refreshes).equals(2);
    await tester.pumpAndSettle();
  });

  _viewportTest('synchronous refresh failures clear and can retry', (
    tester,
  ) async {
    final controller = _controller(tester);
    var refreshes = 0;

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: const ['message'],
          onTrailingRefresh: () {
            refreshes += 1;
            throw StateError('synchronous refresh failure');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (
      var expectedRefreshes = 1;
      expectedRefreshes <= 2;
      expectedRefreshes++
    ) {
      await tester.drag(
        find.byType(CustomScrollView),
        const Offset(0, -(debugChatTimelineTrailingRefreshThreshold + 24)),
        touchSlopY: 0,
      );
      await tester.pumpAndSettle();
      check(refreshes).equals(expectedRefreshes);
      check(tester.takeException()).isNull();
      check(find.byType(CircularProgressIndicator).evaluate()).isEmpty();
    }
  });

  _viewportTest('owner change removes an active trailing refresh indicator', (
    tester,
  ) async {
    final controller = _controller(tester);
    final completion = Completer<void>();
    var ownerGeneration = 1;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: const ['message'],
              ownerGeneration: ownerGeneration,
              onTrailingRefresh: () => completion.future,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, -(debugChatTimelineTrailingRefreshThreshold + 24)),
      touchSlopY: 0,
    );
    await tester.pump();
    check(find.byType(CircularProgressIndicator).evaluate()).length.equals(1);

    rebuild(() => ownerGeneration = 2);
    await tester.pump();
    check(find.byType(CircularProgressIndicator).evaluate()).isEmpty();

    completion.complete();
    await tester.pumpAndSettle();
    check(find.byType(CircularProgressIndicator).evaluate()).isEmpty();
  });

  _viewportTest('owner generation change cancels stale navigation', (
    tester,
  ) async {
    final controller = _controller(tester);
    var ownerGeneration = 1;
    var ids = List<String>.generate(30, (index) => 'old-$index');
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: ids,
              ownerGeneration: ownerGeneration,
              followLatest: false,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(await controller.jumpMessageToTop('old-12')).isTrue();
    await tester.pump();

    var staleNavigationCompleted = false;
    unawaited(
      controller
          .animateToLatest(
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutCubic,
          )
          .then((_) => staleNavigationCompleted = true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    check(controller.isProgrammaticNavigationActive).isTrue();

    rebuild(() {
      ownerGeneration = 2;
      ids = List<String>.generate(16, (index) => 'replacement-$index');
    });
    await tester.pump();
    await tester.pumpAndSettle();

    check(staleNavigationCompleted).isTrue();
    check(controller.isProgrammaticNavigationActive).isFalse();
    check(controller.distanceFromLatest).isCloseTo(0, 1);
    check(
      controller.visibleMessageIds.where((id) => id.startsWith('old-')),
    ).isEmpty();
    check(controller.visibleMessageIds).isNotEmpty();
  });

  _viewportTest('controller dispose permanently fences later commands', (
    tester,
  ) async {
    final controller = ChatTimelineViewportController();
    var disposed = false;
    void disposeOnce() {
      if (disposed) return;
      disposed = true;
      controller.dispose();
    }

    addTearDown(disposeOnce);

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: List<String>.generate(20, (index) => 'message-$index'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(controller.isAttached).isTrue();

    disposeOnce();
    check(controller.isAttached).isFalse();
    check(await controller.jumpMessageToTop('message-10')).isFalse();

    await tester.pump();
    check(controller.isAttached).isFalse();
    check(await controller.jumpMessageToTop('message-10')).isFalse();
  });

  _viewportTest('duplicate message IDs collapse to their first source index', (
    tester,
  ) async {
    final controller = _controller(tester);
    const ids = ['first', 'duplicate', 'duplicate', 'last'];

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          rowBuilder: (context, index) =>
              SizedBox(height: 52, child: Text('source-$index')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    check(find.text('source-0').evaluate().length).equals(1);
    check(find.text('source-1').evaluate().length).equals(1);
    // The later duplicate is intentionally omitted from the rendered timeline.
    check(find.text('source-2').evaluate()).isEmpty();
    check(find.text('source-3').evaluate().length).equals(1);
    check(
      controller.visibleMessageIds,
    ).deepEquals(['first', 'duplicate', 'last']);
  });
}

Widget _viewportHost(
  Widget child, {
  ThemeData? theme,
  Iterable<LocalizationsDelegate<dynamic>>? localizationsDelegates,
  Iterable<Locale> supportedLocales = const <Locale>[Locale('en', 'US')],
}) {
  return MaterialApp(
    theme: theme,
    localizationsDelegates: localizationsDelegates,
    supportedLocales: supportedLocales,
    home: Scaffold(body: SizedBox.expand(child: child)),
  );
}

Widget _viewport({
  required ChatTimelineViewportController controller,
  required List<String> ids,
  int ownerGeneration = 1,
  ChatScrollAnchor? initialAnchor,
  String? pinnedUserMessageId,
  bool pinAutomatic = false,
  bool isLoadingOlder = false,
  bool maintainVisibleAnchor = false,
  // Defaults to the inverse so free-scroll anchor maintenance and automatic
  // latest ownership remain mutually exclusive in tests, as in ChatPage.
  bool? followLatest,
  Widget? trailingContent,
  bool hideUntilSettled = false,
  double Function(String id)? rowHeight,
  ChatTimelineRowBuilder? rowBuilder,
  ValueChanged<ChatTimelineViewportMetrics>? onMetricsChanged,
  ValueChanged<double>? onPinEndSpaceChanged,
  VoidCallback? onOldestThresholdReached,
  Future<void> Function()? onTrailingRefresh,
  VoidCallback? onPointerDown,
  VoidCallback? onUserDragStart,
  VoidCallback? onUserDragEnd,
}) {
  return ChatTimelineViewport(
    controller: controller,
    ownerGeneration: ownerGeneration,
    messageIds: ids,
    initialAnchor: initialAnchor,
    pinnedUserMessageId: pinnedUserMessageId,
    trailingContent: trailingContent,
    topContentInset: _topContentInset,
    bottomPadding: 80,
    horizontalPadding: 16,
    cacheExtent: 600,
    physics: const AlwaysScrollableScrollPhysics(),
    isLoadingOlder: isLoadingOlder,
    maintainVisibleAnchor: maintainVisibleAnchor,
    followLatest: followLatest ?? !maintainVisibleAnchor,
    pinAutomatic: pinAutomatic,
    hideUntilSettled: hideUntilSettled,
    onPointerDown: onPointerDown ?? () {},
    onUserDragStart: onUserDragStart ?? () {},
    onUserDragEnd: onUserDragEnd ?? () {},
    onMetricsChanged: onMetricsChanged ?? (_) {},
    onPinEndSpaceChanged: onPinEndSpaceChanged ?? (_) {},
    onOldestThresholdReached: onOldestThresholdReached ?? () {},
    onTrailingRefresh: onTrailingRefresh ?? () async {},
    rowBuilder:
        rowBuilder ??
        (context, index) {
          final id = ids[index];
          return SizedBox(
            height: rowHeight?.call(id) ?? 52,
            child: Text(id, key: ValueKey<String>('label-$id')),
          );
        },
  );
}
