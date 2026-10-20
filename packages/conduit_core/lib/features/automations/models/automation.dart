import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// An Open WebUI scheduled task ("automation"), as the server returns it.
///
/// [data] and [meta] are kept exactly as the server sent them, unknown keys
/// included. The server overwrites both from every update form, so an edit has
/// to send them back whole; reading them through the typed getters never
/// loses what this client does not model.
///
/// Every timestamp is integer epoch **nanoseconds**. Nanosecond epochs exceed
/// what a double holds exactly, so they are never routed through one.
@immutable
class Automation {
  const Automation({
    required this.id,
    required this.userId,
    required this.name,
    required this.data,
    required this.isActive,
    this.folderId,
    this.meta,
    this.lastRunAtNs,
    this.nextRunAtNs,
    this.createdAtNs,
    this.updatedAtNs,
    this.lastRun,
    this.nextRunsNs,
  });

  final String id;

  /// The owner. Open WebUI shows a task only to its owner, an admin included.
  final String userId;
  final String? folderId;
  final String name;

  /// `{prompt, model_id, rrule, terminal?, target?}` plus anything else the
  /// server stored.
  final Map<String, dynamic> data;

  /// Opaque task settings; null when the server has none.
  final Map<String, dynamic>? meta;
  final bool isActive;
  final int? lastRunAtNs;
  final int? nextRunAtNs;
  final int? createdAtNs;
  final int? updatedAtNs;

  /// The most recent history entry, or null when the task has never run.
  final AutomationRun? lastRun;

  /// The server's own next occurrences, computed in the account's time zone.
  /// Null when the route does not compute them (list items).
  final List<int>? nextRunsNs;

  String get prompt => _string(data['prompt']) ?? '';
  String get modelId => _string(data['model_id']) ?? '';
  String get rrule => _string(data['rrule']) ?? '';

  /// The terminal server configuration, verbatim, or null when none is set.
  Map<String, dynamic>? get terminal => _map(data['terminal']);

  AutomationTarget get target => AutomationTarget.fromJson(data['target']);

  /// The next time the server will run an active task, or null when it has no
  /// future run or is paused. A paused task still has `next_runs` computed
  /// from its rule, so those are not a promise.
  int? get nextRunNs {
    if (!isActive) return null;
    final next = nextRunsNs;
    if (next != null && next.isNotEmpty) return next.first;
    return nextRunAtNs;
  }

  factory Automation.fromJson(Map<String, dynamic> json) {
    final data = _map(json['data']) ?? const <String, dynamic>{};
    final last = _map(json['last_run']);
    final nextRuns = json['next_runs'];
    return Automation(
      id: (json['id'] ?? '').toString(),
      userId: (json['user_id'] ?? '').toString(),
      folderId: _string(json['folder_id']),
      name: (json['name'] ?? '').toString(),
      data: data,
      meta: _map(json['meta']),
      isActive: json['is_active'] is bool ? json['is_active'] as bool : true,
      lastRunAtNs: epochNanoseconds(json['last_run_at']),
      nextRunAtNs: epochNanoseconds(json['next_run_at']),
      createdAtNs: epochNanoseconds(json['created_at']),
      updatedAtNs: epochNanoseconds(json['updated_at']),
      lastRun: last == null ? null : AutomationRun.fromJson(last),
      nextRunsNs: nextRuns is List
          ? List<int>.unmodifiable([
              for (final value in nextRuns) ?epochNanoseconds(value),
            ])
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Automation &&
      other.id == id &&
      other.userId == userId &&
      other.folderId == folderId &&
      other.name == name &&
      other.isActive == isActive &&
      other.lastRunAtNs == lastRunAtNs &&
      other.nextRunAtNs == nextRunAtNs &&
      other.createdAtNs == createdAtNs &&
      other.updatedAtNs == updatedAtNs &&
      other.lastRun == lastRun &&
      const DeepCollectionEquality().equals(other.data, data) &&
      const DeepCollectionEquality().equals(other.meta, meta) &&
      const ListEquality<int>().equals(other.nextRunsNs, nextRunsNs);

  @override
  int get hashCode => Object.hash(
    id,
    userId,
    folderId,
    name,
    isActive,
    lastRunAtNs,
    nextRunAtNs,
    updatedAtNs,
    lastRun,
    const DeepCollectionEquality().hash(data),
    const DeepCollectionEquality().hash(meta),
  );

  // The prompt can hold anything the user wrote.
  @override
  String toString() => 'Automation($id)';
}

/// Where a task's result goes.
@immutable
class AutomationTarget {
  const AutomationTarget._({required this.isChannel, this.channelId});

  /// A new chat for each run, optionally inside a folder.
  const AutomationTarget.chat() : this._(isChannel: false);

  /// A message in an existing channel.
  const AutomationTarget.channel(String channelId)
    : this._(isChannel: true, channelId: channelId);

  /// A channel destination whose channel is not chosen yet. It cannot be
  /// saved until one is.
  const AutomationTarget.channelPending() : this._(isChannel: true);

  final bool isChannel;
  final String? channelId;

  /// The server treats a missing or non-channel target as a chat.
  factory AutomationTarget.fromJson(Object? json) {
    if (json is Map && json['type'] == 'channel') {
      final id = json['channel_id'];
      return AutomationTarget._(
        isChannel: true,
        channelId: id is String && id.isNotEmpty ? id : null,
      );
    }
    return const AutomationTarget.chat();
  }

  @override
  bool operator ==(Object other) =>
      other is AutomationTarget &&
      other.isChannel == isChannel &&
      other.channelId == channelId;

  @override
  int get hashCode => Object.hash(isChannel, channelId);
}

/// One entry of a task's history. Independent of the definition: a run is
/// recorded when the server finishes one, not when one is requested.
@immutable
class AutomationRun {
  const AutomationRun({
    required this.id,
    required this.automationId,
    required this.status,
    this.chatId,
    this.error,
    this.createdAtNs,
  });

  /// The only success status the server records; any other value is shown as a
  /// failure.
  static const String statusSuccess = 'success';

  /// Prefix the server puts on `chat_id` when the result is a channel message.
  static const String channelPrefix = 'channel:';

  final String id;
  final String automationId;
  final String status;

  /// The result chat, or `channel:<id>` for a channel result.
  final String? chatId;
  final String? error;
  final int? createdAtNs;

  bool get succeeded => status == statusSuccess;

  /// The channel the result was posted to, or null for a chat result.
  String? get resultChannelId {
    final id = chatId;
    if (id == null || !id.startsWith(channelPrefix)) return null;
    final channel = id.substring(channelPrefix.length);
    return channel.isEmpty ? null : channel;
  }

  /// The result chat, or null when there is none or it is a channel result.
  String? get resultChatId {
    final id = chatId;
    if (id == null || id.isEmpty || id.startsWith(channelPrefix)) return null;
    return id;
  }

  factory AutomationRun.fromJson(Map<String, dynamic> json) {
    return AutomationRun(
      id: (json['id'] ?? '').toString(),
      automationId: (json['automation_id'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      chatId: _string(json['chat_id']),
      error: _string(json['error']),
      createdAtNs: epochNanoseconds(json['created_at']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AutomationRun &&
      other.id == id &&
      other.automationId == automationId &&
      other.status == status &&
      other.chatId == chatId &&
      other.error == error &&
      other.createdAtNs == createdAtNs;

  @override
  int get hashCode =>
      Object.hash(id, automationId, status, chatId, error, createdAtNs);

  @override
  String toString() => 'AutomationRun($id)';
}

/// Entries the server returns per history page unless asked for fewer.
const int automationRunsPageSize = 50;

/// One page of `GET /automations/list`.
@immutable
class AutomationPage {
  const AutomationPage({required this.items, required this.total});

  final List<Automation> items;

  /// Matches across every page, for the same query and status.
  final int total;
}

/// What a create or update sends. [data] is the full `data` object, including
/// keys this client does not edit, and [meta] is the server's own value, since
/// an update replaces both.
@immutable
class AutomationForm {
  const AutomationForm({
    required this.name,
    required this.data,
    required this.isActive,
    this.folderId,
    this.meta,
  });

  final String name;
  final String? folderId;
  final Map<String, dynamic> data;
  final Map<String, dynamic>? meta;
  final bool isActive;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'folder_id': folderId,
    'data': data,
    'meta': ?meta,
    'is_active': isActive,
  };
}

/// An epoch value as integer nanoseconds.
///
/// A JSON integer is kept as is. A numeric string is read as an integer, since
/// a proxy can quote a value too large for its parser. A double is accepted
/// only when it is a whole number: a fractional or non-finite one cannot be a
/// nanosecond count.
int? epochNanoseconds(Object? value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value.trim());
  if (value is double) {
    if (!value.isFinite || value != value.truncateToDouble()) return null;
    return value.toInt();
  }
  return null;
}

/// [nanoseconds] as a [DateTime], at the microsecond precision it holds.
DateTime? dateTimeFromEpochNanoseconds(int? nanoseconds) {
  if (nanoseconds == null) return null;
  return DateTime.fromMicrosecondsSinceEpoch(nanoseconds ~/ 1000);
}

String? _string(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

Map<String, dynamic>? _map(Object? value) => value is Map
    ? Map<String, dynamic>.unmodifiable(
        value.map((key, entry) => MapEntry(key.toString(), entry)),
      )
    : null;
