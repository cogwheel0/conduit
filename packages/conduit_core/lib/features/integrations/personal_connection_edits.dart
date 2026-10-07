/// Edits to a personal connection list, applied to the latest server copy.
///
/// Every edit names its target by identity instead of position, so a list the
/// user opened a while ago still edits the right entry after another client
/// reordered or pruned it. Edits patch only the fields they carry and leave
/// unknown fields, secrets and untouched entries as the server stored them.
library;

import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/utils/json_normalization.dart';

enum PersonalConnectionEditFailure {
  /// The target is no longer in the latest list.
  notFound,

  /// Another entry already has this key or URL.
  duplicate,

  /// The entry lacks what the edit needs, such as a URL or a key.
  invalid,
}

class PersonalConnectionEditException implements Exception {
  const PersonalConnectionEditException(this.failure, [this.detail]);

  final PersonalConnectionEditFailure failure;
  final String? detail;

  @override
  String toString() =>
      'PersonalConnectionEditException(${failure.name}'
      '${detail == null ? '' : ': $detail'})';
}

/// The list after an edit, and where each earlier entry went.
class PersonalConnectionEditResult {
  const PersonalConnectionEditResult({
    required this.list,
    required this.indexMap,
    this.entryIndex,
  });

  final List<dynamic> list;

  /// Index in the earlier list to index in [list]. A removed entry is absent.
  final Map<int, int> indexMap;

  /// Index in [list] of the entry an add or patch produced.
  final int? entryIndex;
}

/// The server did not keep the list that was written, for example because the
/// account lacks the permission that guards it.
class PersonalConnectionsWriteRejected implements Exception {
  const PersonalConnectionsWriteRejected(this.kind);

  final PersonalConnectionKind kind;

  @override
  String toString() => 'PersonalConnectionsWriteRejected(${kind.name})';
}

/// A saved edit, read back from the server's canonical settings.
class PersonalConnectionsWrite {
  const PersonalConnectionsWrite({
    required this.kind,
    required this.before,
    required this.after,
    required this.indexMap,
    required this.settings,
    this.entryIndex,
  });

  final PersonalConnectionKind kind;

  /// The latest list the edit was applied to.
  final List<dynamic> before;

  /// The list the server now returns for [kind].
  final List<dynamic> after;

  /// Index in [before] to index in [after]. A removed entry is absent.
  final Map<int, int> indexMap;

  /// The full settings document the server returned.
  final Map<String, dynamic> settings;

  final int? entryIndex;
}

/// Identity that names the entry at [index] across list changes.
String personalConnectionIdentity(
  PersonalConnectionKind kind,
  List<dynamic> list,
  int index,
) {
  final entry = personalConnectionMap(list[index]) ?? const {};
  return switch (kind) {
    PersonalConnectionKind.toolServer => personalToolServerSelectionId(
      list,
      index,
    ).substring(kDirectServerSelectionPrefix.length),
    PersonalConnectionKind.terminal => personalTerminalIdentity(entry),
  };
}

/// Index of the entry [identity] names in [list], or null.
int? indexOfPersonalConnection(
  PersonalConnectionKind kind,
  List<dynamic> list,
  String identity,
) {
  switch (kind) {
    case PersonalConnectionKind.toolServer:
      return resolvePersonalToolServerToken(list, identity);
    case PersonalConnectionKind.terminal:
      for (var index = 0; index < list.length; index++) {
        final entry = personalConnectionMap(list[index]);
        if (entry != null && personalTerminalIdentity(entry) == identity) {
          return index;
        }
      }
      return null;
  }
}

/// Applies a JSON merge patch: a null value removes the key, a map merges into
/// the existing map, and any other value replaces it.
Map<String, dynamic> mergePersonalConnectionPatch(
  Map<String, dynamic> target,
  Map<String, dynamic> patch,
) {
  final merged = normalizeJsonLikeMap(target);
  patch.forEach((key, value) {
    if (value == null) {
      merged.remove(key);
    } else if (value is Map) {
      final current = merged[key];
      merged[key] = mergePersonalConnectionPatch(
        current is Map ? normalizeJsonLikeMap(current) : <String, dynamic>{},
        normalizeJsonLikeMap(value),
      );
    } else {
      merged[key] = normalizeJsonLikeValue(value);
    }
  });
  return merged;
}

sealed class PersonalConnectionEdit {
  const PersonalConnectionEdit();

  PersonalConnectionEditResult apply(
    PersonalConnectionKind kind,
    List<dynamic> latest,
  );
}

List<dynamic> _copy(List<dynamic> list) => <dynamic>[
  for (final item in list) normalizeJsonLikeValue(item),
];

Map<int, int> _identityMap(int length) => <int, int>{
  for (var index = 0; index < length; index++) index: index,
};

int _requireIndex(
  PersonalConnectionKind kind,
  List<dynamic> list,
  String identity,
) =>
    indexOfPersonalConnection(kind, list, identity) ??
    (throw const PersonalConnectionEditException(
      PersonalConnectionEditFailure.notFound,
    ));

/// Open WebUI keeps one terminal switched on. Turning one on turns the rest
/// off, which is what the reference editor does when it enables a terminal.
void _enforceSingleTerminal(List<dynamic> list, int enabledIndex) {
  for (var index = 0; index < list.length; index++) {
    if (index == enabledIndex) continue;
    final entry = list[index];
    if (entry is Map<String, dynamic> && entry['enabled'] == true) {
      entry['enabled'] = false;
    }
  }
}

String? _ownIdentity(PersonalConnectionKind kind, Map<String, dynamic> entry) =>
    switch (kind) {
      PersonalConnectionKind.toolServer => personalToolServerKey(entry),
      PersonalConnectionKind.terminal => personalTerminalIdentity(entry),
    };

void _requireUnique(
  PersonalConnectionKind kind,
  List<dynamic> list,
  int index,
) {
  final entry = personalConnectionMap(list[index])!;
  final own = _ownIdentity(kind, entry);
  if (own == null || own.isEmpty) {
    throw const PersonalConnectionEditException(
      PersonalConnectionEditFailure.invalid,
      'missing identity',
    );
  }
  for (var other = 0; other < list.length; other++) {
    if (other == index) continue;
    final candidate = personalConnectionMap(list[other]);
    if (candidate == null) continue;
    if (_ownIdentity(kind, candidate) == own) {
      throw PersonalConnectionEditException(
        PersonalConnectionEditFailure.duplicate,
        own,
      );
    }
  }
}

/// Appends [entry]. Tool servers must already carry a key and terminals a URL.
final class AddPersonalConnection extends PersonalConnectionEdit {
  const AddPersonalConnection(this.entry);

  final Map<String, dynamic> entry;

  @override
  PersonalConnectionEditResult apply(
    PersonalConnectionKind kind,
    List<dynamic> latest,
  ) {
    final list = _copy(latest)..add(normalizeJsonLikeMap(entry));
    final index = list.length - 1;
    _requireUnique(kind, list, index);
    if (kind == PersonalConnectionKind.terminal &&
        personalConnectionMap(list[index])!['enabled'] == true) {
      _enforceSingleTerminal(list, index);
    }
    return PersonalConnectionEditResult(
      list: list,
      indexMap: _identityMap(latest.length),
      entryIndex: index,
    );
  }
}

/// Merges [patch] into the entry [identity] names.
///
/// [stampKey] is written to a keyless tool server so the entry gains an
/// identity that outlives later list changes.
final class PatchPersonalConnection extends PersonalConnectionEdit {
  const PatchPersonalConnection(this.identity, this.patch, {this.stampKey});

  final String identity;
  final Map<String, dynamic> patch;
  final String? stampKey;

  @override
  PersonalConnectionEditResult apply(
    PersonalConnectionKind kind,
    List<dynamic> latest,
  ) {
    final index = _requireIndex(kind, latest, identity);
    final list = _copy(latest);
    final current = personalConnectionMap(list[index])!;
    var merged = mergePersonalConnectionPatch(current, patch);
    if (kind == PersonalConnectionKind.toolServer &&
        stampKey != null &&
        personalToolServerKey(merged) == null) {
      merged = mergePersonalConnectionPatch(merged, <String, dynamic>{
        'info': <String, dynamic>{'id': stampKey},
      });
    }
    list[index] = merged;
    // Entries the server already holds may share an identity; only an edit
    // that changes the identity has to keep it unique.
    if (_ownIdentity(kind, merged) != _ownIdentity(kind, current)) {
      _requireUnique(kind, list, index);
    }
    if (kind == PersonalConnectionKind.terminal && merged['enabled'] == true) {
      _enforceSingleTerminal(list, index);
    }
    return PersonalConnectionEditResult(
      list: list,
      indexMap: _identityMap(latest.length),
      entryIndex: index,
    );
  }
}

final class RemovePersonalConnection extends PersonalConnectionEdit {
  const RemovePersonalConnection(this.identity);

  final String identity;

  @override
  PersonalConnectionEditResult apply(
    PersonalConnectionKind kind,
    List<dynamic> latest,
  ) {
    final removed = _requireIndex(kind, latest, identity);
    final list = _copy(latest)..removeAt(removed);
    return PersonalConnectionEditResult(
      list: list,
      indexMap: <int, int>{
        for (var index = 0; index < latest.length; index++)
          if (index < removed)
            index: index
          else if (index > removed)
            index: index - 1,
      },
    );
  }
}

/// Switches an entry on or off without touching its other fields.
final class SetPersonalConnectionEnabled extends PersonalConnectionEdit {
  const SetPersonalConnectionEnabled(this.identity, this.enabled);

  final String identity;
  final bool enabled;

  @override
  PersonalConnectionEditResult apply(
    PersonalConnectionKind kind,
    List<dynamic> latest,
  ) {
    final index = _requireIndex(kind, latest, identity);
    final list = _copy(latest);
    final patch = switch (kind) {
      PersonalConnectionKind.toolServer => <String, dynamic>{
        'config': <String, dynamic>{'enable': enabled},
      },
      PersonalConnectionKind.terminal => <String, dynamic>{'enabled': enabled},
    };
    list[index] = mergePersonalConnectionPatch(
      personalConnectionMap(list[index])!,
      patch,
    );
    if (kind == PersonalConnectionKind.terminal && enabled) {
      _enforceSingleTerminal(list, index);
    }
    return PersonalConnectionEditResult(
      list: list,
      indexMap: _identityMap(latest.length),
      entryIndex: index,
    );
  }
}
