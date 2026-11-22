import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:path/path.dart' as p;

import 'daemon_paths.dart';
import 'log.dart';
import 'redact.dart';
import 'system_service.dart';

/// `system.exportDiagnostics` on the desktop: the daemon's logs and a
/// snapshot of its configuration with every credential left out, zipped
/// into the staging directory.
final class DaemonDiagnostics {
  DaemonDiagnostics({
    required this.directories,
    required DaemonLog log,
    required SystemService system,
    Future<Map<String, Object?>> Function()? configSnapshot,
    Iterable<String> secrets = const <String>[],
  }) : _log = log,
       _system = system,
       _configSnapshot = configSnapshot,
       _secrets = List<String>.of(secrets);

  final DaemonDirectories directories;
  final DaemonLog _log;
  final SystemService _system;

  /// Null, or answering for nothing, while the core is starting.
  final Future<Map<String, Object?>> Function()? _configSnapshot;

  /// Known by value and kept out of the export: the session token and the
  /// master key.
  final List<String> _secrets;

  Future<DiagnosticsExport> export() async {
    final zip = await writeDiagnosticsZip(
      logs: Directory(directories.paths.logs),
      staging: Directory(directories.paths.staging),
      snapshot: await _snapshot(),
      exactSecrets: _secrets,
    );
    _log.info('diagnostics written to ${homeRelative(zip.path)}');
    return DiagnosticsExport(path: zip.path, sizeBytes: await zip.length());
  }

  Future<Map<String, Object?>> _snapshot() async {
    Map<String, Object?> core;
    final snapshot = _configSnapshot;
    if (snapshot == null) {
      core = <String, Object?>{'state': 'starting'};
    } else {
      try {
        core = await snapshot();
      } on Object catch (error) {
        core = <String, Object?>{
          'state': 'unreadable',
          'error': error.runtimeType.toString(),
        };
      }
    }
    return <String, Object?>{
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'daemonVersion': _system.daemonVersion,
      'protocolVersion': kConduitProtocolVersion,
      'platform': _system.platform,
      'osVersion': Platform.operatingSystemVersion,
      'dartVersion': Platform.version.split(' ').first,
      'uptimeMs': _system.ping().uptimeMs,
      'logLevel': _log.level,
      'paths': <String, String>{
        'userData': homeRelative(directories.paths.userData),
        'logs': homeRelative(directories.paths.logs),
      },
      'capabilities': _system.capabilities.toJson(),
      'core': core,
    };
  }
}

/// The platform string the protocol uses for this computer. Kept here
/// rather than derived in the UI so both front-ends agree on the spelling.
String get daemonPlatform {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  return Platform.operatingSystem;
}

/// Writes a diagnostics zip into [staging] and returns it.
///
/// It holds the daemon's log files from [logs] (`*.log`, as written by
/// `RotatingLogFile`) under `logs/`, and [snapshot] as `config.json`.
/// Nothing leaves the computer: the app reveals the file and the user
/// decides what to do with it.
///
/// The snapshot is built field by field from what is known to be safe, and
/// both it and the logs pass through [redactSecrets] once more on the way
/// in, so a token that slipped into a line anyway, or a log written before
/// redaction existed, still does not reach the zip. [exactSecrets] are
/// secrets known by value: the session token and the master key.
Future<File> writeDiagnosticsZip({
  required Directory logs,
  required Directory staging,
  required Map<String, Object?> snapshot,
  Iterable<String> exactSecrets = const <String>[],
  DateTime? now,
}) async {
  final archive = Archive();
  void add(String name, String text) {
    final bytes = utf8.encode(redactSecrets(text, exact: exactSecrets));
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('config.json', const JsonEncoder.withIndent('  ').convert(snapshot));

  if (logs.existsSync()) {
    final files =
        logs
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.log'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      // Read leniently: a line cut off mid-character by a crash is still
      // worth having.
      final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      add('logs/${p.basename(file.path)}', text);
    }
  }

  final stamp = (now ?? DateTime.now())
      .toUtc()
      .toIso8601String()
      .replaceAll(':', '')
      .split('.')
      .first;
  await staging.create(recursive: true);
  final zip = File(p.join(staging.path, 'conduit-diagnostics-${stamp}Z.zip'));
  await zip.writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
  return zip;
}

/// [path] with the user's home directory shown as `~`, so a snapshot does
/// not carry the account name.
String homeRelative(String path) {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty || !p.isWithin(home, path)) return path;
  return p.join('~', p.relative(path, from: home));
}
