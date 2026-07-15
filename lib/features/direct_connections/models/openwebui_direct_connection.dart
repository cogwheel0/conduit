import 'dart:collection';

import 'direct_connection_profile.dart';

/// Whether Conduit can safely execute a direct connection stored by Open WebUI.
enum OpenWebUiDirectConnectionCompatibility {
  compatible,
  unsupportedAuthentication,
  invalidProfile,
}

/// One indexed Open WebUI `ui.directConnections` entry.
///
/// This is an ephemeral projection of server settings. [rawConfig] is retained
/// only so edits can round-trip configuration fields that Conduit does not yet
/// understand. It must never be persisted into the local profile document.
final class OpenWebUiDirectConnectionRecord {
  OpenWebUiDirectConnectionRecord({
    required this.index,
    required this.profile,
    required this.revision,
    required this.contentRevision,
    required Map<String, dynamic> rawConfig,
    required this.authType,
    required this.compatibility,
  }) : rawConfig = _freezeJsonMap(rawConfig);

  final int index;
  final DirectConnectionProfile profile;

  /// Opaque fingerprint of this indexed raw server record.
  ///
  /// Callers may retain this value for compare-and-swap edits, but should not
  /// infer any record data from it.
  final String revision;

  /// Alias documenting that [revision] fingerprints the raw server record.
  String get fingerprint => revision;

  /// Opaque keyed fingerprint of the raw record without its mutable index.
  ///
  /// Editors use this only to distinguish a pure reindex from a same-id
  /// content edit before refreshing their compare-and-swap base.
  final String contentRevision;

  /// Original per-index config, including fields unknown to Conduit.
  final Map<String, dynamic> rawConfig;

  /// Normalized Open WebUI `auth_type`; missing values decode as `bearer`.
  final String authType;
  final OpenWebUiDirectConnectionCompatibility compatibility;

  bool get isCompatible =>
      compatibility == OpenWebUiDirectConnectionCompatibility.compatible;

  @override
  String toString() =>
      'OpenWebUiDirectConnectionRecord(index: $index, '
      'compatibility: ${compatibility.name})';
}

/// Authoritative server snapshot used by the remote direct-connection UI.
final class OpenWebUiDirectConnectionsSnapshot {
  OpenWebUiDirectConnectionsSnapshot({
    required this.serverId,
    required this.accountId,
    required Iterable<OpenWebUiDirectConnectionRecord> records,
    required Map<String, dynamic> ui,
    required this.documentRevision,
  }) : records = List<OpenWebUiDirectConnectionRecord>.unmodifiable(records),
       ui = _freezeJsonMap(ui);

  final String serverId;
  final String accountId;
  final List<OpenWebUiDirectConnectionRecord> records;

  /// Complete `ui` object from the user settings response.
  ///
  /// Store mutations clone and merge this object before replacing only
  /// `directConnections`.
  final Map<String, dynamic> ui;

  /// Opaque fingerprint of the raw `ui.directConnections` document.
  final String documentRevision;

  List<DirectConnectionProfile> get profiles =>
      List<DirectConnectionProfile>.unmodifiable(
        records.map((record) => record.profile),
      );

  List<DirectConnectionProfile> get compatibleProfiles =>
      List<DirectConnectionProfile>.unmodifiable(
        records
            .where((record) => record.isCompatible)
            .map((record) => record.profile),
      );

  OpenWebUiDirectConnectionRecord? recordByProfileId(String profileId) {
    for (final record in records) {
      if (record.profile.id == profileId) return record;
    }
    return null;
  }

  @override
  String toString() =>
      'OpenWebUiDirectConnectionsSnapshot(records: ${records.length})';
}

Map<String, dynamic> _freezeJsonMap(Map<String, dynamic> source) =>
    UnmodifiableMapView<String, dynamic>(
      source.map((key, value) => MapEntry(key, _freezeJsonValue(value))),
    );

Object? _freezeJsonValue(Object? value) => switch (value) {
  Map<String, dynamic>() => _freezeJsonMap(value),
  Map() => UnmodifiableMapView<String, dynamic>(
    value.map<String, dynamic>(
      (key, item) => MapEntry(key.toString(), _freezeJsonValue(item)),
    ),
  ),
  List() => List<Object?>.unmodifiable(value.map(_freezeJsonValue)),
  _ => value,
};
