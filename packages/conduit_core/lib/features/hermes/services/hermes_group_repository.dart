import 'dart:convert';

import '../models/hermes_bot_group.dart';

typedef HermesProfileRequest = Future<Map<String, dynamic>> Function(
  String method,
  Map<String, dynamic> parameters,
);

/// Shares Hermes desktop's version-3 room snapshot, using its revision guard.
/// Conduit-only coordination/session options have their own metadata namespace.
class HermesGroupRepository {
  const HermesGroupRepository(this.request);
  final HermesProfileRequest request;
  Future<void> assertEditable(HermesBotGroup group) async {
    final profile = await _profile();
    final snapshot = _namespace(profile, hermesGroupsNamespace);
    final deleted = snapshot['deleted'];
    if (deleted is Map && deleted.containsKey(group.key)) {
      throw StateError(
        'This group was replaced or removed on another device. Refresh before saving.',
      );
    }
    final previous = _rooms(snapshot)[group.key];
    if (previous is Map &&
        group.raw['revision'] is num &&
        previous['revision'] != group.raw['revision']) {
      throw StateError(
        'This group changed on another device. Refresh before saving.',
      );
    }
  }

  Future<void> remove(HermesBotGroup group) async {
    final profile = await _profile();
    final revisions = profile['ui_meta_revisions'];
    if (revisions is! Map) {
      throw UnsupportedError('Update Hermes to safely remove groups.');
    }
    final snapshot = _namespace(profile, hermesGroupsNamespace);
    final rooms = _rooms(snapshot)..remove(group.key);
    final deleted = snapshot['deleted'] is Map
        ? Map<String, dynamic>.from(snapshot['deleted'])
        : <String, dynamic>{};
    final revision = (revisions[hermesGroupsNamespace] as num?)?.toInt() ?? 0;
    deleted[group.key] = revision + 1;
    final options = _namespace(profile, conduitGroupOptionsNamespace)
      ..remove(group.key);
    final result = await request('profiles.configure', {
      'name': 'default',
      'profile': 'default',
      'ui_meta': {
        hermesGroupsNamespace: {
          ...snapshot,
          'version': 3,
          'rooms': rooms,
          'deleted': deleted,
        },
        conduitGroupOptionsNamespace: options,
      },
      'ui_meta_expected_revisions': {
        hermesGroupsNamespace: revision,
        conduitGroupOptionsNamespace:
            revisions[conduitGroupOptionsNamespace] ?? 0,
      },
    });
    final applied = result['applied'];
    if (applied is! Map ||
        applied['ui_meta'] != true ||
        applied['ui_meta_revisions'] is! Map ||
        applied['ui_meta_revisions'][hermesGroupsNamespace] != revision + 1) {
      throw StateError(
        'Hermes did not confirm removing the group. Refresh before retrying.',
      );
    }
  }

  Future<Map<String, dynamic>> _profile() async {
    final result = await request('profiles.list', {
      'include_sessions': false,
      'profile': 'default',
    });
    if (result['bot_mode_protocol'] != true) {
      throw UnsupportedError('This Hermes gateway does not support Bot Mode.');
    }
    final rows = result['profiles'];
    if (rows is List) {
      for (final row in rows) {
        if (row is Map && row['name'] == 'default') {
          return Map<String, dynamic>.from(row);
        }
      }
    }
    throw StateError('Hermes default profile is unavailable.');
  }

  Map<String, dynamic> _namespace(Map<String, dynamic> profile, String key) {
    final meta = profile['ui_meta'];
    final value = meta is Map ? meta[key] : null;
    if (value is! Map) return {};
    final snapshot = Map<String, dynamic>.from(value);
    if (key != hermesGroupsNamespace ||
        (snapshot['version'] as num? ?? 0) >= 3) {
      return snapshot;
    }
    // Same migration as Hermes desktop: old rooms use their names as keys.
    return {
      ...snapshot,
      'version': 3,
      'rooms': {
        for (final entry in _rooms(snapshot).entries)
          'name:${entry.key}': {...entry.value as Map, 'name': entry.key},
      },
      'deleted': {
        if (snapshot['deleted'] is Map)
          for (final entry in (snapshot['deleted'] as Map).entries)
            'name:${entry.key}': (snapshot['version'] as num? ?? 0) >= 2
                ? entry.value
                : 0,
      },
    };
  }

  Map<String, dynamic> _rooms(Map<String, dynamic> snapshot) {
    final rooms = snapshot['rooms'];
    if (rooms is! Map) return {};
    return {
      for (final entry in rooms.entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: Map<String, dynamic>.from(entry.value as Map),
    };
  }

  Future<List<HermesBotGroup>> list() async {
    final profile = await _profile();
    final snapshot = _namespace(profile, hermesGroupsNamespace);
    final options = _namespace(profile, conduitGroupOptionsNamespace);
    final result = <HermesBotGroup>[];
    for (final entry in _rooms(snapshot).entries) {
      final raw = options[entry.key];
      final group = HermesBotGroup.fromJson(
        entry.key,
        entry.value as Map<String, dynamic>,
        raw is Map ? Map<String, dynamic>.from(raw) : {},
      );
      if (group != null) result.add(group);
    }
    result.sort(
      (a, b) => (b.lastActive ?? DateTime(1970)).compareTo(
        a.lastActive ?? DateTime(1970),
      ),
    );
    return result;
  }

  Future<HermesBotGroup> save(
    HermesBotGroup group, {
    String? replacesKey,
  }) async {
    if (group.name.trim().isEmpty ||
        group.name.length > 64 ||
        group.memberProfiles.length < 2 ||
        group.memberProfiles.length > 6) {
      throw ArgumentError('A group requires a name and 2–6 bots.');
    }
    // Re-read immediately before writing. Revisions reject a concurrent writer;
    // never retry an uncertain mutation or overwrite another device's changes.
    final profile = await _profile();
    final revisions = profile['ui_meta_revisions'];
    if (revisions is! Map) {
      throw UnsupportedError(
        'Update Hermes to enable safe group synchronization.',
      );
    }
    final snapshot = _namespace(profile, hermesGroupsNamespace);
    final rooms = _rooms(snapshot);
    final previous = rooms[replacesKey ?? group.key];
    if (previous is Map &&
        group.raw['revision'] is num &&
        previous['revision'] != group.raw['revision']) {
      throw StateError(
        'This group changed on another device. Refresh before saving.',
      );
    }
    final deleted = snapshot['deleted'] is Map
        ? Map<String, dynamic>.from(snapshot['deleted'])
        : <String, dynamic>{};
    if (deleted.containsKey(group.key)) {
      throw StateError('This group was removed on another device.');
    }
    final merged = <String, HermesGroupMessage>{};
    if (previous is Map) {
      final remote = HermesBotGroup.fromJson(
        group.key,
        Map<String, dynamic>.from(previous),
        {},
      );
      for (final message in remote?.messages ?? <HermesGroupMessage>[]) {
        merged[message.id] = message;
      }
    }
    for (final message in group.messages) {
      merged[message.id] = message;
    }
    final log = merged.values.toList()..sort((a, b) => a.at.compareTo(b.at));
    final updated = group.copyWith(messages: log);
    final room = updated.roomJson();
    final revision = (revisions[hermesGroupsNamespace] as num?)?.toInt() ?? 0;
    room['revision'] = revision + 1;
    // Hermes desktop syncs the newest 16 entries and bounds the whole snapshot.
    // Full Conduit history is archived separately on this device.
    room['log'] = log.skip(log.length > 16 ? log.length - 16 : 0).map((m) {
      final row = m.toJson(includeTools: false);
      if (m.text.length > 1200) {
        row['text'] = '${m.text.substring(0, 1180)}… [truncated]';
        row['truncated'] = true;
      }
      return row;
    }).toList();
    room['omitted'] = group.omitted + (log.length > 16 ? log.length - 16 : 0);
    if (replacesKey != null && replacesKey != group.key) {
      rooms.remove(replacesKey);
      deleted[replacesKey] = revision + 1;
    }
    rooms[group.key] = room;
    final next = {
      ...snapshot,
      'version': 3,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'rooms': rooms,
      'deleted': deleted,
    };
    if (jsonEncode(next).runes.fold<int>(
          0,
          (size, rune) =>
              size +
              (rune <= 127
                  ? (rune == 44 || rune == 58 ? 2 : 1)
                  : rune <= 65535
                  ? 6
                  : 12),
        ) >
        48000) {
      throw StateError(
        'Hermes group storage is full. Reduce this group history or remove an old group in Hermes.',
      );
    }
    final options = _namespace(profile, conduitGroupOptionsNamespace)
      ..[group.key] = group.optionsJson();
    if (replacesKey != null && replacesKey != group.key) {
      options.remove(replacesKey);
    }
    final response = await request('profiles.configure', {
      'name': 'default',
      'profile': 'default',
      'ui_meta': {
        hermesGroupsNamespace: next,
        conduitGroupOptionsNamespace: options,
      },
      'ui_meta_expected_revisions': {
        hermesGroupsNamespace: revision,
        conduitGroupOptionsNamespace:
            (revisions[conduitGroupOptionsNamespace] as num?)?.toInt() ?? 0,
      },
    });
    final applied = response['applied'];
    if (applied is! Map || applied['ui_meta'] != true) {
      throw StateError('Hermes did not save the group. Refresh and try again.');
    }
    final advanced = applied['ui_meta_revisions'];
    final optionsRevision =
        (revisions[conduitGroupOptionsNamespace] as num?)?.toInt() ?? 0;
    if (advanced is! Map ||
        advanced[hermesGroupsNamespace] != revision + 1 ||
        advanced[conduitGroupOptionsNamespace] != optionsRevision + 1) {
      throw StateError(
        'Hermes did not confirm the group revisions. Refresh before retrying.',
      );
    }
    return updated.copyWith(raw: room);
  }
}
