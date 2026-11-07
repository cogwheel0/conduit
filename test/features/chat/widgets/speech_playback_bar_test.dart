import 'dart:async';

import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/speech_playback_bar.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:cupertino_native_better/cupertino_native_better.dart'
    show CNFloatingIsland;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/native_platform_views.dart';

Widget _harness(_Playback playback, {bool nativeIOS26 = false}) =>
    ProviderScope(
      overrides: [textToSpeechControllerProvider.overrideWith(() => playback)],
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // Like the composer's, the column gives the bar an unbounded height.
        home: const Scaffold(
          body: Column(children: [Spacer(), SpeechPlaybackBar()]),
        ),
        builder: (context, child) {
          final scaled = MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          );
          return nativeIOS26
              ? LegacyDesignCompatibility(child: scaled)
              : scaled;
        },
      ),
    );

void _useNativeIOS26() {
  stubNativePlatformViews();
  PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
  PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
  PlatformUiCapabilities.debugNativeIOS26Override = true;
  addTearDown(PlatformUiCapabilities.resetDebugOverrides);
}

/// The island's glass: its size for the current state, at the bottom centre
/// of the island, which is where the native view and the Flutter one draw it.
Rect _glass(WidgetTester tester) {
  final island = find.byType(CNFloatingIsland);
  final config = tester.widget<CNFloatingIsland>(island);
  final size = config.isExpanded
      ? Size(config.expandedWidth!, config.expandedHeight!)
      : Size(config.collapsedWidth!, config.collapsedHeight);
  final box = tester.getRect(island);
  return Rect.fromLTWH(
    box.center.dx - size.width / 2,
    box.bottom - size.height,
    size.width,
    size.height,
  );
}

void _expectOnGlass(WidgetTester tester, Finder control) {
  final glass = _glass(tester).inflate(0.5);
  final rect = tester.getRect(control);
  expect(
    glass.contains(rect.topLeft) && glass.contains(rect.bottomRight),
    isTrue,
    reason: '$control at $rect is off the glass at $glass',
  );
}

bool _islandExpanded(WidgetTester tester) =>
    tester.widget<CNFloatingIsland>(find.byType(CNFloatingIsland)).isExpanded;

/// Presses a control the way its native button would.
void _press(WidgetTester tester, String key) =>
    tester.widget<AdaptiveButton>(find.byKey(ValueKey(key))).onPressed!();

void main() {
  testWidgets('read-aloud shows elapsed time instead of Listen', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(_Playback((_) {})));
    await tester.pumpAndSettle();
    expect(find.text('0:00'), findsOneWidget);
    expect(find.text('Listen'), findsNothing);
  });

  for (final entry in {
    const Duration(seconds: 65): '1:05',
    const Duration(hours: 1, minutes: 2, seconds: 3): '1:02:03',
  }.entries) {
    testWidgets('elapsed timestamp formats ${entry.value}', (tester) async {
      await tester.pumpWidget(_harness(_Playback((_) {}, elapsed: entry.key)));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
    });
  }

  for (final size in [const Size(390, 844), const Size(1024, 768)]) {
    testWidgets('playback controls fit and retain state at 2x text in $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final actions = <String>[];
      await tester.pumpWidget(_harness(_Playback(actions.add)));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.5,
      );
      await tester.tap(find.byKey(const ValueKey('speech-playback-toggle')));
      await tester.pumpAndSettle();
      expect(actions, ['pause']);
      await tester.tap(find.byKey(const ValueKey('speech-playback-toggle')));
      await tester.pumpAndSettle();
      expect(actions, ['pause', 'resume']);
      await tester.tap(find.byKey(const ValueKey('speech-playback-stop')));
      await tester.pumpAndSettle();
      expect(actions, ['pause', 'resume', 'stop']);
      expect(find.byKey(const ValueKey('speech-playback-bar')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('audio duration drives progress after a timed seek', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        _Playback(
          (_) {},
          elapsed: const Duration(seconds: 15),
          duration: const Duration(minutes: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .25,
    );
  });

  testWidgets('15-second skip controls dispatch both directions', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(_harness(_Playback(actions.add)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('speech-playback-backward')));
    await tester.tap(find.byKey(const ValueKey('speech-playback-forward')));
    expect(actions, ['skip:-15', 'skip:15']);
    final back = tester
        .getCenter(find.byKey(const ValueKey('speech-playback-backward')))
        .dx;
    final play = tester
        .getCenter(find.byKey(const ValueKey('speech-playback-toggle')))
        .dx;
    final forward = tester
        .getCenter(find.byKey(const ValueKey('speech-playback-forward')))
        .dx;
    expect(back, lessThan(play));
    expect(play, lessThan(forward));
  });

  testWidgets('an error offers retry without displaying raw engine details', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(_harness(_Playback(actions.add, failed: true)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Synthetic engine details'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('speech-playback-retry')));
    await tester.pumpAndSettle();
    expect(actions, ['retry']);
    expect(
      find.byKey(const ValueKey('speech-playback-toggle')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(390, 844), const Size(1024, 768)]) {
    testWidgets(
      'iOS 26 island expands from a compact pill with every control on its '
      'glass at 2x text in $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        _useNativeIOS26();
        final actions = <String>[];
        await tester.pumpWidget(
          _harness(_Playback(actions.add), nativeIOS26: true),
        );
        await tester.pumpAndSettle();

        // Compact: the progress and play/pause only.
        expect(_islandExpanded(tester), isFalse);
        final compactWidth = _glass(tester).width;
        for (final key in [
          'speech-playback-backward',
          'speech-playback-forward',
          'speech-playback-stop',
        ]) {
          expect(find.byKey(ValueKey(key)), findsNothing);
        }
        _expectOnGlass(
          tester,
          find.byKey(const ValueKey('speech-playback-expand')),
        );
        _expectOnGlass(
          tester,
          find.byKey(const ValueKey('speech-playback-toggle')),
        );
        _press(tester, 'speech-playback-toggle');
        expect(actions, ['pause']);

        await tester.tap(find.byKey(const ValueKey('speech-playback-expand')));
        await tester.pumpAndSettle();

        // Expanded: every control, across the composer's width.
        expect(_islandExpanded(tester), isTrue);
        expect(_glass(tester).width, size.width - 2 * Spacing.inputPadding);
        expect(compactWidth, lessThan(_glass(tester).width));
        for (final key in [
          'speech-playback-collapse',
          'speech-playback-backward',
          'speech-playback-toggle',
          'speech-playback-forward',
          'speech-playback-stop',
        ]) {
          _expectOnGlass(tester, find.byKey(ValueKey(key)));
        }
        _press(tester, 'speech-playback-forward');
        expect(actions, ['pause', 'skip:15']);

        await tester.tap(
          find.byKey(const ValueKey('speech-playback-collapse')),
        );
        await tester.pumpAndSettle();

        expect(_islandExpanded(tester), isFalse);
        expect(
          find.byKey(const ValueKey('speech-playback-stop')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets(
    'iOS 26 compact island keeps an error readable beside its retry',
    (tester) async {
      _useNativeIOS26();
      final actions = <String>[];
      await tester.pumpWidget(
        _harness(_Playback(actions.add, failed: true), nativeIOS26: true),
      );
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(SpeechPlaybackBar)),
      )!;

      expect(_islandExpanded(tester), isFalse);
      expect(find.textContaining('Synthetic engine details'), findsNothing);
      _expectOnGlass(tester, find.text(l10n.error));
      _press(tester, 'speech-playback-retry');
      expect(actions, ['retry']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS 26 island leaves a covering sheet clear and keeps its room',
    (tester) async {
      _useNativeIOS26();
      await tester.pumpWidget(_harness(_Playback((_) {}), nativeIOS26: true));
      await tester.pumpAndSettle();
      final bar = find.byType(SpeechPlaybackBar);
      final height = tester.getSize(bar).height;
      await tester.tap(find.byKey(const ValueKey('speech-playback-expand')));
      await tester.pumpAndSettle();
      final expandedHeight = tester.getSize(bar).height;
      expect(expandedHeight, greaterThan(height));

      // UIKit would draw the glass above the sheet.
      unawaited(
        ThemedSheets.showRoundedPage<void>(
          context: tester.element(bar),
          builder: (_) => const SizedBox.expand(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CNFloatingIsland), findsNothing);
      expect(tester.getSize(bar).height, expandedHeight);

      Navigator.of(tester.element(find.byType(SizedBox).last)).pop();
      await tester.pumpAndSettle();

      expect(_islandExpanded(tester), isTrue);
      expect(ThemedSheets.hasActiveSheet, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

class _Playback extends TextToSpeechController {
  _Playback(
    this._onAction, {
    bool failed = false,
    this.elapsed = Duration.zero,
    this.duration = Duration.zero,
  }) : _failed = failed;
  final void Function(String) _onAction;
  final bool _failed;
  final Duration elapsed;
  final Duration duration;

  @override
  TextToSpeechState build() => TextToSpeechState(
    elapsed: elapsed,
    duration: duration,
    canSeek: true,
    initialized: true,
    available: true,
    activeMessageId: 'garden-guide',
    status: _failed ? TtsPlaybackStatus.error : TtsPlaybackStatus.speaking,
    errorMessage: _failed ? 'Synthetic engine details' : null,
    sentences: const ['abcd'],
    activeSentenceIndex: 0,
    wordEndInSentence: 2,
  );

  @override
  Future<void> skip(Duration offset) async {
    _onAction('skip:${offset.inSeconds}');
  }

  @override
  Future<void> pause() async {
    _onAction('pause');
    state = state.copyWith(status: TtsPlaybackStatus.paused);
  }

  @override
  Future<void> resume() async {
    _onAction('resume');
    state = state.copyWith(status: TtsPlaybackStatus.speaking);
  }

  @override
  Future<void> retry() async {
    _onAction('retry');
    state = state.copyWith(
      status: TtsPlaybackStatus.speaking,
      clearErrorMessage: true,
    );
  }

  @override
  Future<void> stop() async {
    _onAction('stop');
    state = state.copyWith(
      status: TtsPlaybackStatus.idle,
      clearActiveMessageId: true,
    );
  }
}
