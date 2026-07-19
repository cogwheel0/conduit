// Regression coverage for streaming haptic ownership. Streamed content is
// replayed when virtualized assistant rows remount, and transport ownership can
// flap isStreaming during optimistic/durable/server-echo transitions. Neither
// event may replay content-arrival or completion haptics.

import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestTextToSpeechController extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

ChatMessage _assistantMessage({
  String id = 'assistant-1',
  String content = '',
  bool isStreaming = true,
  bool responseDone = false,
}) {
  return ChatMessage(
    id: id,
    role: 'assistant',
    content: content,
    timestamp: DateTime(2026, 1, 1),
    model: 'test-model',
    isStreaming: isStreaming,
    metadata: responseDone ? const {'responseDone': true} : null,
  );
}

void main() {
  final haptics = <String>[];

  setUp(() {
    haptics.clear();
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add('${call.arguments}');
          }
          return null;
        });
  });

  Widget harness({
    required Widget child,
    required ProviderContainer container,
  }) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );
  }

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        textToSpeechControllerProvider.overrideWith(
          _TestTextToSpeechController.new,
        ),
        streamingHapticsEnabledProvider.overrideWithValue(true),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Widget assistant(ChatMessage message, {Key? key}) {
    return AssistantMessageWidget(
      key: key,
      message: message,
      isStreaming: message.isStreaming,
      showFollowUps: false,
      animateOnMount: false,
      modelName: message.model,
      onCopy: () {},
      onRegenerate: () {},
      onDelete: () {},
    );
  }

  testWidgets(
    'content arrival fires once and remounting mid-stream does not replay it',
    (tester) async {
      final container = makeContainer();
      final message = _assistantMessage();

      // Simulate mid-stream: chunks have arrived in streamingContentProvider,
      // while the message row content is still empty (as in production).
      container
          .read(streamingContentProvider.notifier)
          .set('Hello world, chunk');

      await tester.pumpWidget(
        harness(
          container: container,
          child: assistant(message, key: const ValueKey('mount-1')),
        ),
      );
      // The streamed text is applied on the next scheduled frame and produces
      // one content-arrival acknowledgement.
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      final firstMountHaptics = List.of(haptics);
      debugPrint('haptics after first mount: $firstMountHaptics');

      haptics.clear();
      // Remount with a DIFFERENT key (fresh State), same message/id — exactly
      // what happens when the row's element is recreated (live-tail slot
      // restructure, key churn, transient null from chatMessageByIdProvider).
      await tester.pumpWidget(
        harness(
          container: container,
          child: assistant(message, key: const ValueKey('mount-2')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      debugPrint('haptics after REMOUNT mid-stream: $haptics');

      expect(
        firstMountHaptics.length,
        1,
        reason: 'genuine first content arrival fires one acknowledgement',
      );
      expect(
        haptics,
        isEmpty,
        reason:
            'per-message haptic memory survives row remounts, so replayed '
            'streaming content must not create another burst',
      );
    },
  );

  testWidgets(
    'isStreaming flaps do not fire completion haptics without responseDone',
    (tester) async {
      final container = makeContainer();

      await tester.pumpWidget(
        harness(
          container: container,
          child: assistant(_assistantMessage(content: 'partial')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      haptics.clear();

      // Flap 1: true -> false
      await tester.pumpWidget(
        harness(
          container: container,
          child: assistant(
            _assistantMessage(content: 'partial', isStreaming: false),
          ),
        ),
      );
      await tester.pump();
      // back to true
      await tester.pumpWidget(
        harness(
          container: container,
          child: assistant(_assistantMessage(content: 'partial')),
        ),
      );
      await tester.pump();
      // Flap 2: true -> false
      await tester.pumpWidget(
        harness(
          container: container,
          child: assistant(
            _assistantMessage(content: 'partial', isStreaming: false),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      debugPrint('haptics after two streaming flaps: $haptics');
      expect(
        haptics,
        isEmpty,
        reason: 'transport ownership flaps are not durable completion events',
      );
    },
  );

  testWidgets('responseDone fires exactly one completion haptic', (
    tester,
  ) async {
    final container = makeContainer();

    await tester.pumpWidget(
      harness(
        container: container,
        child: assistant(_assistantMessage(content: 'complete soon')),
      ),
    );
    await tester.pump();
    haptics.clear();

    await tester.pumpWidget(
      harness(
        container: container,
        child: assistant(
          _assistantMessage(
            content: 'complete soon',
            isStreaming: false,
            responseDone: true,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(haptics.length, 1);

    // A remount of the already-completed row must not replay completion.
    haptics.clear();
    await tester.pumpWidget(
      harness(
        container: container,
        child: assistant(
          _assistantMessage(
            content: 'complete soon',
            isStreaming: false,
            responseDone: true,
          ),
          key: const ValueKey('completed-remount'),
        ),
      ),
    );
    await tester.pump();
    expect(haptics, isEmpty);
  });

  testWidgets(
    'A3 control: a plain rebuild (same State) mid-stream does NOT re-fire',
    (tester) async {
      final container = makeContainer();
      final message = _assistantMessage();
      container.read(streamingContentProvider.notifier).set('Hello world');

      await tester.pumpWidget(
        harness(container: container, child: assistant(message)),
      );
      // Let the mount-time content acknowledgement finish before clearing.
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      haptics.clear();

      container.read(streamingContentProvider.notifier).set('Hello world more');
      await tester.pumpWidget(
        harness(container: container, child: assistant(message)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      debugPrint('haptics after in-place rebuild: $haptics');
      expect(
        haptics,
        isEmpty,
        reason: 'a rebuild that keeps the State must not re-fire haptics',
      );
    },
  );
}
