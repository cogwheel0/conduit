import 'package:checks/checks.dart';
import 'package:conduit/core/services/local_notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    IOSFlutterLocalNotificationsPlugin.registerWith();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'iOS enabled check reads system permissions after initialization',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return switch (call.method) {
              'initialize' => true,
              'getNotificationAppLaunchDetails' => {
                'notificationLaunchedApp': false,
              },
              'checkPermissions' => {
                'isEnabled': false,
                'isAlertEnabled': false,
                'isBadgeEnabled': false,
                'isSoundEnabled': false,
                'isProvisionalEnabled': false,
                'isCriticalEnabled': false,
                'isProvidesAppNotificationSettingsEnabled': false,
                'isCarPlayEnabled': false,
              },
              _ => null,
            };
          });

      final service = LocalNotificationService.testing(isIOS: true);

      final enabled = await service.areNotificationsEnabled();

      check(enabled).isFalse();
      check(calls).contains('initialize');
      check(calls).contains('checkPermissions');
    },
  );
}
