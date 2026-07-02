import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../../../core/utils/debug_logger.dart';
import 'remote_push_models.dart';

class RemotePushSubscriptionStore {
  RemotePushSubscriptionStore(this._storage);

  final FlutterSecureStorage _storage;

  static const _installationKey = 'remote_push_installation_id_v1';
  static const _subscriptionPrefix = 'remote_push_subscription_v1_';

  Future<String> getOrCreateInstallationId() async {
    final current = (await _storage.read(key: _installationKey))?.trim();
    if (current != null && current.isNotEmpty) {
      return current;
    }
    final next = const Uuid().v4();
    await _storage.write(key: _installationKey, value: next);
    return next;
  }

  Future<RemotePushSubscription?> read(String serverId) async {
    final value = await _storage.read(key: _key(serverId));
    return RemotePushSubscription.tryDecode(value);
  }

  Future<void> write(RemotePushSubscription subscription) async {
    await _storage.write(
      key: _key(subscription.serverId),
      value: subscription.encode(),
    );
  }

  Future<void> delete(String serverId) async {
    await _storage.delete(key: _key(serverId));
  }

  Future<List<RemotePushSubscription>> readAll() async {
    try {
      final all = await _storage.readAll();
      return all.entries
          .where((entry) => entry.key.startsWith(_subscriptionPrefix))
          .map((entry) => RemotePushSubscription.tryDecode(entry.value))
          .whereType<RemotePushSubscription>()
          .toList(growable: false);
    } catch (e, st) {
      DebugLogger.error(
        'failed to read remote push subscriptions',
        error: e,
        stackTrace: st,
        scope: 'notifications/push',
      );
      return const <RemotePushSubscription>[];
    }
  }

  static String _key(String serverId) => '$_subscriptionPrefix$serverId';
}
