import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../data/qonduit_router_api_client.dart';

class QonduitRouterReadyNotificationService {
  final QonduitRouterApiClient apiClient;
  final FlutterLocalNotificationsPlugin notifications;

  Timer? _timer;
  bool _hasNotified = false;
  bool _initialized = false;
  bool _seenNotReadyAfterLaunch = false;

  QonduitRouterReadyNotificationService({
    required this.apiClient,
    required this.notifications,
  });

  Future<void> initialize() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await notifications.initialize(initSettings);

    final androidPlugin =
    notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.requestNotificationsPermission();
    _initialized = true;
  }

  Future<void> showTestNotification() async {
    if (!_initialized) return;

    await notifications.show(
      999,
      'Qonduit test',
      'Notifications are working.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'qonduit_test_channel',
          'Qonduit Test',
          channelDescription: 'Test notifications',
          importance: Importance.max,
          priority: Priority.high,
        ),
      ),
    );
  }

  void startWatchingForReady() {
    _hasNotified = false;
    _seenNotReadyAfterLaunch = false;
    _timer?.cancel();

    _timer = Timer.periodic(const Duration(seconds: 3), (_) async {
      final ready = await apiClient.isLlamaReady();

      if (!ready) {
        _seenNotReadyAfterLaunch = true;
        return;
      }

      if (ready && _seenNotReadyAfterLaunch && !_hasNotified && _initialized) {
        _hasNotified = true;
        _timer?.cancel();

        await notifications.show(
          1001,
          'Qonduit',
          'Model finished loading and is ready.',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'qonduit_router_ready_channel',
              'Qonduit Router Ready',
              channelDescription: 'Notifies when llama.cpp is ready',
              importance: Importance.max,
              priority: Priority.high,
            ),
          ),
        );
      }
    });
  }

  void stopWatching() {
    _timer?.cancel();
  }

  void dispose() {
    _timer?.cancel();
  }
}