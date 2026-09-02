// ignore_for_file: depend_on_referenced_packages

import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

class _FakeWakelock extends WakelockPlusPlatformInterface {
  final toggles = <bool>[];
  bool throwOnToggle = false;

  @override
  Future<void> toggle({required bool enable}) async {
    toggles.add(enable);
    if (throwOnToggle) throw StateError('wakelock unavailable');
  }

  @override
  Future<bool> get enabled async => toggles.lastOrNull ?? false;
}

ChatMessage _assistantMessage({required bool isStreaming}) => ChatMessage(
  id: 'assistant',
  role: 'assistant',
  content: isStreaming ? '' : 'Done',
  timestamp: DateTime(2026),
  isStreaming: isStreaming,
);

Future<void> _flushPluginCall() => pumpEventQueue(times: 20);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WakelockPlusPlatformInterface originalPlatform;
  late _FakeWakelock fakePlatform;

  setUp(() {
    originalPlatform = wakelockPlusPlatformInstance;
    fakePlatform = _FakeWakelock();
    wakelockPlusPlatformInstance = fakePlatform;
  });

  tearDown(() {
    wakelockPlusPlatformInstance = originalPlatform;
  });

  test('holds the screen through foreground and headless streaming', () async {
    final container = ProviderContainer();
    container.read(chatWakelockCoordinatorProvider);
    await _flushPluginCall();

    container.read(chatMessagesProvider.notifier).setMessages([
      _assistantMessage(isStreaming: true),
    ]);
    await _flushPluginCall();
    container.read(activeChatIdsProvider.notifier).setActive('background-chat');
    container.read(chatMessagesProvider.notifier).setMessages([
      _assistantMessage(isStreaming: false),
    ]);
    await _flushPluginCall();
    expect(fakePlatform.toggles, [false, true]);

    container
        .read(activeChatIdsProvider.notifier)
        .setInactive('background-chat');
    await _flushPluginCall();
    container.read(activeChatIdsProvider.notifier).setActive('background-chat');
    await _flushPluginCall();
    container.dispose();
    await _flushPluginCall();

    expect(fakePlatform.toggles, [false, true, false, true, false]);
  });

  test('wakelock failures do not change generation state', () async {
    fakePlatform.throwOnToggle = true;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(chatWakelockCoordinatorProvider);
    container.read(chatMessagesProvider.notifier).setMessages([
      _assistantMessage(isStreaming: true),
    ]);
    await _flushPluginCall();

    expect(container.read(isChatStreamingProvider), isTrue);
    expect(fakePlatform.toggles, contains(true));
  });
}
