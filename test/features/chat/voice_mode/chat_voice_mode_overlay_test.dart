import 'package:conduit/features/chat/voice_mode/chat_voice_mode_overlay.dart';
import 'package:conduit/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_native_better/cupertino_native_better.dart'
    show
        CNFloatingIsland,
        CNIcon,
        CNSymbolEffectType,
        CNSymbolReplaceTransition;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/floating_island.dart';
import '../../../support/native_platform_views.dart';

void main() {
  testWidgets('inactive overlay does not collapse a loose Stack', (
    tester,
  ) async {
    const stackKey = Key('chat-stack');
    const bodyKey = Key('chat-body');

    await tester.pumpWidget(
      const ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 300,
              height: 500,
              child: Align(
                alignment: Alignment.topLeft,
                child: Stack(
                  key: stackKey,
                  children: [
                    Positioned.fill(
                      child: ColoredBox(key: bodyKey, color: Colors.black),
                    ),
                    ChatVoiceModeOverlay(bottomOffset: 0),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(stackKey)), const Size(300, 500));
    expect(tester.getSize(find.byKey(bodyKey)), const Size(300, 500));
  });

  testWidgets('live transcript updates directly and intensity avoids layout', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        chatVoiceModeControllerProvider.overrideWith(
          () => _TestVoiceModeController(
            const ChatVoiceModeSnapshot(
              phase: ChatVoiceModePhase.speaking,
              spokenResponse: 'First partial',
              intensity: 0,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildActiveHarness(container));
    final controller = container.read(
      chatVoiceModeControllerProvider.notifier,
    ) as _TestVoiceModeController;
    final dotFinder = find.byKey(const ValueKey('voice-status-dot'));
    final scaleFinder = find.byKey(const ValueKey('voice-status-dot-scale'));
    final initialSize = tester.getSize(dotFinder);
    expect(find.text('First partial', findRichText: true), findsOneWidget);
    expect(
      find.byKey(const ValueKey('voice-mode-surface-switcher')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('voice-overlay-expanded')),
        matching: find.byType(AnimatedSwitcher),
      ),
      findsNothing,
    );

    controller.update(
      const ChatVoiceModeSnapshot(
        phase: ChatVoiceModePhase.speaking,
        spokenResponse: 'Second partial',
        intensity: 10,
      ),
    );
    await tester.pump();

    expect(find.text('Second partial', findRichText: true), findsOneWidget);
    expect(tester.getSize(dotFinder), initialSize);
    expect(
      tester.widget<Transform>(scaleFinder).transform.getMaxScaleOnAxis(),
      greaterThan(1),
    );
  });

  testWidgets('an error is shown by its kind, never as an exception text', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        chatVoiceModeControllerProvider.overrideWith(
          () => _TestVoiceModeController(
            const ChatVoiceModeSnapshot(
              phase: ChatVoiceModePhase.error,
              errorMessage: 'Microphone permission denied.',
              errorKind: ChatVoiceModeError.microphoneDenied,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildActiveHarness(container));
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ChatVoiceModeOverlay)),
    )!;

    expect(find.text(l10n.microphonePermissionDenied), findsOneWidget);

    final controller = container.read(
      chatVoiceModeControllerProvider.notifier,
    ) as _TestVoiceModeController;
    controller.update(
      const ChatVoiceModeSnapshot(
        phase: ChatVoiceModePhase.error,
        errorMessage: 'SocketException: connection refused',
        errorKind: ChatVoiceModeError.other,
      ),
    );
    await tester.pump();

    expect(find.text('SocketException: connection refused'), findsNothing);
    expect(find.text(l10n.voiceCallFailed), findsOneWidget);

    controller.update(
      const ChatVoiceModeSnapshot(
        phase: ChatVoiceModePhase.error,
        errorMessage: 'The server could not answer.',
        errorKind: ChatVoiceModeError.message,
      ),
    );
    await tester.pump();

    expect(find.text('The server could not answer.'), findsOneWidget);
  });

  testWidgets('reduced motion makes voice surface changes spatially static', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        chatVoiceModeControllerProvider.overrideWith(
          () => _TestVoiceModeController(
            const ChatVoiceModeSnapshot(
              phase: ChatVoiceModePhase.listening,
              intensity: 10,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _buildActiveHarness(container, disableAnimations: true),
    );

    final switcher = tester.widget<AnimatedSwitcher>(
      find.byKey(const ValueKey('voice-mode-surface-switcher')),
    );
    final size = tester.widget<AnimatedSize>(
      find.byKey(const ValueKey('voice-mode-surface-size')),
    );
    final scale = tester.widget<Transform>(
      find.byKey(const ValueKey('voice-status-dot-scale')),
    );
    expect(switcher.duration, Duration.zero);
    expect(size.duration, Duration.zero);
    expect(size.clipBehavior, Clip.none);
    expect(scale.transform.getMaxScaleOnAxis(), 1);
  });

  testWidgets(
    'iOS 26 toggles animate their native symbols in place as the call changes',
    (tester) async {
      stubNativePlatformViews();
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
      PlatformUiCapabilities.debugNativeIOS26Override = true;
      addTearDown(PlatformUiCapabilities.resetDebugOverrides);
      final container = ProviderContainer(
        overrides: [
          chatVoiceModeControllerProvider.overrideWith(
            () => _TestVoiceModeController(
              const ChatVoiceModeSnapshot(phase: ChatVoiceModePhase.listening),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_buildActiveHarness(container));
      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      ) as _TestVoiceModeController;
      // Mute, speaker and pause, in that order. Minimize and End never change,
      // so they keep Flutter icons rather than a platform view each.
      final icons = find.byType(CNIcon);
      CNIcon icon(int index) => tester.widget<CNIcon>(icons.at(index));
      final views = [for (var i = 0; i < 3; i++) tester.state(icons.at(i))];

      expect(icons, findsNWidgets(3));
      expect(icon(0).symbol!.name, 'mic.fill');
      expect(icon(0).replaceTransition, CNSymbolReplaceTransition.magic);
      expect(icon(1).symbol!.name, 'speaker.wave.1');
      expect(icon(1).replaceTransition, CNSymbolReplaceTransition.replace);
      expect(icon(1).effect, isNull);
      expect(icon(2).symbol!.name, 'pause.fill');
      expect(icon(2).replaceTransition, CNSymbolReplaceTransition.replace);

      controller.update(
        const ChatVoiceModeSnapshot(
          phase: ChatVoiceModePhase.speaking,
          spokenResponse: 'Here is the forecast.',
          isSpeakerphoneEnabled: true,
        ),
      );
      await tester.pump();

      expect(icon(1).symbol!.name, 'speaker.wave.3.fill');
      expect(icon(1).effect?.type, CNSymbolEffectType.variableColor);

      controller.update(
        const ChatVoiceModeSnapshot(
          phase: ChatVoiceModePhase.muted,
          isMuted: true,
          isSpeakerphoneEnabled: true,
        ),
      );
      await tester.pump();

      expect(icon(0).symbol!.name, 'mic.slash.fill');
      expect(icon(1).effect, isNull);
      expect(icon(2).symbol!.name, 'play.fill');
      // A replace transition plays only inside the view that showed the old
      // symbol, so each toggle must update its view rather than replace it.
      expect([for (var i = 0; i < 3; i++) tester.state(icons.at(i))], views);
      await tester.pump(const Duration(milliseconds: 500));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  group('iOS 26 island', () {
    // A transcript, a reply and an error past the lines they may take.
    const transcript =
        'Please remind me to water the fern on the balcony tomorrow morning, '
        'then check whether the tomato seedlings need a bigger pot, and add '
        'potting soil, twine and a small watering can to the shopping list.';
    const reply =
        'The fern gets a reminder at eight tomorrow, and potting soil, twine '
        'and a small watering can are on the shopping list for Saturday.';
    const error =
        'The garden planner could not save the reminder because the shared '
        'list is read-only for this account; ask its owner for edit access.';
    const quiet = ChatVoiceModeSnapshot(phase: ChatVoiceModePhase.listening);
    const listening = ChatVoiceModeSnapshot(
      phase: ChatVoiceModePhase.listening,
      transcript: transcript,
      errorMessage: error,
      errorKind: ChatVoiceModeError.message,
    );
    const speaking = ChatVoiceModeSnapshot(
      phase: ChatVoiceModePhase.speaking,
      spokenResponse: reply,
      spokenWordStart: 4,
      spokenWordEnd: 8,
      errorMessage: error,
      errorKind: ChatVoiceModeError.message,
    );

    Finder action(String tooltip) => find.descendant(
      of: find.byWidgetPredicate(
        (widget) => widget is AdaptiveTooltip && widget.message == tooltip,
      ),
      matching: find.byType(AdaptiveButton),
    );

    /// Expects the panel to leave the transcript and the reply to the chat
    /// and to fit the error on the glass between the header and the
    /// controls.
    void expectErrorFitsWithoutCallText(
      WidgetTester tester,
      AppLocalizations l10n,
    ) {
      expect(find.text(transcript), findsNothing);
      expect(find.text(reply, findRichText: true), findsNothing);
      final controlsTop = tester.getRect(action(l10n.voiceCallEnd)).top;
      expectOnFloatingIslandGlass(tester, find.text(error));
      expect(
        tester.getRect(find.text(error)).bottom,
        lessThanOrEqualTo(controlsTop),
      );
      expectOnFloatingIslandGlass(tester, action(l10n.voiceCallEnd));
    }

    testWidgets(
      'morphs between the pill and a panel that keeps room for an error but '
      'leaves the call text to the chat',
      (tester) async {
        useNativeIOS26();
        final container = ProviderContainer(
          overrides: [
            chatVoiceModeControllerProvider.overrideWith(
              () => _TestVoiceModeController(quiet),
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(_buildActiveHarness(container));
        await tester.pumpAndSettle();
        final l10n = AppLocalizations.of(
          tester.element(find.byType(ChatVoiceModeOverlay)),
        )!;
        final controller = container.read(
          chatVoiceModeControllerProvider.notifier,
        ) as _TestVoiceModeController;

        // The panel spans the composer's width with room to spare while the
        // call is quiet.
        final island = tester.state(find.byType(CNFloatingIsland));
        final panel = floatingIslandGlass(tester);
        expect(floatingIsland(tester).isExpanded, isTrue);
        expect(panel.width, 402 - 2 * Spacing.inputPadding);

        // Heard and spoken text never shows, and an error fits without
        // resizing the island.
        for (final snapshot in [listening, speaking]) {
          controller.update(snapshot);
          await tester.pumpAndSettle();
          expect(tester.state(find.byType(CNFloatingIsland)), same(island));
          expect(floatingIslandGlass(tester), panel);
          expectErrorFitsWithoutCallText(tester, l10n);
        }

        tester
            .widget<AdaptiveButton>(action(l10n.voiceCallMinimize))
            .onPressed!();
        await tester.pumpAndSettle();

        // The pill: status, expand and end, on a narrower glass.
        expect(floatingIsland(tester).isExpanded, isFalse);
        expect(floatingIslandGlass(tester).width, lessThan(panel.width));
        expectOnFloatingIslandGlass(tester, find.text(l10n.voiceCallSpeaking));
        expectOnFloatingIslandGlass(tester, action(l10n.voiceCallExpand));
        expectOnFloatingIslandGlass(tester, action(l10n.voiceCallEnd));
        expect(tester.state(find.byType(CNFloatingIsland)), same(island));

        tester
            .widget<AdaptiveButton>(action(l10n.voiceCallExpand))
            .onPressed!();
        await tester.pumpAndSettle();

        expect(floatingIsland(tester).isExpanded, isTrue);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'a text size change mid-call resizes the same island for the larger '
      'error',
      (tester) async {
        useNativeIOS26();
        final container = ProviderContainer(
          overrides: [
            chatVoiceModeControllerProvider.overrideWith(
              () => _TestVoiceModeController(listening),
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(_buildActiveHarness(container));
        await tester.pumpAndSettle();
        final l10n = AppLocalizations.of(
          tester.element(find.byType(ChatVoiceModeOverlay)),
        )!;
        final island = tester.state(find.byType(CNFloatingIsland));
        final height = floatingIsland(tester).expandedHeight!;

        await tester.pumpWidget(
          _buildActiveHarness(
            container,
            textScaler: const TextScaler.linear(1.6),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.state(find.byType(CNFloatingIsland)), same(island));
        expect(floatingIsland(tester).expandedHeight, greaterThan(height));
        expectErrorFitsWithoutCallText(tester, l10n);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets('under Reduce Motion the glass takes each new shape at once', (
      tester,
    ) async {
      useNativeIOS26();
      final container = ProviderContainer(
        overrides: [
          chatVoiceModeControllerProvider.overrideWith(
            () => _TestVoiceModeController(quiet),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(_buildActiveHarness(container));
      await tester.pumpAndSettle();
      expect(floatingIsland(tester).springResponse, greaterThan(0));

      await tester.pumpWidget(
        _buildActiveHarness(container, disableAnimations: true),
      );
      await tester.pumpAndSettle();
      // SwiftUI's spring of no length is infinitely stiff.
      expect(floatingIsland(tester).springResponse, 0);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}

Widget _buildActiveHarness(
  ProviderContainer container, {
  bool disableAnimations = false,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => LegacyDesignCompatibility(child: child!),
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
            disableAnimations: disableAnimations,
            textScaler: textScaler,
          ),
          child: const SizedBox(
            width: 402,
            height: 874,
            child: Stack(
              children: [
                Positioned.fill(child: SizedBox.shrink()),
                ChatVoiceModeOverlay(bottomOffset: 0),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _TestVoiceModeController extends ChatVoiceModeController {
  _TestVoiceModeController(this.initialState);

  final ChatVoiceModeSnapshot initialState;

  @override
  ChatVoiceModeSnapshot build() => initialState;

  void update(ChatVoiceModeSnapshot next) => state = next;
}
