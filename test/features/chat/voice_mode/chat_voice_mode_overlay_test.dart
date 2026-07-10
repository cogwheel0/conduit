import 'package:conduit/features/chat/voice_mode/chat_voice_mode_overlay.dart';
import 'package:conduit/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
    final controller =
        container.read(chatVoiceModeControllerProvider.notifier)
            as _TestVoiceModeController;
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
}

Widget _buildActiveHarness(
  ProviderContainer container, {
  bool disableAnimations = false,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
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
