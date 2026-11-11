import 'dart:async';

import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/speech_playback_bar.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:cupertino_native_better/cupertino_native_better.dart'
    show CNFloatingIsland, CNPopupMenuButton;
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoSlider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/floating_island.dart';

Widget _harness(
  _Playback playback, {
  bool nativeIOS26 = false,
  double textScale = 2,
}) => ProviderScope(
  overrides: [
    textToSpeechControllerProvider.overrideWith(() => playback),
    appSettingsProvider.overrideWith(_Settings.new),
  ],
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
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      );
      return nativeIOS26 ? LegacyDesignCompatibility(child: scaled) : scaled;
    },
  ),
);

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

  for (final nativeIOS26 in [false, true]) {
    testWidgets(
      'a timed reading scrubs: its progress drives the scrubber, a drag '
      'seeks once it lifts and a change without a touch once it rests'
      '${nativeIOS26 ? ' on the iOS 26 island' : ''}',
      (tester) async {
        if (nativeIOS26) useNativeIOS26();
        final actions = <String>[];
        await tester.pumpWidget(
          _harness(
            _Playback(
              actions.add,
              elapsed: const Duration(seconds: 15),
              duration: const Duration(minutes: 1),
            ),
            nativeIOS26: nativeIOS26,
          ),
        );
        await tester.pumpAndSettle();
        final scrubber = find.descendant(
          of: find.byKey(const ValueKey('speech-playback-scrubber')),
          matching: find.byType(AdaptiveSlider),
        );
        AdaptiveSlider slider() => tester.widget<AdaptiveSlider>(scrubber);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(slider().value, .25);
        // A tap seeks too, which UIKit's slider would otherwise ignore.
        expect(slider().seekOnTap, isTrue);

        // The drag holds its place under the finger, however long it takes,
        // and seeks once the finger lifts.
        slider().onChangeStart!(.25);
        slider().onChanged!(.6);
        await tester.pump(const Duration(milliseconds: 300));
        slider().onChanged!(.5);
        await tester.pump(const Duration(milliseconds: 300));
        expect(actions, isEmpty);
        expect(slider().value, .5);
        slider().onChangeEnd!(.5);
        await tester.pump();
        expect(actions, ['seek:30']);
        await tester.pumpAndSettle();

        // VoiceOver adjusts the slider without a touch: the reading seeks
        // once the value rests.
        slider().onChanged!(.75);
        await tester.pump(const Duration(milliseconds: 100));
        expect(actions, ['seek:30']);
        expect(slider().value, .75);
        await tester.pump(const Duration(milliseconds: 150));
        expect(actions, ['seek:30', 'seek:45']);
        await tester.pumpAndSettle();
      },
      variant: nativeIOS26
          ? TargetPlatformVariant.only(TargetPlatform.iOS)
          : const DefaultTestVariant(),
    );
  }

  testWidgets(
    'a tap anywhere on the track seeks there before iOS 26, where the '
    'Cupertino slider answers only near its thumb',
    (tester) async {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
      PlatformUiCapabilities.debugNativeIOS26Override = false;
      addTearDown(PlatformUiCapabilities.resetDebugOverrides);
      final actions = <String>[];
      await tester.pumpWidget(
        _harness(
          _Playback(
            actions.add,
            elapsed: const Duration(seconds: 30),
            duration: const Duration(minutes: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final track = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('speech-playback-scrubber')),
          matching: find.byType(AdaptiveSlider),
        ),
      );
      expect(find.byType(CupertinoSlider), findsOneWidget);

      // Well away from the thumb, which sits halfway along. The thumb's
      // centre travels between 22 points in from either end.
      await tester.tapAt(
        Offset(track.left + 22 + (track.width - 44) * .75, track.center.dy),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(actions, ['seek:45']);
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a drag along the track before iOS 26 seeks once, where the finger lifts',
    (tester) async {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
      PlatformUiCapabilities.debugNativeIOS26Override = false;
      addTearDown(PlatformUiCapabilities.resetDebugOverrides);
      final actions = <String>[];
      await tester.pumpWidget(
        _harness(
          _Playback(
            actions.add,
            elapsed: const Duration(seconds: 30),
            duration: const Duration(minutes: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final slider = find.byType(CupertinoSlider);
      final track = tester.getRect(slider);

      // From the thumb, halfway along, a quarter of the track to the right.
      final finger = await tester.startGesture(track.center);
      await finger.moveBy(Offset(track.width / 8, 0));
      await tester.pump();
      await finger.moveBy(Offset(track.width / 8, 0));
      await tester.pump(const Duration(milliseconds: 300));
      final dragged = tester.widget<CupertinoSlider>(slider).value;
      expect(dragged, greaterThan(.6));
      // Nothing while the finger is down, however long it rests.
      expect(actions, isEmpty);

      await finger.up();
      await tester.pump();
      expect(actions, [
        'seek:${(const Duration(minutes: 1) * dragged).inSeconds}',
      ]);
      // And no second seek once the drag has rested.
      await tester.pump(const Duration(milliseconds: 300));
      expect(actions, hasLength(1));
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('the bar\'s speed menu sets the speed it shows', (tester) async {
    await tester.pumpWidget(_harness(_Playback((_) {}), textScale: 1));
    await tester.pumpAndSettle();
    final settings = ProviderScope.containerOf(
      tester.element(find.byType(SpeechPlaybackBar)),
    );
    await tester.tap(find.text('1×'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.5×').last);
    await tester.pumpAndSettle();
    expect(settings.read(appSettingsProvider).ttsSpeed, 1.5);
    expect(find.text('1.5×'), findsOneWidget);
  });

  testWidgets('the iOS 26 island\'s speed menu sets the speed it shows', (
    tester,
  ) async {
    useNativeIOS26();
    await tester.pumpWidget(
      _harness(_Playback((_) {}), nativeIOS26: true, textScale: 1),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('speech-playback-expand')));
    await tester.pumpAndSettle();
    final settings = ProviderScope.containerOf(
      tester.element(find.byType(SpeechPlaybackBar)),
    );
    CNPopupMenuButton menu() => tester.widget<CNPopupMenuButton>(
      find.byKey(const ValueKey('speech-playback-speed')),
    );
    expectOnFloatingIslandGlass(
      tester,
      find.byKey(const ValueKey('speech-playback-speed')),
    );
    expect(menu().buttonLabel, '1×');
    // 0.75×, 1×, 1.25×, 1.5×, 2×.
    menu().onSelected!(4);
    await tester.pumpAndSettle();
    expect(settings.read(appSettingsProvider).ttsSpeed, 2.0);
    expect(menu().buttonLabel, '2×');
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a reading without a known length shows its progress, '
      'not a scrubber', (tester) async {
    await tester.pumpWidget(_harness(_Playback((_) {})));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('speech-playback-scrubber')),
      findsNothing,
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .5,
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

  // At regular text the pill keeps the 15-second skips; a phone at 2x text
  // leaves the pill room for its main action only.
  for (final (size, textScale, compactSkips) in [
    (const Size(402, 874), 1.0, true),
    (const Size(320, 568), 2.0, false),
    (const Size(390, 844), 2.0, false),
    (const Size(1024, 768), 2.0, true),
  ]) {
    testWidgets(
      'iOS 26 island expands from a compact pill with every control on its '
      'glass at ${textScale}x text in $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        useNativeIOS26();
        final actions = <String>[];
        await tester.pumpWidget(
          _harness(
            _Playback(actions.add),
            nativeIOS26: true,
            textScale: textScale,
          ),
        );
        await tester.pumpAndSettle();

        // Compact: the progress and play/pause, between the skips when they
        // fit, but not stop.
        expect(floatingIsland(tester).isExpanded, isFalse);
        final compactWidth = floatingIslandGlass(tester).width;
        expect(
          find.byKey(const ValueKey('speech-playback-stop')),
          findsNothing,
        );
        final compactControls = [
          'speech-playback-expand',
          if (compactSkips) 'speech-playback-backward',
          'speech-playback-toggle',
          if (compactSkips) 'speech-playback-forward',
        ];
        for (final key in compactControls) {
          expectOnFloatingIslandGlass(tester, find.byKey(ValueKey(key)));
        }
        if (!compactSkips) {
          expect(
            find.byKey(const ValueKey('speech-playback-backward')),
            findsNothing,
          );
        }
        _press(tester, 'speech-playback-toggle');
        expect(actions, ['pause']);

        await tester.tap(find.byKey(const ValueKey('speech-playback-expand')));
        await tester.pumpAndSettle();

        // Expanded: every control, across the composer's width.
        expect(floatingIsland(tester).isExpanded, isTrue);
        expect(
          floatingIslandGlass(tester).width,
          size.width - 2 * Spacing.inputPadding,
        );
        expect(compactWidth, lessThan(floatingIslandGlass(tester).width));
        for (final key in [
          'speech-playback-collapse',
          'speech-playback-speed',
          'speech-playback-backward',
          'speech-playback-toggle',
          'speech-playback-forward',
          'speech-playback-stop',
        ]) {
          expectOnFloatingIslandGlass(tester, find.byKey(ValueKey(key)));
        }
        // However narrow the panel, the time keeps a target that minimises.
        expect(
          tester
              .getSize(find.byKey(const ValueKey('speech-playback-collapse')))
              .width,
          greaterThanOrEqualTo(TouchTarget.minimum),
        );
        _press(tester, 'speech-playback-forward');
        expect(actions, ['pause', 'skip:15']);

        await tester.tap(
          find.byKey(const ValueKey('speech-playback-collapse')),
        );
        await tester.pumpAndSettle();

        expect(floatingIsland(tester).isExpanded, isFalse);
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
      useNativeIOS26();
      final actions = <String>[];
      await tester.pumpWidget(
        _harness(_Playback(actions.add, failed: true), nativeIOS26: true),
      );
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(SpeechPlaybackBar)),
      )!;

      expect(floatingIsland(tester).isExpanded, isFalse);
      expect(find.textContaining('Synthetic engine details'), findsNothing);
      expectOnFloatingIslandGlass(tester, find.text(l10n.error));
      _press(tester, 'speech-playback-retry');
      expect(actions, ['retry']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS 26 island leaves a covering sheet clear and keeps its room',
    (tester) async {
      useNativeIOS26();
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

      expect(floatingIsland(tester).isExpanded, isTrue);
      expect(ThemedSheets.hasActiveSheet, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> setTtsSpeed(double speed) async =>
      state = state.copyWith(ttsSpeed: speed);
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
  Future<void> seekTo(Duration position) async {
    _onAction('seek:${position.inSeconds}');
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
