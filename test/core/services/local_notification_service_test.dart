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
      _setNotificationChannelHandler(channel, calls);

      final service = LocalNotificationService.testing(isIOS: true);

      final enabled = await service.areNotificationsEnabled();

      check(enabled).isFalse();
      check(calls).contains('initialize');
      check(calls).contains('checkPermissions');
    },
  );

  test('drains multiple background taps in order on startup', () async {
    final calls = <String>[];
    _setNotificationChannelHandler(channel, calls);
    await localNotificationTapBackground(_response('first'));
    await localNotificationTapBackground(_response('second'));
    final service = LocalNotificationService.testing(isIOS: true);
    final deliveredPayloads = <String>[];
    service.addResponseHandler('test', (response) {
      deliveredPayloads.add(response.payload ?? '');
    });

    await service.initialize();

    check(deliveredPayloads).deepEquals(['first', 'second']);
  });

  test('keeps concurrent background taps on startup', () async {
    final calls = <String>[];
    _setNotificationChannelHandler(channel, calls);
    await Future.wait([
      localNotificationTapBackground(_response('first')),
      localNotificationTapBackground(_response('second')),
    ]);
    final service = LocalNotificationService.testing(isIOS: true);
    final deliveredPayloads = <String>[];
    service.addResponseHandler('test', (response) {
      deliveredPayloads.add(response.payload ?? '');
    });

    await service.initialize();

    check(deliveredPayloads..sort()).deepEquals(['first', 'second']);
  });

  test('does not replay a drained tap when a handler re-registers', () async {
    final calls = <String>[];
    _setNotificationChannelHandler(channel, calls);
    await localNotificationTapBackground(_response('queued'));
    final service = LocalNotificationService.testing(isIOS: true);
    await service.initialize();
    final deliveredPayloads = <String>[];
    void handler(NotificationResponse response) {
      deliveredPayloads.add(response.payload ?? '');
    }

    service.addResponseHandler('test', handler);
    service.removeResponseHandler('test');
    service.addResponseHandler('test', handler);

    check(deliveredPayloads).deepEquals(['queued']);
  });

  test(
    'routes a repeated queued tap after the first delivery drains',
    () async {
      final calls = <String>[];
      _setNotificationChannelHandler(channel, calls);
      final service = LocalNotificationService.testing(isIOS: true);
      await service.initialize();
      final deliveredPayloads = <String>[];
      void handler(NotificationResponse response) {
        deliveredPayloads.add(response.payload ?? '');
      }

      service.handleNotificationResponseForTesting(_response('repeat'));
      service.addResponseHandler('test', handler);
      service.removeResponseHandler('test');
      service.handleNotificationResponseForTesting(_response('repeat'));
      service.addResponseHandler('test', handler);

      check(deliveredPayloads).deepEquals(['repeat', 'repeat']);
    },
  );
}

void _setNotificationChannelHandler(MethodChannel channel, List<String> calls) {
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
}

NotificationResponse _response(String payload) {
  return NotificationResponse(
    notificationResponseType: NotificationResponseType.selectedNotification,
    id: payload.hashCode,
    payload: payload,
  );
}
