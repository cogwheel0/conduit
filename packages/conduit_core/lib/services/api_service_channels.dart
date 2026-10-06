part of 'api_service.dart';

mixin _ChannelsApi on _ApiServiceBase {
  // Team Collaboration

  /// Returns a record with (channels data, feature enabled flag).
  /// When the channels feature is disabled server-side (401 or 403),
  /// returns ([], false). Mirrors the getNotes() pattern.
  Future<(List<Map<String, dynamic>>, bool)> getChannels() async {
    try {
      _traceApi('Fetching channels');
      final response = await _dio.get('/api/v1/channels/');
      DebugLogger.log(
        'fetch-status',
        scope: 'api/channels',
        data: {'code': response.statusCode},
      );
      DebugLogger.log('fetch-ok', scope: 'api/channels');

      final data = response.data;
      if (data is List) {
        _traceApi('Found ${data.length} channels');
        return (data.cast<Map<String, dynamic>>(), true);
      } else {
        DebugLogger.warning(
          'unexpected-type',
          scope: 'api/channels',
          data: {'type': data.runtimeType},
        );
        return (const <Map<String, dynamic>>[], true);
      }
    } on DioException catch (e) {
      // 401/403 indicates channels feature is disabled server-side or user lacks permission
      final statusCode = e.response?.statusCode;
      if (statusCode == 401 || statusCode == 403) {
        DebugLogger.log(
          'feature-disabled',
          scope: 'api/channels',
          data: {'status': statusCode},
        );
        return (const <Map<String, dynamic>>[], false);
      }
      DebugLogger.error('fetch-failed', scope: 'api/channels', error: e);
      rethrow;
    } catch (e) {
      DebugLogger.error('fetch-failed', scope: 'api/channels', error: e);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> createChannel({
    required String name,
    String? type,
    String? description,
    bool? isPrivate,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
    List<Map<String, dynamic>>? accessGrants,
    List<String>? groupIds,
    List<String>? userIds,
  }) async {
    _traceApi('Creating channel: $name');
    final response = await _dio.post(
      '/api/v1/channels/create',
      data: {
        'name': name,
        'type': ?type,
        'description': ?description,
        'is_private': ?isPrivate,
        'data': ?data,
        'meta': ?meta,
        'access_grants': ?accessGrants,
        'group_ids': ?groupIds,
        'user_ids': ?userIds,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  /// Reads one channel.
  ///
  /// Pass [authSnapshot] when the read belongs to the account that opened a
  /// screen: it is refused rather than sent with a token that replaced it.
  Future<Map<String, dynamic>> getChannel(
    String channelId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Fetching channel details: $channelId');
    final response = await _dio.get(
      '/api/v1/channels/$channelId',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateChannel(
    String channelId, {
    String? name,
    String? description,
    bool? isPrivate,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
    List<Map<String, dynamic>>? accessGrants,
  }) async {
    _traceApi('Updating channel: $channelId');
    final response = await _dio.post(
      '/api/v1/channels/$channelId/update',
      data: {
        'name': ?name,
        'description': ?description,
        'is_private': ?isPrivate,
        'data': ?data,
        'meta': ?meta,
        'access_grants': ?accessGrants,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> deleteChannel(String channelId) async {
    _traceApi('Deleting channel: $channelId');
    await _dio.delete('/api/v1/channels/$channelId/delete');
  }

  /// Reads one page of a channel's members.
  ///
  /// Pass [authSnapshot] when a caller must stay bound to the account that
  /// opened the list: the request is refused rather than sent with a token
  /// that replaced it on this shared client.
  Future<Map<String, dynamic>> getChannelMembers(
    String channelId, {
    String? query,
    String? orderBy,
    String? direction,
    int page = 1,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Fetching channel members: $channelId');
    final params = <String, dynamic>{'page': page};
    if (query != null) params['query'] = query;
    if (orderBy != null) params['order_by'] = orderBy;
    if (direction != null) {
      params['direction'] = direction;
    }
    final response = await _dio.get(
      '/api/v1/channels/$channelId/members',
      queryParameters: params,
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return response.data as Map<String, dynamic>;
  }

  /// Adds users and groups to a channel. The server allows this for the
  /// channel owner or an admin; any other caller gets a 403.
  Future<void> addChannelMembers(
    String channelId, {
    List<String> userIds = const [],
    List<String> groupIds = const [],
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Adding channel members: $channelId');
    await _dio.post(
      '/api/v1/channels/$channelId/update/members/add',
      data: {'user_ids': userIds, 'group_ids': groupIds},
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
  }

  /// Removes users from a channel. The server has no group form of this
  /// route, so only user ids are accepted.
  Future<void> removeChannelMembers(
    String channelId, {
    required List<String> userIds,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Removing channel members: $channelId');
    await _dio.post(
      '/api/v1/channels/$channelId/update/members/remove',
      data: {'user_ids': userIds},
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
  }

  Future<List<Map<String, dynamic>>> getChannelMessages(
    String channelId, {
    int skip = 0,
    int limit = 50,
  }) async {
    _traceApi('Fetching channel messages: $channelId');
    final response = await _dio.get(
      '/api/v1/channels/$channelId/messages',
      queryParameters: {'skip': skip, 'limit': limit},
    );
    final data = response.data;
    if (data is List) {
      return _hydrateChannelMessageDataList(
        channelId,
        data.cast<Map<String, dynamic>>(),
      );
    }
    return [];
  }

  Future<Map<String, dynamic>> postChannelMessage(
    String channelId, {
    required String content,
    String? tempId,
    String? replyToId,
    String? parentId,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  }) async {
    _traceApi('Posting message to channel: $channelId');
    final response = await _dio.post(
      '/api/v1/channels/$channelId/messages/post',
      data: {
        'content': content,
        'temp_id': ?tempId,
        'reply_to_id': ?replyToId,
        'parent_id': ?parentId,
        'data': ?data,
        'meta': ?meta,
      },
    );
    return _hydrateChannelMessageData(
      channelId,
      response.data as Map<String, dynamic>,
    );
  }

  Future<Map<String, dynamic>> updateChannelMessage(
    String channelId,
    String messageId, {
    required String content,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  }) async {
    _traceApi(
      'Updating channel message: '
      '$channelId/$messageId',
    );
    final response = await _dio.post(
      '/api/v1/channels/$channelId/messages'
      '/$messageId/update',
      data: {'content': content, 'data': ?data, 'meta': ?meta},
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> deleteChannelMessage(String channelId, String messageId) async {
    _traceApi(
      'Deleting channel message: '
      '$channelId/$messageId',
    );
    await _dio.delete(
      '/api/v1/channels/$channelId/messages'
      '/$messageId/delete',
    );
  }

  Future<bool> addMessageReaction(
    String channelId,
    String messageId,
    String name,
  ) async {
    _traceApi(
      'Adding reaction to message: '
      '$channelId/$messageId',
    );
    final response = await _dio.post(
      '/api/v1/channels/$channelId/messages'
      '/$messageId/reactions/add',
      data: {'name': name},
    );
    return response.data as bool;
  }

  Future<bool> removeMessageReaction(
    String channelId,
    String messageId,
    String name,
  ) async {
    _traceApi('Removing reaction: $channelId/$messageId');
    final response = await _dio.post(
      '/api/v1/channels/$channelId/messages'
      '/$messageId/reactions/remove',
      data: {'name': name},
    );
    return response.data as bool;
  }

  /// Updates current user's active status in a channel.
  Future<bool> updateMemberActiveStatus(
    String channelId, {
    required bool isActive,
  }) async {
    _traceApi(
      'Updating active status in channel: '
      '$channelId',
    );
    final response = await _dio.post(
      '/api/v1/channels/$channelId/members'
      '/active',
      data: {'is_active': isActive},
    );
    return response.data as bool;
  }

  /// Fetches a single message with thread info and reactions.
  Future<Map<String, dynamic>?> getChannelMessage(
    String channelId,
    String messageId,
  ) async {
    _traceApi('Fetching message: $channelId/$messageId');
    final response = await _dio.get(
      '/api/v1/channels/$channelId/messages'
      '/$messageId',
    );
    final message = response.data as Map<String, dynamic>?;
    if (message == null) return null;
    return _hydrateChannelMessageData(channelId, message);
  }

  /// Fetches thread replies for a message.
  Future<List<Map<String, dynamic>>> getMessageThread(
    String channelId,
    String messageId, {
    int skip = 0,
    int limit = 50,
  }) async {
    _traceApi(
      'Fetching message thread: '
      '$channelId/$messageId',
    );
    final response = await _dio.get(
      '/api/v1/channels/$channelId/messages'
      '/$messageId/thread',
      queryParameters: {'skip': skip, 'limit': limit},
    );
    final data = response.data;
    if (data is List) {
      return _hydrateChannelMessageDataList(
        channelId,
        data.cast<Map<String, dynamic>>(),
      );
    }
    return [];
  }

  /// Pins or unpins a message.
  Future<Map<String, dynamic>?> pinMessage(
    String channelId,
    String messageId, {
    required bool isPinned,
  }) async {
    _traceApi(
      'Pinning message: $channelId/$messageId '
      '($isPinned)',
    );
    final response = await _dio.post(
      '/api/v1/channels/$channelId/messages'
      '/$messageId/pin',
      data: {'is_pinned': isPinned},
    );
    return response.data as Map<String, dynamic>?;
  }

  /// Fetches message data (files, attachments).
  @override
  Future<Map<String, dynamic>?> getMessageData(
    String channelId,
    String messageId,
  ) async {
    _traceApi(
      'Fetching message data: '
      '$channelId/$messageId',
    );
    final response = await _dio.get(
      '/api/v1/channels/$channelId/messages'
      '/$messageId/data',
    );
    return response.data as Map<String, dynamic>?;
  }
}
