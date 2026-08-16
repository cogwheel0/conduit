import 'dart:convert';

import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';
import '../../../core/utils/unicode_prefix.dart';
import '../models/hermes_run_event.dart';
import 'hermes_identifier.dart';

enum HermesPendingDesktopDecisionKind {
  approval,
  clarification,
  sudo,
  secret,
  mcpSetup,
}

final class HermesPendingDesktopDecision {
  const HermesPendingDesktopDecision({
    required this.origin,
    required this.storedSessionId,
    required this.runtimeId,
    required this.requestId,
    required this.kind,
    required this.expiresAt,
    this.prompt,
    this.mcpServer,
    this.mcpAction,
    this.choices = const <String>[],
    this.multiSelect = false,
  });

  final String origin;
  final String storedSessionId;
  final String runtimeId;
  final String requestId;
  final HermesPendingDesktopDecisionKind kind;
  final DateTime expiresAt;
  final String? prompt;
  final String? mcpServer;
  final String? mcpAction;
  final List<String> choices;
  final bool multiSelect;

  HermesDecisionKind? get decisionKind => switch (kind) {
    HermesPendingDesktopDecisionKind.approval => null,
    HermesPendingDesktopDecisionKind.clarification =>
      HermesDecisionKind.clarification,
    HermesPendingDesktopDecisionKind.sudo => HermesDecisionKind.sudo,
    HermesPendingDesktopDecisionKind.secret => HermesDecisionKind.secret,
    HermesPendingDesktopDecisionKind.mcpSetup => HermesDecisionKind.mcpSetup,
  };

  String get identity => '$origin\u0000$storedSessionId\u0000$requestId';

  String toStorage() => jsonEncode(<String, Object?>{
    'origin': origin,
    'stored_session_id': storedSessionId,
    'runtime_id': runtimeId,
    'request_id': requestId,
    'kind': kind.name,
    'expires_at': expiresAt.toUtc().toIso8601String(),
    if (prompt != null) 'prompt': prompt,
    if (mcpServer != null) 'mcp_server': mcpServer,
    if (mcpAction != null) 'mcp_action': mcpAction,
    if (choices.isNotEmpty) 'choices': choices,
    if (multiSelect) 'multi_select': true,
  });

  static HermesPendingDesktopDecision? fromStorage(String source) {
    if (source.length > 4096) return null;
    try {
      final value = jsonDecode(source);
      if (value is! Map) return null;
      final origin = value['origin'];
      final storedId = validateHermesOpaqueIdentifier(
        value['stored_session_id'],
      );
      final runtimeId = validateHermesOpaqueIdentifier(value['runtime_id']);
      final requestId = validateHermesOpaqueIdentifier(value['request_id']);
      final expiresAt = DateTime.tryParse(value['expires_at']?.toString() ?? '')
          ?.toUtc();
      HermesPendingDesktopDecisionKind? kind;
      for (final candidate in HermesPendingDesktopDecisionKind.values) {
        if (candidate.name == value['kind']) kind = candidate;
      }
      if (origin is! String ||
          origin.length > 2048 ||
          storedId == null ||
          runtimeId == null ||
          requestId == null ||
          kind == null ||
          expiresAt == null) {
        return null;
      }
      final prompt = value['prompt'];
      final mcpServer = validateHermesBoundedString(
        value['mcp_server'],
        maxCharacters: 128,
      );
      final mcpAction = switch (value['mcp_action']) {
        'authorize' || 'enable' || 'install' => value['mcp_action']!.toString(),
        _ => null,
      };
      final choices = _sanitizeChoices(value['choices']);
      return HermesPendingDesktopDecision(
        origin: origin,
        storedSessionId: storedId,
        runtimeId: runtimeId,
        requestId: requestId,
        kind: kind,
        expiresAt: expiresAt,
        prompt: prompt is String && prompt.length <= 512 ? prompt : null,
        mcpServer: mcpServer,
        mcpAction: mcpAction,
        choices: choices,
        multiSelect: value['multi_select'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Restart-safe presentation state only. Sensitive answers are deliberately
/// absent; Hermes remains authoritative for whether a request is resolved.
final class HermesPendingDecisionStore {
  HermesPendingDecisionStore._();

  static const int maxRecords = 64;
  static const Duration ttl = Duration(hours: 24);
  static Future<void> _writes = Future<void>.value();

  static Future<void> upsert({
    required String origin,
    required String storedSessionId,
    required String runtimeId,
    required String requestId,
    required HermesPendingDesktopDecisionKind kind,
    String? prompt,
    String? mcpServer,
    String? mcpAction,
    Iterable<Object?> choices = const <Object?>[],
    bool multiSelect = false,
    Iterable<String> sensitiveValues = const <String>[],
  }) => _serialize(() async {
    final stored = validateHermesOpaqueIdentifier(storedSessionId);
    final runtime = validateHermesOpaqueIdentifier(runtimeId);
    final request = validateHermesOpaqueIdentifier(
      requestId,
      sensitiveValues: sensitiveValues,
    );
    if (origin.isEmpty ||
        stored == null ||
        runtime == null ||
        request == null) {
      return;
    }
    final records = _read();
    final identity = '$origin\u0000$stored\u0000$request';
    HermesPendingDesktopDecision? previous;
    for (final candidate in records) {
      if (candidate.identity == identity) previous = candidate;
    }
    final sanitizedChoices = _sanitizeChoices(choices);
    final record = HermesPendingDesktopDecision(
      origin: origin,
      storedSessionId: stored,
      runtimeId: runtime,
      requestId: request,
      kind: kind,
      expiresAt: DateTime.now().toUtc().add(ttl),
      prompt: _sanitizePrompt(prompt, sensitiveValues),
      mcpServer: kind == HermesPendingDesktopDecisionKind.mcpSetup
          ? validateHermesBoundedString(mcpServer, maxCharacters: 128)
          : null,
      mcpAction:
          kind == HermesPendingDesktopDecisionKind.mcpSetup &&
              const {'authorize', 'enable', 'install'}.contains(mcpAction)
          ? mcpAction
          : null,
      choices: sanitizedChoices.isEmpty
          ? previous?.choices ?? const <String>[]
          : sanitizedChoices,
      multiSelect:
          kind == HermesPendingDesktopDecisionKind.clarification &&
          (sanitizedChoices.isEmpty
              ? previous?.multiSelect ?? multiSelect
              : multiSelect),
    );
    records
      ..removeWhere((candidate) => candidate.identity == record.identity)
      ..add(record);
    await _write(records);
  });

  static Future<void> resolve({
    required String origin,
    required String runtimeId,
    required String requestId,
  }) => _remove(
    (record) =>
        record.origin == origin &&
        record.runtimeId == runtimeId &&
        record.requestId == requestId,
  );

  static Future<void> clearSession({
    required String origin,
    required String storedSessionId,
  }) => _remove(
    (record) =>
        record.origin == origin && record.storedSessionId == storedSessionId,
  );

  static Future<void> clearOrigin(String origin) =>
      _remove((record) => record.origin == origin);

  static Future<void> rebindSession({
    required String origin,
    required String fromStoredSessionId,
    required String toStoredSessionId,
    required String runtimeId,
  }) => _serialize(() async {
    final records = _read();
    final rebound = <HermesPendingDesktopDecision>[];
    for (final record in records) {
      final candidate =
          record.origin == origin &&
              record.storedSessionId == fromStoredSessionId
          ? HermesPendingDesktopDecision(
              origin: record.origin,
              storedSessionId: toStoredSessionId,
              runtimeId: runtimeId,
              requestId: record.requestId,
              kind: record.kind,
              expiresAt: record.expiresAt,
              prompt: record.prompt,
              mcpServer: record.mcpServer,
              mcpAction: record.mcpAction,
              choices: record.choices,
              multiSelect: record.multiSelect,
            )
          : record;
      rebound.removeWhere(
        (existing) => existing.identity == candidate.identity,
      );
      rebound.add(candidate);
    }
    await _write(rebound);
  });

  static Future<List<HermesPendingDesktopDecision>> forSession({
    required String origin,
    required String storedSessionId,
  }) async {
    var records = const <HermesPendingDesktopDecision>[];
    await _serialize(() async {
      records = _read();
      await _write(records);
    });
    return List.unmodifiable(
      records.where(
        (record) =>
            record.origin == origin &&
            record.storedSessionId == storedSessionId,
      ),
    );
  }

  static Future<void> _remove(
    bool Function(HermesPendingDesktopDecision record) predicate,
  ) => _serialize(() async {
    final records = _read()..removeWhere(predicate);
    await _write(records);
  });

  static List<HermesPendingDesktopDecision> _read() {
    if (!PreferencesStore.isReady) return <HermesPendingDesktopDecision>[];
    final now = DateTime.now().toUtc();
    return <HermesPendingDesktopDecision>[
      for (final source
          in PreferencesStore.getStringList(
                PreferenceKeys.hermesPendingDesktopDecisions,
              ) ??
              const <String>[])
        if (HermesPendingDesktopDecision.fromStorage(source) case final record?
            when record.expiresAt.isAfter(now))
          record,
    ];
  }

  static Future<void> _write(List<HermesPendingDesktopDecision> records) {
    final bounded = records.length <= maxRecords
        ? records
        : records.sublist(records.length - maxRecords);
    return PreferencesStore.putChecked(
      PreferenceKeys.hermesPendingDesktopDecisions,
      bounded.map((record) => record.toStorage()).toList(growable: false),
    );
  }

  static Future<void> _serialize(Future<void> Function() operation) {
    final result = _writes.then((_) => operation());
    _writes = result.catchError((_) {});
    return result;
  }
}

List<String> _sanitizeChoices(Object? value) {
  if (value is! Iterable) return const <String>[];
  final result = <String>[];
  for (final candidate in value) {
    final choice = validateHermesBoundedString(candidate, maxCharacters: 80);
    if (choice != null && choice.isNotEmpty && !result.contains(choice)) {
      result.add(choice);
      if (result.length == 8) break;
    }
  }
  return List.unmodifiable(result);
}

String? _sanitizePrompt(String? value, Iterable<String> sensitiveValues) {
  if (value == null || value.trim().isEmpty) return null;
  final secrets =
      sensitiveValues
          .where((secret) => secret.isNotEmpty && secret.length <= 8192)
          .toSet()
          .toList(growable: false)
        ..sort((a, b) => b.length.compareTo(a.length));
  var safe = redactSensitiveValuesInUnicodePrefix(
    value,
    sensitiveValues: secrets,
    maxVisibleScalars: 512,
  );
  safe = safe
      .replaceAllMapped(
        RegExp(
          r'\b(authorization|cookie|api[-_ ]?key|access[-_ ]?token|password|secret)\b\s*[:=]\s*[^\s,;]+',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}: [REDACTED]',
      )
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return safe.isEmpty ? null : safe;
}
