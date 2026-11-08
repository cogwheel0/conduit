import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/testing.dart';
import 'package:test/test.dart';

void main() {
  test('notification preferences are saved under ui, where the web client '
      'reads them, keeping the rest of ui', () async {
    final server = FakeUserSettingsServer(<String, dynamic>{
      'ui': <String, dynamic>{'theme': 'dark', 'notificationSoundAlways': true},
    });
    final api = ApiService(
      serverConfig: const ServerConfig(
        id: 'notification-settings',
        name: 'Notification settings',
        url: 'https://example.test',
      ),
      workerManager: WorkerManager(),
      authToken: 'account-a',
    );
    api.dio.httpClientAdapter = server;

    final saved = await api.updateUserNotificationSettings(
      notificationEnabled: true,
      notificationSound: false,
    );

    check(server.settings['ui'] as Map<String, dynamic>).deepEquals({
      'theme': 'dark',
      'notificationEnabled': true,
      'notificationSound': false,
      'notificationSoundAlways': true,
    });
    check(server.settings.keys).not((it) => it.contains('notificationEnabled'));
    check(saved.notificationEnabled).equals(true);
    check(saved.notificationSound).equals(false);
    check(saved.notificationSoundAlways).equals(true);
  });
}
