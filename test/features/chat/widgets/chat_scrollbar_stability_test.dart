import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/chat/widgets/chat_timeline_viewport.dart';
import 'package:conduit/features/chat/widgets/user_message_bubble.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/database/models/chat_transcript_window.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _SilentSpeech extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

void main() {
  for (final paragraphCount in [160, 2400]) {
    testWidgets(
      'rapid flings keep the chat thumb moving with the content ($paragraphCount paragraphs)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        PlatformUiCapabilities.debugPlatformOverride =
            debugDefaultTargetPlatformOverride;
        addTearDown(PlatformUiCapabilities.resetDebugOverrides);
        final controller = ChatTimelineViewportController();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
        });
        final ids = List.generate(400, (index) => 'synthetic-message-$index');
        final messages = List.generate(
          ids.length,
          (index) => ChatMessage(
            id: ids[index],
            role: index.isEven ? 'user' : 'assistant',
            content: index.isEven
                ? 'Show marker group ${index ~/ 2 + 1}.'
                : index % 80 == 61
                ? '# Marker group $index\n\n${List.generate(paragraphCount, (line) => 'Marker ${line + 1}.').join('\n\n')}'
                : 'Place a copper marker beside the folded paper sail.',
            timestamp: DateTime(2026, 10, 1),
            model: index.isEven ? null : 'synthetic-model',
            isStreaming: false,
            metadata: const {'responseDone': true},
          ),
        );
        final providerContainer = ProviderContainer.test(
          overrides: [
            textToSpeechControllerProvider.overrideWith(_SilentSpeech.new),
            streamingHapticsEnabledProvider.overrideWithValue(false),
          ],
        );
        final measuredLongRows = <int, Set<double>>{};
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: providerContainer,
            child: MaterialApp(
              theme: AppTheme.dark(TweakcnThemes.conduit),
              localizationsDelegates: conduitLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: ChatTimelineViewport(
                  controller: controller,
                  ownerGeneration: 1,
                  messageIds: ids,
                  initialAnchor: ChatScrollAnchor(
                    messageId: ids.first,
                    offsetWithinMessage: 0,
                    loadedCount: ids.length,
                  ),
                  rowBuilder: (context, index) => index.isEven
                      ? UserMessageBubble(
                          message: messages[index],
                          isUser: true,
                          onDelete: () {},
                        )
                      : AssistantMessageWidget(
                          message: messages[index],
                          isStreaming: false,
                          animateOnMount: false,
                          showFollowUps: false,
                          suppressStreamingHaptics: true,
                          onDelete: () {},
                        ),
                  estimateRowExtent: (index) => estimateChatRowExtent(
                    text: messages[index].content,
                    viewportWidth: 390,
                    isUser: index.isEven,
                  ),
                  onRowExtentMeasured: (index, extent) {
                    if (index % 80 == 61) {
                      measuredLongRows.putIfAbsent(index, () => {}).add(extent);
                    }
                  },
                  topContentInset: 32,
                  bottomPadding: 80,
                  horizontalPadding: 16,
                  cacheExtent: 600,
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  isLoadingOlder: false,
                  maintainVisibleAnchor: true,
                  followLatest: false,
                  pinAutomatic: false,
                  onPointerDown: () {},
                  onUserDragStart: () {},
                  onUserDragEnd: () {},
                  onMetricsChanged: (_) {},
                  onPinEndSpaceChanged: (_) {},
                  onOldestThresholdReached: () {},
                  onTrailingRefresh: () async {},
                  onNativeScrollToTop: () async {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position;
        final reversals = <String>[];
        var sampleCount = 0;
        const flingCount = 16;
        // Repeat in both directions so measured rows leave the cache window and
        // mount again. The final forward pass exercises the warmed extent cache.
        for (final direction in [-1, 1, -1]) {
          ({double pixels, double thumbTop})? previous;
          for (var fling = 0; fling < flingCount; fling++) {
            await tester.flingFrom(
              const Offset(180, 720),
              Offset(0, direction * 550),
              12000,
            );
            for (var frame = 0; frame < 40; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
              final thumbTop = _paintedThumbTop(tester);
              if (thumbTop == null) continue;
              final pixels = position.pixels;
              if (previous != null &&
                  (pixels - previous.pixels) * direction < -0.1 &&
                  (thumbTop - previous.thumbTop) * direction > 0.5) {
                reversals.add(
                  'pixels ${previous.pixels} → $pixels, '
                  'thumb ${previous.thumbTop} → $thumbTop',
                );
              }
              previous = (pixels: pixels, thumbTop: thumbTop);
              sampleCount++;
            }
          }
          await tester.pumpAndSettle();
        }
        expect(sampleCount, greaterThan(1000));
        expect(measuredLongRows, isNotEmpty);
        // Partial 48/144-block layouts must never replace a full row estimate.
        expect(measuredLongRows.values, everyElement(hasLength(1)));
        expect(
          measuredLongRows.values.expand((extents) => extents),
          everyElement(greaterThan(paragraphCount * 30)),
        );
        expect(reversals, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.android,
      }),
    );
  }
}

// Inspect the framework painter's actual draw calls, including on Android
// where the default non-interactive scrollbar deliberately rejects hit tests.
double? _paintedThumbTop(WidgetTester tester) {
  final paintFinder = find.byWidgetPredicate(
    (widget) =>
        widget is CustomPaint && widget.foregroundPainter is ScrollbarPainter,
  );
  final painter =
      tester.widget<CustomPaint>(paintFinder).foregroundPainter!
          as ScrollbarPainter;
  final canvas = TestRecordingCanvas();
  painter.paint(canvas, tester.getSize(paintFinder));
  // Track and border paint first; the last rectangle is the thumb.
  for (final call in canvas.invocations.reversed) {
    final invocation = call.invocation;
    if (invocation.memberName == #drawRRect) {
      return (invocation.positionalArguments.first as RRect).top;
    }
    if (invocation.memberName == #drawRect) {
      return (invocation.positionalArguments.first as Rect).top;
    }
  }
  return null;
}
