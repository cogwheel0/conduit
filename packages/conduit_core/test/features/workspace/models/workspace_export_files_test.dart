import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:test/test.dart';

import 'package:conduit_core/features/workspace/models/workspace_export_files.dart';

void main() {
  test('withExtension appends the extension once', () {
    check(WorkspaceExportFiles.withExtension('models', 'json'))
        .equals('models.json');
    check(WorkspaceExportFiles.withExtension(' Models.JSON ', 'json'))
        .equals('Models.JSON');
    check(WorkspaceExportFiles.withExtension('  ', 'json'))
        .equals('export.json');
  });

  test('sanitize collapses unsafe runs and blocks path escapes', () {
    check(WorkspaceExportFiles.sanitize('My Tool (v2).json'))
        .equals('My_Tool_v2_.json');
    check(WorkspaceExportFiles.sanitize('../../etc/passwd'))
        .equals('.._.._etc_passwd');
    check(WorkspaceExportFiles.sanitize('résumé.md')).equals('r_sum_.md');
    check(WorkspaceExportFiles.sanitize('')).equals('export');
  });

  test('jsonBytes pretty-prints UTF-8 JSON', () {
    final bytes = WorkspaceExportFiles.jsonBytes([
      {'name': 'ü'},
    ]);
    check(utf8.decode(bytes)).equals('[\n  {\n    "name": "ü"\n  }\n]');
  });

  test('stage writes the bytes under the sanitized name', () async {
    final dir = await Directory.systemTemp.createTemp('workspace_export');
    addTearDown(() => dir.delete(recursive: true));

    final file = await WorkspaceExportFiles.stage(
      directory: dir,
      filename: 'a b/c.json',
      bytes: [1, 2, 3],
    );

    check(file.path).equals('${dir.path}/a_b_c.json');
    check(await file.readAsBytes()).deepEquals([1, 2, 3]);
  });
}
