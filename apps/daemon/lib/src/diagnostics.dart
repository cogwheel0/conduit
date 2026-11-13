import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'redact.dart';

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
