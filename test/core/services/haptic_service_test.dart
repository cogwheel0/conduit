import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/services/haptic_service.dart';

class _RecordedPlatformCall {
  const _RecordedPlatformCall(this.method, this.arguments);

  final String method;
  final Object? arguments;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    PreferencesStore.debugReset();
  });

  final haptics = <String, Future<void> Function()>{
    'HapticFeedbackType.lightImpact': ConduitHaptics.lightImpact,
    'HapticFeedbackType.mediumImpact': ConduitHaptics.mediumImpact,
    'HapticFeedbackType.heavyImpact': ConduitHaptics.heavyImpact,
    'HapticFeedbackType.selectionClick': ConduitHaptics.selectionClick,
    'HapticFeedbackType.successNotification': ConduitHaptics.success,
    'HapticFeedbackType.warningNotification': ConduitHaptics.warning,
    'HapticFeedbackType.errorNotification': ConduitHaptics.error,
  };

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test(
      'uses Flutter system haptics for every operation on $platform',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final platformCalls = <_RecordedPlatformCall>[];
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          platformCalls.add(_RecordedPlatformCall(call.method, call.arguments));
          return null;
        });

        try {
          for (final callback in haptics.values) {
            await callback();
          }
        } finally {
          messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        }

        expect(
          platformCalls.map((call) => call.method),
          everyElement('HapticFeedback.vibrate'),
        );
        expect(platformCalls.map((call) => call.arguments), haptics.keys);
      },
    );
  }

  test(
    'does not invoke the platform channel on unsupported platforms',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final platformCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(call);
        return null;
      });

      try {
        await ConduitHaptics.success();
        await ConduitHaptics.vibrate();
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      }

      expect(platformCalls, isEmpty);
    },
  );

  test(
    'does not invoke the platform channel when haptics are disabled',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await PreferencesStore.put(PreferenceKeys.hapticFeedback, false);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final platformCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(call);
        return null;
      });

      try {
        await ConduitHaptics.selectionClick();
        await ConduitHaptics.mediumImpact();
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      }

      expect(platformCalls, isEmpty);
    },
  );
}
