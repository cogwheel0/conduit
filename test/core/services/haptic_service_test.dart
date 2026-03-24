import 'package:flutter/foundation.dart';
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

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('falls back to Flutter haptics when gaimon is unavailable', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

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

  test(
    'android prefers Flutter system haptics even when gaimon is available',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

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
        await ConduitHaptics.mediumImpact();
      } finally {
        messenger.setMockMethodCallHandler(const MethodChannel('gaimon'), null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      }

      expect(pluginCalls, isEmpty);
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
    },
  );

  test('ios routes supported haptics through gaimon when available', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

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
