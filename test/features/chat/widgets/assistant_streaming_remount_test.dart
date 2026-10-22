import 'dart:convert';

import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/chat/widgets/chat_timeline_viewport.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _bodyFadeKey = ValueKey('assistant-streaming-content-fade');
const _assistantId = 'audit-streaming-assistant';
const _alreadyRead =
    'Already visible streaming content. The same message is still running.';

class _TestTextToSpeechController extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

class _LifetimeCounts {
  int mounts = 0;
  int disposals = 0;
}

class _LifetimeProbe extends StatefulWidget {
  const _LifetimeProbe({required this.counts, required this.child});

  final _LifetimeCounts counts;
  final Widget child;

  @override
  State<_LifetimeProbe> createState() => _LifetimeProbeState();
}

class _LifetimeProbeState extends State<_LifetimeProbe> {
  @override
  void initState() {
    super.initState();
    widget.counts.mounts += 1;
  }

  @override
  void dispose() {
    widget.counts.disposals += 1;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

ChatMessage _message() => ChatMessage(
  id: _assistantId,
  role: 'assistant',
  content: _alreadyRead,
  timestamp: DateTime(2026, 10, 17),
  model: 'audit-sample-model',
  isStreaming: true,
);

Widget _assistant(ChatMessage message) => AssistantMessageWidget(
  key: const ValueKey(_assistantId),
  message: message,
  isStreaming: true,
  animateOnMount: false,
  showFollowUps: false,
  showModelHeader: false,
  suppressStreamingHaptics: true,
  onDelete: () {},
);

Widget _host({required Widget child, bool reduceMotion = false}) {
  return ProviderScope(
    overrides: [
      appSettingsProvider.overrideWithValue(
        const AppSettings(disableHapticsWhileStreaming: true),
      ),
      streamingHapticsEnabledProvider.overrideWithValue(false),
      textToSpeechControllerProvider.overrideWith(
        _TestTextToSpeechController.new,
      ),
      hermesMobileLayoutProvider.overrideWithValue(true),
    ],
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, navigator) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduceMotion,
          textScaler: TextScaler.noScaling,
        ),
        child: navigator!,
      ),
      home: Scaffold(body: SizedBox.expand(child: child)),
    ),
  );
}

FadeTransition _bodyFade(WidgetTester tester) =>
    tester.widget<FadeTransition>(find.byKey(_bodyFadeKey));

Map<String, Object?> _sample(
  WidgetTester tester,
  String stage,
  _LifetimeCounts counts,
) {
  final finder = find.byType(AssistantMessageWidget);
  final mounted = finder.evaluate().isNotEmpty;
  final values = <String, Object?>{
    'stage': stage,
    'mounts': counts.mounts,
    'disposals': counts.disposals,
    'mounted': mounted,
    if (mounted) ...{
      'stateIdentity': identityHashCode(tester.state(finder)),
      'bodyOpacity': _bodyFade(tester).opacity.value,
      'characters': tester
          .widget<AssistantMessageWidget>(finder)
          .message
          .content
          ?.length,
      'assistantTop': tester.getRect(finder).top,
      'assistantBottom': tester.getRect(finder).bottom,
    },
  };
  // ignore: avoid_print
  print('STREAM_REMOUNT_PROBE ${jsonEncode(values)}');
  return values;
}

void _phoneViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 800);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

void main() {
  testWidgets(
    'actual timeline eviction preserves already-visible stream opacity',
    (tester) async {
      _phoneViewport(tester);
      final controller = ChatTimelineViewportController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      });
      final message = _message();
      final counts = _LifetimeCounts();
      final ids = [
        ...List<String>.generate(80, (index) => 'history-$index'),
        _assistantId,
      ];

      await tester.pumpWidget(
        _host(
          child: ChatTimelineViewport(
            controller: controller,
            ownerGeneration: 1,
            messageIds: ids,
            rowRebuildKeys: ids,
            rowBuilder: (context, index) => ids[index] == _assistantId
                ? _LifetimeProbe(counts: counts, child: _assistant(message))
                : SizedBox(height: 120, child: Text(ids[index])),
            estimateRowExtent: (index) =>
                ids[index] == _assistantId ? 140 : 120,
            topContentInset: 32,
            bottomPadding: 80,
            horizontalPadding: 16,
            // Matches ChatPage._chatMessageScrollCachePixels, not an artificially
            // tiny cache chosen to force a lifecycle that production avoids.
            cacheExtent: 1200,
            physics: const AlwaysScrollableScrollPhysics(),
            isLoadingOlder: false,
            maintainVisibleAnchor: true,
            followLatest: false,
            pinAutomatic: false,
            alignShortContentToBottom: true,
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
      );
      await tester.pumpAndSettle();
      controller.jumpToLatest();
      await tester.pumpAndSettle();
      expect(find.byType(AssistantMessageWidget), findsOneWidget);
      final initialState = tester.state(find.byType(AssistantMessageWidget));
      final initial = _sample(tester, 'timeline-before-away', counts);
      expect(initial['bodyOpacity'], 1.0);

      // Move the real viewport well outside its cache. This changes the actual
      // scroll offset and lets the lazy sliver decide whether the row survives.
      final scrollView = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      scrollView.controller!.jumpTo(
        scrollView.controller!.position.minScrollExtent,
      );
      await tester.pumpAndSettle();
      _sample(tester, 'timeline-away', counts);
      expect(
        counts.disposals,
        greaterThan(0),
        reason: 'The probe must establish actual lazy-row eviction first.',
      );
      expect(find.byType(AssistantMessageWidget), findsNothing);

      // Do not pumpAndSettle here: that would wait out the suspected 260 ms fade
      // and hide the continuity defect. The content itself has not changed.
      controller.jumpToLatest();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(AssistantMessageWidget), findsOneWidget);
      expect(
        identical(
          tester.state(find.byType(AssistantMessageWidget)),
          initialState,
        ),
        isFalse,
      );
      expect(
        find.textContaining('Already visible', findRichText: true),
        findsOneWidget,
      );
      final returned = _sample(tester, 'timeline-first-return-frame', counts);
      expect(counts.mounts, greaterThan(1));
      expect(tester.takeException(), isNull);
      expect(
        returned['bodyOpacity'],
        1.0,
        reason:
            'Previously visible content should not replay a whole-body arrival '
            'fade after actual timeline eviction and return.',
      );
    },
  );

  testWidgets(
    'artificial State remount control preserves already-visible opacity',
    (tester) async {
      _phoneViewport(tester);
      final message = _message();
      final counts = _LifetimeCounts();
      late StateSetter rebuild;
      var shown = true;
      await tester.pumpWidget(
        _host(
          child: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return shown
                  ? _LifetimeProbe(counts: counts, child: _assistant(message))
                  : const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final initial = _sample(tester, 'artificial-before-remount', counts);
      expect(initial['bodyOpacity'], 1.0);
      rebuild(() => shown = false);
      await tester.pump();
      expect(counts.disposals, 1);
      rebuild(() => shown = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final returned = _sample(
        tester,
        'artificial-first-remount-frame',
        counts,
      );
      expect(counts.mounts, 2);
      expect(tester.takeException(), isNull);
      expect(
        returned['bodyOpacity'],
        1.0,
        reason:
            'Mechanism control only: this forced removal does not establish '
            'that retained production routes recreate the assistant State.',
      );
    },
  );
}
