import 'dart:convert';

enum RemotePushPlatform {
  android('android'),
  ios('ios');

  const RemotePushPlatform(this.wireName);

  final String wireName;
}

enum RemotePushTokenType {
  fcm('fcm'),
  apns('apns');

  const RemotePushTokenType(this.wireName);

  final String wireName;
}

class RemotePushDeviceToken {
  const RemotePushDeviceToken({
    required this.platform,
    required this.tokenType,
    required this.value,
  });

  final RemotePushPlatform platform;
  final RemotePushTokenType tokenType;
  final String value;
}

class RemotePushRegistration {
  const RemotePushRegistration({
    required this.subscriptionId,
    required this.webhookUrl,
  });

  final String subscriptionId;
  final String webhookUrl;

  factory RemotePushRegistration.fromJson(Map<String, dynamic> json) {
    final subscriptionId = (json['subscription_id'] ?? json['id'])
        ?.toString()
        .trim();
    final webhookUrl = json['webhook_url']?.toString().trim();
    if (subscriptionId == null ||
        subscriptionId.isEmpty ||
        webhookUrl == null ||
        webhookUrl.isEmpty) {
      throw const FormatException('push proxy registration response invalid');
    }
    return RemotePushRegistration(
      subscriptionId: subscriptionId,
      webhookUrl: webhookUrl,
    );
  }
}

class RemotePushSubscription {
  const RemotePushSubscription({
    required this.serverId,
    required this.userId,
    required this.installationId,
    required this.subscriptionId,
    required this.webhookUrl,
    required this.proxyBaseUrl,
    required this.platform,
    required this.tokenType,
    required this.updatedAt,
  });

  final String serverId;
  final String userId;
  final String installationId;
  final String subscriptionId;
  final String webhookUrl;
  final String proxyBaseUrl;
  final RemotePushPlatform platform;
  final RemotePushTokenType tokenType;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'server_id': serverId,
    'user_id': userId,
    'installation_id': installationId,
    'subscription_id': subscriptionId,
    'webhook_url': webhookUrl,
    'proxy_base_url': proxyBaseUrl,
    'platform': platform.wireName,
    'token_type': tokenType.wireName,
    'updated_at': updatedAt.toIso8601String(),
  };

  String encode() => jsonEncode(toJson());

  static RemotePushSubscription? tryDecode(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return null;
      final json = decoded.map((key, entry) => MapEntry(key.toString(), entry));
      final serverId = json['server_id']?.toString().trim();
      final userId = json['user_id']?.toString().trim();
      final installationId = json['installation_id']?.toString().trim();
      final subscriptionId = json['subscription_id']?.toString().trim();
      final webhookUrl = json['webhook_url']?.toString().trim();
      final proxyBaseUrl = json['proxy_base_url']?.toString().trim();
      final platform = _parsePlatform(json['platform']);
      final tokenType = _parseTokenType(json['token_type']);
      final updatedAt =
          DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      if (serverId == null ||
          serverId.isEmpty ||
          userId == null ||
          userId.isEmpty ||
          installationId == null ||
          installationId.isEmpty ||
          subscriptionId == null ||
          subscriptionId.isEmpty ||
          webhookUrl == null ||
          webhookUrl.isEmpty ||
          proxyBaseUrl == null ||
          proxyBaseUrl.isEmpty ||
          platform == null ||
          tokenType == null) {
        return null;
      }
      return RemotePushSubscription(
        serverId: serverId,
        userId: userId,
        installationId: installationId,
        subscriptionId: subscriptionId,
        webhookUrl: webhookUrl,
        proxyBaseUrl: proxyBaseUrl,
        platform: platform,
        tokenType: tokenType,
        updatedAt: updatedAt,
      );
    } catch (_) {
      return null;
    }
  }

  static RemotePushPlatform? _parsePlatform(Object? value) {
    final wireName = value?.toString();
    for (final platform in RemotePushPlatform.values) {
      if (platform.wireName == wireName) return platform;
    }
    return null;
  }

  static RemotePushTokenType? _parseTokenType(Object? value) {
    final wireName = value?.toString();
    for (final tokenType in RemotePushTokenType.values) {
      if (tokenType.wireName == wireName) return tokenType;
    }
    return null;
  }
}

enum RemotePushSyncStatus {
  registered,
  disabledByPreference,
  buildNotConfigured,
  unsupportedPlatform,
  serverUserWebhooksDisabled,
  missingSession,
  permissionDenied,
  tokenUnavailable,
  existingWebhookConflict,
  failed,
}

class RemotePushSyncResult {
  const RemotePushSyncResult(this.status, {this.error});

  final RemotePushSyncStatus status;
  final Object? error;

  bool get isRegistered => status == RemotePushSyncStatus.registered;
}
