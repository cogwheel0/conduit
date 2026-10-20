/// Form state for a personal connection and the entries and patches it
/// produces, shaped like the ones Open WebUI's own settings screen saves.
library;

import 'dart:convert';

import 'package:conduit_core/features/integrations/personal_connection_settings.dart';

/// What a form does to the credential the server already stores.
enum PersonalConnectionSecretMode {
  /// Leave the stored credential as it is. The form never sees its value.
  keep,

  /// Store the value the user typed.
  replace,

  /// Store an empty credential.
  clear,
}

enum PersonalConnectionDraftIssue {
  urlRequired,
  urlInvalid,
  pathRequired,
  specInvalid,
}

/// How much of an entry the editor understands.
///
/// Entries it cannot edit stay in the list and can still be switched or
/// deleted, but their fields are never rewritten.
bool personalConnectionIsEditable(
  PersonalConnectionKind kind,
  Map<String, dynamic> entry,
) {
  final authType = entry['auth_type']?.toString().trim() ?? '';
  switch (kind) {
    case PersonalConnectionKind.terminal:
      return authType.isEmpty || authType == 'bearer';
    case PersonalConnectionKind.toolServer:
      final type = entry['type']?.toString().trim() ?? '';
      final specType = entry['spec_type']?.toString().trim() ?? '';
      return (authType.isEmpty || authType == 'bearer' || authType == 'none') &&
          (type.isEmpty || type == 'openapi') &&
          (specType.isEmpty || specType == 'url' || specType == 'json');
  }
}

PersonalConnectionDraftIssue? _urlIssue(String url) {
  if (url.isEmpty) return PersonalConnectionDraftIssue.urlRequired;
  final uri = Uri.tryParse(url);
  if (uri == null ||
      !uri.hasAuthority ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return PersonalConnectionDraftIssue.urlInvalid;
  }
  return null;
}

String _clean(String? value) => value?.trim() ?? '';

String _stripTrailingSlash(String value) =>
    value.replaceFirst(RegExp(r'/+$'), '');

/// Writes [value] into [patch] only when it differs from what the entry
/// stores, treating a missing field as [fallback].
void _setIfChanged(
  Map<String, dynamic> patch,
  Map<String, dynamic> previous,
  String key,
  String value, {
  String fallback = '',
}) {
  final stored = previous[key]?.toString() ?? fallback;
  if (stored != value) patch[key] = value;
}

class PersonalToolServerDraft {
  const PersonalToolServerDraft({
    this.name = '',
    this.description = '',
    this.url = '',
    this.specType = 'url',
    this.path = 'openapi.json',
    this.spec = '',
    this.authType = 'bearer',
    this.key = '',
    this.keyMode = PersonalConnectionSecretMode.replace,
    this.enabled = true,
  });

  /// Draft for editing [entry]. Its stored key is not copied in.
  factory PersonalToolServerDraft.fromEntry(Map<String, dynamic> entry) {
    final info = personalConnectionMap(entry['info']);
    final config = personalConnectionMap(entry['config']);
    final authType = entry['auth_type']?.toString().trim() ?? '';
    return PersonalToolServerDraft(
      name: info?['name']?.toString() ?? '',
      description: info?['description']?.toString() ?? '',
      url: entry['url']?.toString() ?? '',
      specType: (entry['spec_type']?.toString().trim() ?? '') == 'json'
          ? 'json'
          : 'url',
      path: entry['path']?.toString() ?? '',
      spec: entry['spec']?.toString() ?? '',
      authType: authType.isEmpty ? 'bearer' : authType,
      keyMode: PersonalConnectionSecretMode.keep,
      enabled: config?['enable'] != false,
    );
  }

  final String name;
  final String description;
  final String url;

  /// `url` fetches the document from [path]; `json` uses [spec] inline.
  final String specType;
  final String path;
  final String spec;

  /// `bearer` or `none`.
  final String authType;
  final String key;
  final PersonalConnectionSecretMode keyMode;
  final bool enabled;

  PersonalToolServerDraft copyWith({
    String? name,
    String? description,
    String? url,
    String? specType,
    String? path,
    String? spec,
    String? authType,
    String? key,
    PersonalConnectionSecretMode? keyMode,
    bool? enabled,
  }) => PersonalToolServerDraft(
    name: name ?? this.name,
    description: description ?? this.description,
    url: url ?? this.url,
    specType: specType ?? this.specType,
    path: path ?? this.path,
    spec: spec ?? this.spec,
    authType: authType ?? this.authType,
    key: key ?? this.key,
    keyMode: keyMode ?? this.keyMode,
    enabled: enabled ?? this.enabled,
  );

  /// The first problem that stops this draft from being saved, or null.
  PersonalConnectionDraftIssue? validate() {
    final urlIssue = _urlIssue(_stripTrailingSlash(_clean(url)));
    if (urlIssue != null) return urlIssue;
    if (specType == 'json') {
      try {
        final decoded = jsonDecode(spec);
        if (decoded is! Map || decoded['paths'] is! Map) {
          return PersonalConnectionDraftIssue.specInvalid;
        }
      } on FormatException {
        return PersonalConnectionDraftIssue.specInvalid;
      }
    } else if (_clean(path).isEmpty) {
      return PersonalConnectionDraftIssue.pathRequired;
    }
    return null;
  }

  String get _effectiveKey =>
      authType == 'none' || keyMode == PersonalConnectionSecretMode.clear
      ? ''
      : key.trim();

  /// A new entry with the shape the reference editor saves for a personal
  /// connection. [id] becomes its stable identity.
  Map<String, dynamic> toNewEntry({required String id}) => <String, dynamic>{
    'type': 'openapi',
    'url': _stripTrailingSlash(_clean(url)),
    'spec_type': specType,
    'spec': specType == 'json' ? spec : '',
    'path': _clean(path),
    'auth_type': authType,
    'key': _effectiveKey,
    'config': <String, dynamic>{
      'enable': enabled,
      'function_name_filter_list': '',
      'access_grants': <dynamic>[],
    },
    'info': <String, dynamic>{
      'id': id,
      'name': _clean(name),
      'description': _clean(description),
    },
  };

  /// The merge patch that turns [previous] into this draft. Only changed
  /// fields appear, and the key appears only when the draft replaces or clears
  /// it.
  Map<String, dynamic> toPatch(Map<String, dynamic> previous) {
    final patch = <String, dynamic>{};
    final info = <String, dynamic>{};
    final previousInfo = personalConnectionMap(previous['info']) ?? const {};
    _setIfChanged(info, previousInfo, 'name', _clean(name));
    _setIfChanged(info, previousInfo, 'description', _clean(description));
    if (info.isNotEmpty) patch['info'] = info;

    _setIfChanged(patch, previous, 'url', _stripTrailingSlash(_clean(url)));
    _setIfChanged(
      patch,
      previous,
      'spec_type',
      specType,
      fallback: specType == 'url' ? 'url' : '',
    );
    _setIfChanged(patch, previous, 'path', _clean(path));
    _setIfChanged(patch, previous, 'spec', specType == 'json' ? spec : '');
    _setIfChanged(
      patch,
      previous,
      'auth_type',
      authType,
      fallback: authType == 'bearer' ? 'bearer' : '',
    );

    final previousConfig = personalConnectionMap(previous['config']);
    if ((previousConfig?['enable'] != false) != enabled ||
        previousConfig?.containsKey('enable') != true) {
      patch['config'] = <String, dynamic>{'enable': enabled};
    }

    if (authType == 'none') {
      if ((previous['key']?.toString() ?? '').isNotEmpty) patch['key'] = '';
    } else if (keyMode == PersonalConnectionSecretMode.replace) {
      patch['key'] = key.trim();
    } else if (keyMode == PersonalConnectionSecretMode.clear) {
      patch['key'] = '';
    }
    return patch;
  }
}

class PersonalTerminalDraft {
  const PersonalTerminalDraft({
    this.name = '',
    this.url = '',
    this.path = '/openapi.json',
    this.key = '',
    this.keyMode = PersonalConnectionSecretMode.replace,
    this.enabled = false,
  });

  factory PersonalTerminalDraft.fromEntry(Map<String, dynamic> entry) =>
      PersonalTerminalDraft(
        name: entry['name']?.toString() ?? '',
        url: entry['url']?.toString() ?? '',
        path: entry['path']?.toString() ?? '/openapi.json',
        keyMode: PersonalConnectionSecretMode.keep,
        enabled: entry['enabled'] == true,
      );

  final String name;
  final String url;
  final String path;
  final String key;
  final PersonalConnectionSecretMode keyMode;
  final bool enabled;

  PersonalTerminalDraft copyWith({
    String? name,
    String? url,
    String? path,
    String? key,
    PersonalConnectionSecretMode? keyMode,
    bool? enabled,
  }) => PersonalTerminalDraft(
    name: name ?? this.name,
    url: url ?? this.url,
    path: path ?? this.path,
    key: key ?? this.key,
    keyMode: keyMode ?? this.keyMode,
    enabled: enabled ?? this.enabled,
  );

  PersonalConnectionDraftIssue? validate() {
    final urlIssue = _urlIssue(_stripTrailingSlash(_clean(url)));
    if (urlIssue != null) return urlIssue;
    if (_clean(path).isEmpty) return PersonalConnectionDraftIssue.pathRequired;
    return null;
  }

  Map<String, dynamic> toNewEntry() => <String, dynamic>{
    'url': _stripTrailingSlash(_clean(url)),
    'key': keyMode == PersonalConnectionSecretMode.clear ? '' : key.trim(),
    'name': _clean(name),
    'path': _clean(path),
    'auth_type': 'bearer',
    'enabled': enabled,
    'config': <String, dynamic>{},
  };

  Map<String, dynamic> toPatch(Map<String, dynamic> previous) {
    final patch = <String, dynamic>{};
    _setIfChanged(patch, previous, 'name', _clean(name));
    _setIfChanged(patch, previous, 'url', _stripTrailingSlash(_clean(url)));
    _setIfChanged(
      patch,
      previous,
      'path',
      _clean(path),
      fallback: '/openapi.json',
    );
    if ((previous['enabled'] == true) != enabled) patch['enabled'] = enabled;
    if (keyMode == PersonalConnectionSecretMode.replace) {
      patch['key'] = key.trim();
    } else if (keyMode == PersonalConnectionSecretMode.clear) {
      patch['key'] = '';
    }
    return patch;
  }
}
