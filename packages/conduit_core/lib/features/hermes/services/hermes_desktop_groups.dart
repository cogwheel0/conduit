part of 'hermes_desktop_api_service.dart';

extension _HermesDesktopGroups on HermesDesktopApiService {
  Future<HermesBotGroup> _saveDurableGroup(HermesBotGroup draft) async {
    final repository = HermesGroupRepository(_messagesProfileRequest);
    await repository.assertEditable(draft);
    final capabilities = await groupCapabilities();
    if (capabilities['driver'] != true || draft.hasScopedMembers) {
      return repository.save(draft);
    }
    final stored = (await repository.list())
        .where((g) => g.identity == draft.identity)
        .firstOrNull;
    if (stored != null &&
        draft.raw['revision'] is num &&
        stored.raw['revision'] != draft.raw['revision']) {
      throw StateError(
        'This group changed on another device. Refresh before saving.',
      );
    }
    final native = draft.raw['hostedRoom'];
    final oldProfiles = native is Map && native['members'] is List
        ? {
            for (final m in native['members'] as List)
              if (m is Map) m['profile'],
          }
        : stored?.memberProfiles.toSet();
    final rosterChanged =
        oldProfiles != null &&
        (oldProfiles.length != draft.memberProfiles.length ||
            !oldProfiles.containsAll(draft.memberProfiles));
    if (rosterChanged && draft.previousRooms.length >= 32) {
      throw StateError(
        'This group has reached its membership-change history limit.',
      );
    }
    var next = draft;
    String? replacesKey;
    if (rosterChanged) {
      // The parent room plus desired roster is a stable retry key. Repeating an
      // uncertain save recovers this room instead of creating another one.
      final roster = List<String>.of(draft.memberProfiles)..sort();
      final id =
          'conduit-${sha256.convert(utf8.encode(jsonEncode([draft.identity, roster]))).toString().substring(0, 32)}';
      next = draft.copyWith(
        key: 'id:$id',
        roomId: id,
        memberSessions: const {},
        pendingTurn: const {},
      );
      replacesKey = draft.key;
    }
    final result = !rosterChanged && draft.raw['hosted'] == true
        ? await groupRequest('state', {'room_id': draft.identity})
        : await groupRequest('create', {
            'room_id': next.identity,
            'name': next.name,
            'members': [
              for (final profile in next.memberProfiles)
                {
                  'member_id': profile,
                  'profile': profile,
                  'handle': profile,
                  'display_name': profile,
                  'target': {'kind': 'local', 'profile': profile},
                },
            ],
          });
    if (rosterChanged && draft.raw['hosted'] == true) {
      // Disband fences the old driver's work before capturing its final log.
      // Its log remains readable, including after a metadata-save retry.
      await groupRequest('disband', {'room_id': draft.identity});
      final state = await groupRequest('state', {
        'room_id': draft.identity,
        'include_disbanded': true,
      });
      final oldRoom = _object(state['room']);
      final previous = [
        ...draft.previousRooms,
        {
          'room_id': draft.identity,
          'name': draft.name,
          'members': oldRoom['members'],
        },
      ];
      if (previous.length > 32) {
        throw StateError(
          'This group has reached its membership-change history limit.',
        );
      }
      final history = await _hostedRoomHistory(
        hermesHostedRoom(oldRoom, previous: draft),
      );
      next = next.copyWith(messages: history.messages, previousRooms: previous);
    }
    var updated = hermesHostedRoom(_object(result['room']), previous: next);
    if (updated.name != draft.name) {
      await groupRequest('rename', {
        'room_id': next.identity,
        'event_id':
            'rename-${DateTime.now().microsecondsSinceEpoch}-${sha256.convert(utf8.encode('${next.identity}:${draft.name}'))}',
        'name': draft.name,
      });
      updated = updated.copyWith(name: draft.name);
    }
    return repository.save(updated, replacesKey: replacesKey);
  }

  Future<HermesBotGroup> _hostedRoomHistory(
    HermesBotGroup group, {
    CancelToken? cancelToken,
  }) async {
    var cursor = 0;
    final merged = {for (final m in group.messages) m.id: m};
    while (true) {
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      final page = await groupRequest('log', {
        'room_id': group.identity,
        'since_seq': cursor,
        'limit': 200,
        'include_disbanded': true,
      });
      for (final event in _objects(page['events'])) {
        final message = hermesHostedRoomMessage(event, group);
        if (message != null) merged[message.id] = message;
      }
      final next = page['cursor'];
      if (page['has_more'] != true) break;
      if (next is! int || next <= cursor) {
        throw StateError('Hermes did not advance the group history cursor.');
      }
      cursor = next;
    }
    return group.copyWith(
      messages: merged.values.toList()..sort((a, b) => a.at.compareTo(b.at)),
    );
  }

  Future<({String folder, List<String> paths})> _uploadHostedFiles(
    HermesBotGroup group,
    List<HermesInputFilePart> files,
  ) async {
    final folder =
        group.sharedFolder ??
        '${await botHome('default')}/workspace/groups/${sha256.convert(utf8.encode(group.identity)).toString().substring(0, 32)}';
    if (hermesFilePath(folder) == null) {
      throw ArgumentError('Invalid shared folder');
    }
    try {
      await _filesList(folder, null);
    } on DioException catch (error) {
      if (error.response?.statusCode != 404) rethrow;
      await _requestJson('POST', '/api/files/mkdir', body: {'path': folder});
    }
    final paths = <String>[];
    var total = 0;
    if (files.length > 4) throw ArgumentError('Too many files');
    for (final file in files) {
      final bytes = base64Decode(file.base64Data);
      total += bytes.length;
      if (total > 18 * 1024 * 1024) throw ArgumentError('Files are too large');
      final digest = sha256.convert(bytes).toString();
      final name = file.filename.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final safe = name.substring(0, min(name.length, 120));
      final path = _filesChildPath(folder, '$digest-$safe');
      try {
        await _requestJson(
          'POST',
          '/api/files/upload',
          body: {'path': path, 'data_url': file.dataUrl, 'overwrite': false},
        );
      } on DioException catch (error) {
        if (error.response?.statusCode != 409) rethrow;
        final existing = _object(
          await _requestJson(
            'GET',
            '/api/files/read',
            query: {'path': path},
            maximumResponseBytes: kMaxHermesDesktopFrameBytes,
          ),
        )['data_url'];
        if (existing is! String ||
            sha256
                    .convert(UriData.parse(existing).contentAsBytes())
                    .toString() !=
                digest) {
          throw StateError('A different shared file already uses this name.');
        }
      }
      paths.add(path);
    }
    return (folder: folder, paths: paths);
  }
}
