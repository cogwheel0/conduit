import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';

/// The most subagents or processes one chat lists.
const int kMaxHermesBackgroundItems = 64;

/// Hermes sends at most the last 16 KiB of a child's transcript.
const int kMaxHermesSubagentTailCharacters = 16384;

/// The most of a process's output kept for its row.
const int kMaxHermesProcessOutputCharacters = 4000;
const int _kMaxGoalCharacters = 500;
const int _kMaxCommandCharacters = 200;
const int _kMaxLabelCharacters = 120;

/// A child agent the chat's agent delegated a task to (a `subagent.list`
/// row): its goal, model, and how far it got.
final class HermesSubagent {
  const HermesSubagent({
    required this.id,
    required this.goal,
    this.parentId,
    this.depth = 0,
    this.model,
    this.startedAt,
    this.status,
    this.toolCount = 0,
    this.lastTool,
    this.acceptingSteer = true,
  });

  final String id;
  final String goal;

  /// The subagent that spawned this one, when it is nested.
  final String? parentId;
  final int depth;
  final String? model;
  final DateTime? startedAt;

  /// Hermes' lifecycle word (`queued`, `running`, `completed`, ...).
  final String? status;
  final int toolCount;
  final String? lastTool;

  /// Whether Hermes still passes new instructions on to it.
  final bool acceptingSteer;

  /// Queued or running; other statuses are final.
  bool get running =>
      status == null || status == 'running' || status == 'queued';

  static HermesSubagent? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = validateHermesOpaqueIdentifier(raw['subagent_id']);
    if (id == null) return null;
    final depth = raw['depth'];
    final tools = raw['tool_count'];
    return HermesSubagent(
      id: id,
      goal: _line(raw['goal'], _kMaxGoalCharacters) ?? '',
      parentId: validateHermesOpaqueIdentifier(raw['parent_id']),
      depth: depth is int && depth > 0 ? depth.clamp(0, 8) : 0,
      model: _line(raw['model'], _kMaxLabelCharacters),
      startedAt: _epoch(raw['started_at']),
      status: _line(raw['status'], 32),
      toolCount: tools is int && tools > 0 ? tools : 0,
      lastTool: _line(raw['last_tool'], _kMaxLabelCharacters),
      acceptingSteer: raw['accepting_steer'] != false,
    );
  }
}

/// A command the agent left running in the background (a `process.list`
/// row): a dev server, a watcher, a long build.
final class HermesBackgroundProcess {
  const HermesBackgroundProcess({
    required this.id,
    required this.command,
    required this.running,
    this.startedAt,
    this.exitCode,
    this.output,
  });

  final String id;

  /// The command's first line, shortened.
  final String command;
  final bool running;
  final DateTime? startedAt;
  final int? exitCode;

  /// The end of what it printed, when Hermes sent it.
  final String? output;

  /// [now] lets a legacy row, which counts `uptime_seconds` instead of
  /// naming its start, date its start.
  static HermesBackgroundProcess? fromJson(Object? raw, {DateTime? now}) {
    if (raw is! Map) return null;
    final id = validateHermesOpaqueIdentifier(raw['session_id']);
    if (id == null) return null;
    final command = raw['command'];
    final firstLine = command is String
        ? command.trim().split('\n').first
        : '';
    final uptime = raw['uptime_seconds'];
    final exitCode = raw['exit_code'];
    final output = raw['output_tail'] ?? raw['output_preview'];
    return HermesBackgroundProcess(
      id: id,
      command: _line(firstLine, _kMaxCommandCharacters) ?? id,
      running: raw['status'] != 'exited',
      startedAt:
          _epoch(raw['started_epoch']) ??
          (uptime is int && uptime >= 0
              ? (now ?? DateTime.now()).subtract(Duration(seconds: uptime))
              : null),
      exitCode: exitCode is int ? exitCode : null,
      output: output is String && output.isNotEmpty
          ? _tail(output, kMaxHermesProcessOutputCharacters)
          : null,
    );
  }
}

/// What a chat has running besides its reply: delegated child agents and
/// background processes, as Hermes listed them last.
final class HermesBackgroundWork {
  const HermesBackgroundWork({
    this.subagents = const [],
    this.processes = const [],
  });

  static const empty = HermesBackgroundWork();

  final List<HermesSubagent> subagents;
  final List<HermesBackgroundProcess> processes;

  int get runningSubagents => subagents.where((s) => s.running).length;
  int get runningProcesses => processes.where((p) => p.running).length;

  /// Whether anything is still running.
  bool get active => runningSubagents > 0 || runningProcesses > 0;

  HermesSubagent? subagent(String id) =>
      subagents.where((subagent) => subagent.id == id).firstOrNull;

  /// Reads a `subagent.list` result and a `process.list` result; either may
  /// be null when the gateway does not serve it.
  static HermesBackgroundWork fromResults({
    Object? subagents,
    Object? processes,
    DateTime? now,
  }) {
    final children = <HermesSubagent>[];
    final rows = subagents is Map ? subagents['subagents'] : null;
    if (rows is List) {
      for (final raw in rows.take(kMaxHermesBackgroundItems)) {
        final subagent = HermesSubagent.fromJson(raw);
        if (subagent != null) children.add(subagent);
      }
    }
    final commands = <HermesBackgroundProcess>[];
    final entries = processes is Map ? processes['processes'] : null;
    if (entries is List) {
      for (final raw in entries.take(kMaxHermesBackgroundItems)) {
        final process = HermesBackgroundProcess.fromJson(raw, now: now);
        if (process != null) commands.add(process);
      }
    }
    return HermesBackgroundWork(
      subagents: List.unmodifiable(children),
      processes: List.unmodifiable(commands),
    );
  }
}

/// The end of a subagent's live transcript (`subagent.tail`).
final class HermesSubagentTail {
  const HermesSubagentTail({
    required this.available,
    this.text = '',
    this.truncated = false,
  });

  /// False while the child has no transcript yet or once it is gone.
  final bool available;
  final String text;

  /// Whether earlier output was cut off.
  final bool truncated;

  static HermesSubagentTail fromJson(Object? raw) {
    if (raw is! Map) return const HermesSubagentTail(available: false);
    final text = raw['text'];
    return HermesSubagentTail(
      available: raw['available'] == true,
      text: text is String
          ? _tail(text, kMaxHermesSubagentTailCharacters)
          : '',
      truncated: raw['truncated'] == true,
    );
  }
}

enum HermesProcessKillStatus { killed, alreadyExited, notFound, failed }

/// What `process.kill` did, with the end of the process's output.
final class HermesProcessKillResult {
  const HermesProcessKillResult({
    required this.status,
    this.output,
    this.error,
  });

  final HermesProcessKillStatus status;
  final String? output;
  final String? error;

  /// Whether the process is no longer running.
  bool get stopped =>
      status == HermesProcessKillStatus.killed ||
      status == HermesProcessKillStatus.alreadyExited;

  static HermesProcessKillResult fromJson(Object? raw) {
    if (raw is! Map) {
      return const HermesProcessKillResult(
        status: HermesProcessKillStatus.failed,
      );
    }
    final output = raw['output'];
    return HermesProcessKillResult(
      status: switch (raw['status']) {
        'killed' => HermesProcessKillStatus.killed,
        'already_exited' => HermesProcessKillStatus.alreadyExited,
        'not_found' => HermesProcessKillStatus.notFound,
        _ => HermesProcessKillStatus.failed,
      },
      output: output is String && output.isNotEmpty
          ? _tail(output, kMaxHermesProcessOutputCharacters)
          : null,
      error: _line(raw['error'], 300),
    );
  }
}

/// [value] on one line, shortened to [max] characters; null when empty.
String? _line(Object? value, int max) {
  if (value is! String) return null;
  final text = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (text.isEmpty || text.contains('\u0000')) return null;
  final runes = text.runes;
  if (runes.length <= max) return text;
  return '${String.fromCharCodes(runes.take(max - 1))}…';
}

/// The last [max] UTF-16 units of [text], never half a character.
String _tail(String text, int max) {
  final clean = text.replaceAll('\u0000', '');
  if (clean.length <= max) return clean;
  var start = clean.length - max;
  final unit = clean.codeUnitAt(start);
  if (unit >= 0xDC00 && unit <= 0xDFFF) start++;
  return clean.substring(start);
}

/// A Unix time in seconds, as Hermes sends it.
DateTime? _epoch(Object? value) {
  if (value is! num || !value.isFinite || value <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch((value * 1000).round());
}
