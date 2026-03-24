import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/services/haptic_service.dart';

class _RecordedPlatformCall {
  const _RecordedPlatformCall(this.method, this.arguments);

  final String method;
  final Object? arguments;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('falls back to Flutter haptics when gaimon is unavailable', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final platformCalls = <_RecordedPlatformCall>[];

    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(_RecordedPlatformCall(call.method, call.arguments));
      return null;
    });

    try {
      await ConduitHaptics.mediumImpact();
    } finally {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    }

    expect(
      platformCalls,
      contains(
        isA<_RecordedPlatformCall>()
            .having((call) => call.method, 'method', 'HapticFeedback.vibrate')
            .having(
              (call) => call.arguments,
              'arguments',
              'HapticFeedbackType.mediumImpact',
            ),
      ),
    );
  });

  test('routes supported haptics through gaimon when available', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final pluginCalls = <String>[];
    final platformCalls = <_RecordedPlatformCall>[];

    messenger.setMockMethodCallHandler(const MethodChannel('gaimon'), (
      call,
    ) async {
      pluginCalls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(_RecordedPlatformCall(call.method, call.arguments));
      return null;
    });

    try {
      await ConduitHaptics.selectionClick();
    } finally {
      messenger.setMockMethodCallHandler(const MethodChannel('gaimon'), null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    }

    expect(pluginCalls, ['selection']);
    expect(platformCalls, isEmpty);
  });
}
