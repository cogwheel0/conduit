part of 'api_service.dart';

/// Open WebUI webhook destinations under `/api/v1/notifications`.
///
/// Every call requires the [ApiAuthSnapshot] of the account that asked for it,
/// so a request that was admitted for one account can never be sent with the
/// credentials of the account that signed in afterwards on this same
/// [ApiService]. The destination URL is a secret: it is sent only when the
/// caller passes one, never logged, and never part of an exception message.
mixin _NotificationTargetsApi on _ApiServiceBase {
  static const String _base = '/api/v1/notifications';

  String _targetPath(String targetId) =>
      '$_base/targets/${Uri.encodeComponent(targetId)}';

  /// The event kinds a destination can subscribe to. This is a catalog, not a
  /// record of notifications that were sent.
  Future<List<NotificationEvent>> getNotificationEvents({
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Fetching notification event catalog');
    final response = await _dio.get(
      '$_base/events',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final events = _requireResponseMap(
      response.data,
      'notification events',
    )['events'];
    if (events is! List) {
      throw const FormatException('notification events: missing events list');
    }
    return List<NotificationEvent>.unmodifiable([
      for (final entry in events)
        if (entry is Map)
          ?NotificationEvent.tryParse(entry.cast<String, dynamic>()),
    ]);
  }

  Future<List<NotificationTarget>> getNotificationTargets({
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Fetching notification targets');
    final response = await _dio.get(
      '$_base/targets',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final targets = _requireResponseMap(
      response.data,
      'notification targets',
    )['targets'];
    if (targets is! List) {
      throw const FormatException('notification targets: missing targets list');
    }
    return List<NotificationTarget>.unmodifiable([
      for (final entry in targets)
        if (entry is Map)
          NotificationTarget.fromJson(entry.cast<String, dynamic>()),
    ]);
  }

  /// Creates a webhook destination. [id] is optional; the server derives one
  /// from the URL host when it is blank.
  Future<NotificationTarget> createNotificationTarget({
    required String url,
    required bool enabled,
    required List<String> events,
    required String delivery,
    String? id,
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Creating notification target');
    final trimmedId = id?.trim();
    final response = await _dio.post(
      '$_base/targets',
      data: <String, dynamic>{
        if (trimmedId != null && trimmedId.isNotEmpty) 'id': trimmedId,
        'type': NotificationTarget.webhookType,
        'enabled': enabled,
        'events': events,
        'delivery': delivery,
        'config': <String, dynamic>{'url': url.trim()},
      },
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return NotificationTarget.fromJson(
      _requireResponseMap(response.data, 'notification target'),
    );
  }

  /// Updates a destination. Only the arguments that are passed are sent, and
  /// the server keeps what it already stores for the rest.
  ///
  /// [replacementUrl] is the one way a URL goes out. A blank value is treated
  /// as not replacing, as the web client does. The server's masked form must
  /// not be passed here: it is display-only.
  Future<NotificationTarget> updateNotificationTarget(
    String targetId, {
    bool? enabled,
    List<String>? events,
    String? delivery,
    String? replacementUrl,
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Updating notification target');
    final url = replacementUrl?.trim();
    final response = await _dio.put(
      _targetPath(targetId),
      data: <String, dynamic>{
        'enabled': ?enabled,
        'events': ?events,
        'delivery': ?delivery,
        if (url != null && url.isNotEmpty)
          'config': <String, dynamic>{'url': url},
      },
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return NotificationTarget.fromJson(
      _requireResponseMap(response.data, 'notification target'),
    );
  }

  Future<void> deleteNotificationTarget(
    String targetId, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Deleting notification target');
    await _dio.delete(
      _targetPath(targetId),
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
  }

  Future<NotificationTarget> setDefaultNotificationTarget(
    String targetId, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Setting default notification target');
    final response = await _dio.put(
      '${_targetPath(targetId)}/default',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return NotificationTarget.fromJson(
      _requireResponseMap(response.data, 'notification target'),
    );
  }

  /// Asks the server to deliver one real test notification to the destination.
  /// Call this only from an explicit user action: it contacts the webhook.
  Future<void> testNotificationTarget(
    String targetId, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Testing notification target');
    final response = await _dio.post(
      '${_targetPath(targetId)}/test',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final body = _requireResponseMap(response.data, 'notification test');
    if (body['ok'] != true) {
      throw const FormatException('notification test: server did not confirm');
    }
  }
}
