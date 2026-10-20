/// Personal Open WebUI tool-server and terminal connections stored in the
/// user's settings document.
///
/// Open WebUI 0.11.4 saves these lists under `ui.toolServers` and
/// `ui.terminalServers`. Older clients (including earlier Conduit builds) also
/// wrote them at the document root, and the server never removes a root key
/// that a later `ui` write omits. A present `ui` list therefore wins, even when
/// it is empty, and the root list is only a fallback for when `ui` has none.
library;

import 'dart:convert';

import 'package:conduit_core/utils/json_normalization.dart';

/// Prefix of the chat selection ids that name a personal tool server.
const String kDirectServerSelectionPrefix = 'direct_server:';

enum PersonalConnectionKind {
  toolServer('toolServers'),
  terminal('terminalServers');

  const PersonalConnectionKind(this.settingsKey);

  /// Key of the list inside `ui` (and, for legacy data, the document root).
  final String settingsKey;
}

/// Route path segment for [kind] in the personal connection editor.
String personalConnectionKindRouteValue(PersonalConnectionKind kind) =>
    kind == PersonalConnectionKind.toolServer ? 'tool' : 'terminal';

PersonalConnectionKind? personalConnectionKindFromRouteValue(String value) =>
    switch (value) {
      'tool' => PersonalConnectionKind.toolServer,
      'terminal' => PersonalConnectionKind.terminal,
      _ => null,
    };

/// Route value that opens the editor for a connection that does not exist yet.
const String personalConnectionNewRouteValue = '__new__';

/// The list consumers should read for [key].
///
/// A list under `ui` always wins, including an empty one. The root list is
/// returned only when `ui` has no list for [key].
List<dynamic> effectivePersonalServerList(
  Map<String, dynamic>? settings,
  String key,
) {
  if (settings == null || settings.isEmpty) {
    return const <dynamic>[];
  }
  final ui = settings['ui'];
  if (ui is Map && ui[key] is List) {
    return ui[key] as List<dynamic>;
  }
  final root = settings[key];
  if (root is List) {
    return root;
  }
  return const <dynamic>[];
}

/// Writes [value] into the namespace [effectivePersonalServerList] reads from:
/// `ui` when it holds a list for [key], otherwise the root list that exists,
/// otherwise `ui`.
void writeEffectivePersonalServerList(
  Map<String, dynamic> settings,
  String key,
  List<dynamic> value,
) {
  final ui = settings['ui'];
  if (ui is Map && ui[key] is List) {
    ui[key] = value;
    return;
  }
  if (settings[key] is List) {
    settings[key] = value;
    return;
  }
  final nextUi = ui is Map ? normalizeJsonLikeMap(ui) : <String, dynamic>{};
  nextUi[key] = value;
  settings['ui'] = nextUi;
}

Map<String, dynamic>? personalConnectionMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return normalizeJsonLikeMap(value);
  return null;
}

String _text(Object? value) => value?.toString().trim() ?? '';

/// Name shown for an entry, or an empty string when it has no label.
String personalConnectionName(Map<String, dynamic> entry) {
  final info = personalConnectionMap(entry['info']);
  for (final candidate in <Object?>[
    entry['name'],
    info?['name'],
    entry['title'],
    info?['title'],
  ]) {
    final text = _text(candidate);
    if (text.isNotEmpty) return text;
  }
  return '';
}

String personalConnectionUrl(Map<String, dynamic> entry) =>
    _text(entry['url']).replaceFirst(RegExp(r'/+$'), '');

/// Whether the reference client treats the entry as switched on.
///
/// Tool servers carry `config.enable`; terminals carry `enabled`.
bool personalConnectionEnabled(
  Map<String, dynamic> entry, {
  required PersonalConnectionKind kind,
}) {
  final config = entry['config'];
  if (config is Map && config.containsKey('enable')) {
    return config['enable'] == true;
  }
  final enabled = entry['enabled'];
  if (enabled is bool) return enabled;
  return kind == PersonalConnectionKind.toolServer;
}

/// Identity that survives reordering: the entry's own `id`, else the `id` the
/// reference editor stores under `info`. Null for entries that never had one.
String? personalToolServerKey(Map<String, dynamic> entry) {
  final topLevel = _text(entry['id']);
  if (topLevel.isNotEmpty) return topLevel;
  final infoId = _text(personalConnectionMap(entry['info'])?['id']);
  return infoId.isEmpty ? null : infoId;
}

/// Short non-secret digest of the fields that tell two keyless entries apart.
String personalToolServerFingerprint(Map<String, dynamic> entry) {
  final material = <String>[
    personalConnectionUrl(entry),
    _text(entry['path']),
    personalConnectionName(entry),
    _text(entry['spec_type']),
  ].join('\u0000');
  // 32-bit FNV-1a. It only has to tell entries apart across list edits, so a
  // stable cheap digest is enough and no secret goes into the id.
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(material)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// Selection id for the tool server at [index].
///
/// Keyed entries use their key. Keyless entries use their position plus a
/// fingerprint, so a list change that moves the entry cannot make the old
/// position select another server.
String personalToolServerSelectionId(List<dynamic> servers, int index) {
  final entry = personalConnectionMap(servers[index]) ?? const {};
  final key = personalToolServerKey(entry);
  if (key != null) return '$kDirectServerSelectionPrefix$key';
  return '$kDirectServerSelectionPrefix$index~'
      '${personalToolServerFingerprint(entry)}';
}

final RegExp _positionalSelection = RegExp(r'^(\d+)(?:~([0-9a-f]{8}))?$');

/// Name to show for a selection whose server can no longer be looked up: the
/// key for a keyed selection, or an empty string for a positional one, which
/// has no readable name.
String personalToolSelectionLabel(String id) {
  final token = id.startsWith(kDirectServerSelectionPrefix)
      ? id.substring(kDirectServerSelectionPrefix.length)
      : id;
  return _positionalSelection.hasMatch(token) ? '' : token;
}

/// Index of the server named by the selection [token] (the part after
/// [kDirectServerSelectionPrefix]), or null when no current entry matches.
///
/// A key matches only the entry that has that key. A position with a
/// fingerprint matches the keyless entry carrying that fingerprint, searching
/// from the recorded position, and never an entry whose fingerprint differs.
///
/// A bare position, which builds before this one wrote, names no one: once the
/// list has been replaced nothing shows which server it was taken from, and
/// the keyless entry now at that position may be a different server. It
/// resolves to nothing, so the selection is cleared and made again.
int? resolvePersonalToolServerToken(List<dynamic> servers, String token) {
  final wanted = token.trim();
  if (wanted.isEmpty) return null;

  final entries = <Map<String, dynamic>?>[
    for (final server in servers) personalConnectionMap(server),
  ];
  for (var index = 0; index < entries.length; index++) {
    final entry = entries[index];
    if (entry != null && personalToolServerKey(entry) == wanted) return index;
  }

  final positional = _positionalSelection.firstMatch(wanted);
  final fingerprint = positional?.group(2);
  if (positional == null || fingerprint == null) return null;
  final position = int.parse(positional.group(1)!);

  bool keyless(int index) =>
      entries[index] != null && personalToolServerKey(entries[index]!) == null;

  if (position < entries.length &&
      keyless(position) &&
      personalToolServerFingerprint(entries[position]!) == fingerprint) {
    return position;
  }
  for (var index = 0; index < entries.length; index++) {
    if (keyless(index) &&
        personalToolServerFingerprint(entries[index]!) == fingerprint) {
      return index;
    }
  }
  return null;
}

/// How a set of chat selection ids lines up with the current tool servers.
class PersonalToolSelectionResolution {
  const PersonalToolSelectionResolution({
    required this.matchedIndices,
    required this.unresolvedIds,
  });

  /// Indices of the servers the selections name, ascending and distinct.
  final List<int> matchedIndices;

  /// `direct_server:` ids that name no current entry.
  final List<String> unresolvedIds;
}

PersonalToolSelectionResolution resolvePersonalToolSelections(
  List<dynamic> servers,
  Iterable<String> selectedIds,
) {
  final matched = <int>{};
  final unresolved = <String>[];
  for (final id in selectedIds) {
    if (!id.startsWith(kDirectServerSelectionPrefix)) continue;
    final index = resolvePersonalToolServerToken(
      servers,
      id.substring(kDirectServerSelectionPrefix.length),
    );
    if (index == null) {
      unresolved.add(id);
    } else {
      matched.add(index);
    }
  }
  return PersonalToolSelectionResolution(
    matchedIndices: matched.toList()..sort(),
    unresolvedIds: unresolved,
  );
}

/// Selection ids after the tool-server list changed from [before] to [after].
class PersonalToolSelectionReconciliation {
  const PersonalToolSelectionReconciliation({
    required this.selectedIds,
    required this.clearedNames,
  });

  final List<String> selectedIds;

  /// Display names of selections that no longer name a server.
  final List<String> clearedNames;
}

/// Carries `direct_server:` selections across a list edit.
///
/// [indexMap] maps an index in [before] to its index in [after]; an index
/// missing from the map was removed. A selection follows its entry to the new
/// index, or is cleared when the entry is gone or never resolved. Other
/// selections pass through unchanged.
PersonalToolSelectionReconciliation reconcilePersonalToolSelections({
  required List<dynamic> before,
  required List<dynamic> after,
  required Map<int, int> indexMap,
  required Iterable<String> selectedIds,
}) {
  final next = <String>[];
  final cleared = <String>[];
  for (final id in selectedIds) {
    if (!id.startsWith(kDirectServerSelectionPrefix)) {
      next.add(id);
      continue;
    }
    final oldIndex = resolvePersonalToolServerToken(
      before,
      id.substring(kDirectServerSelectionPrefix.length),
    );
    final newIndex = oldIndex == null ? null : indexMap[oldIndex];
    if (oldIndex == null || newIndex == null) {
      final entry = oldIndex == null
          ? null
          : personalConnectionMap(before[oldIndex]);
      cleared.add(
        entry == null
            ? personalToolSelectionLabel(id)
            : personalConnectionDisplayName(entry),
      );
      continue;
    }
    final replacement = personalToolServerSelectionId(after, newIndex);
    if (!next.contains(replacement)) next.add(replacement);
  }
  return PersonalToolSelectionReconciliation(
    selectedIds: next,
    clearedNames: cleared,
  );
}

/// Name shown in lists and notices for [entry].
String personalConnectionDisplayName(Map<String, dynamic> entry) {
  final name = personalConnectionName(entry);
  if (name.isNotEmpty) return name;
  final url = personalConnectionUrl(entry);
  return url.isNotEmpty ? url : _text(personalToolServerKey(entry));
}

/// Identity of a terminal: its URL, which is also the chat selection id.
String personalTerminalIdentity(Map<String, dynamic> entry) =>
    _text(entry['url']);
