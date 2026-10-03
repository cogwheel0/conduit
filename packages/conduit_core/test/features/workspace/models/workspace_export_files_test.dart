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
    check(WorkspaceExportFiles.withExtension('models.json', 'JSON'))
        .equals('models.json');
    check(WorkspaceExportFiles.withExtension('models', 'JSON'))
        .equals('models.JSON');
  });

  test('sanitize collapses unsafe runs and blocks path escapes', () {
    check(WorkspaceExportFiles.sanitize('My Tool (v2).json'))
        .equals('My_Tool_v2_.json');
    check(WorkspaceExportFiles.sanitize('../../etc/passwd'))
        .equals('.._.._etc_passwd');
    check(WorkspaceExportFiles.sanitize('résumé.md')).equals('résumé.md');
    check(WorkspaceExportFiles.sanitize('模型.json')).equals('模型.json');
    check(WorkspaceExportFiles.sanitize('模型 (v2)/x.json'))
        .equals('模型_v2_x.json');
    check(WorkspaceExportFiles.sanitize('a:b*c?.json')).equals('a_b_c_.json');
    check(WorkspaceExportFiles.sanitize('')).equals('export');
    // An overlong name is cut to a byte budget, keeping a short extension.
    int bytes(String value) => utf8.encode(value).length;
    final bounded = WorkspaceExportFiles.sanitize('${'a' * 300}.json');
    check(bytes(bounded)).equals(WorkspaceExportFiles.maxNameBytes);
    check(bounded).endsWith('.json');
    // Three-byte characters: a hundred of them are already over 255 bytes.
    final cjk = WorkspaceExportFiles.sanitize('${'模' * 100}.json');
    check(bytes(cjk)).isLessOrEqual(WorkspaceExportFiles.maxNameBytes);
    check(cjk).endsWith('.json');
    check(cjk.startsWith('模')).isTrue();
    check(bytes(WorkspaceExportFiles.sanitize('b' * 300)))
        .equals(WorkspaceExportFiles.maxNameBytes);
    // A name that fits is left alone.
    check(WorkspaceExportFiles.sanitize('${'模' * 60}.json'))
        .equals('${'模' * 60}.json');

    // Names that are only dots cannot be files.
    check(WorkspaceExportFiles.sanitize('.')).equals('export');
    check(WorkspaceExportFiles.sanitize('..')).equals('export');
    check(WorkspaceExportFiles.sanitize(' .. ')).equals('export');
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

    check(file.uri.pathSegments.last).equals('a_b_c.json');
    // Inside the export-owned directory, in a directory of its own.
    check(file.parent.parent.path)
        .equals('${dir.path}/${WorkspaceExportFiles.stagingRoot}');
    check(await file.readAsBytes()).deepEquals([1, 2, 3]);
  });

  test('a long non-Latin name can still be written', () async {
    final dir = await Directory.systemTemp.createTemp('workspace_export');
    addTearDown(() => dir.delete(recursive: true));

    final file = await WorkspaceExportFiles.stage(
      directory: dir,
      filename: '${'模' * 100}.json',
      bytes: [1],
    );

    check(await file.exists()).isTrue();
    check(utf8.encode(file.uri.pathSegments.last).length)
        .isLessOrEqual(WorkspaceExportFiles.maxNameBytes);
  });

  test('exports with the same name get their own paths', () async {
    final dir = await Directory.systemTemp.createTemp('workspace_export');
    addTearDown(() => dir.delete(recursive: true));

    final first = await WorkspaceExportFiles.stage(
      directory: dir,
      filename: 'models.json',
      bytes: [1],
    );
    final second = await WorkspaceExportFiles.stage(
      directory: dir,
      filename: 'models.json',
      bytes: [2],
    );

    check(first.path).not((it) => it.equals(second.path));
    check(await first.readAsBytes()).deepEquals([1]);
    check(await second.readAsBytes()).deepEquals([2]);
  });

  test('staging removes older exports and leaves everything else', () async {
    final dir = await Directory.systemTemp.createTemp('workspace_export');
    addTearDown(() => dir.delete(recursive: true));
    // Neighbours of the export directory are never touched, even when their
    // name starts like a staged export's.
    final other = Directory('${dir.path}/export_unrelated')..createSync();
    File('${other.path}/keep.txt').writeAsStringSync('keep');

    final old = await WorkspaceExportFiles.stage(
      directory: dir,
      filename: 'old.json',
      bytes: [1],
    );
    // A recent export survives an ordinary export.
    final recent = await WorkspaceExportFiles.stage(
      directory: dir,
      filename: 'recent.json',
      bytes: [2],
    );
    check(await old.exists()).isTrue();
    check(await recent.exists()).isTrue();

    // With a zero keep time everything staged before is stale.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final fresh = await WorkspaceExportFiles.stage(
      directory: dir,
      filename: 'fresh.json',
      bytes: [3],
      keepFor: Duration.zero,
    );

    check(await old.exists()).isFalse();
    check(await old.parent.exists()).isFalse();
    check(await recent.exists()).isFalse();
    check(await fresh.exists()).isTrue();
    check(await other.exists()).isTrue();
    check(File('${other.path}/keep.txt').existsSync()).isTrue();
  });
}
