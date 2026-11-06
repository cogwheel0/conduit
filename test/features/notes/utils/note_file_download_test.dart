import 'dart:convert' show utf8;
import 'dart:io' show Directory;

import 'package:conduit/features/notes/utils/note_file_download.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a name keeps no path separators', () {
    expect(noteFileDownloadName('../../etc/passwd'), '.._.._etc_passwd');
  });

  test('a name file systems refuse is made safe, and a long one cut', () {
    expect(noteFileDownloadName('a:b*c?.pdf'), 'a_b_c_.pdf');
    expect(noteFileDownloadName('  '), 'file');
    final fileName = noteFileDownloadName('${'x' * 300}.pdf');
    expect(fileName.length, 200);
    expect(fileName, endsWith('.pdf'));
  });

  test('a name is cut by its bytes, never inside a character', () {
    final fileName = noteFileDownloadName('${'文' * 100}.pdf');
    expect(utf8.encode(fileName).length, lessThanOrEqualTo(200));
    expect(fileName, endsWith('.pdf'));
    expect(fileName.replaceAll('文', ''), '.pdf');
  });

  test('downloads go under the temporary folder', () {
    expect(noteFileDownloadsPath('/tmp'), '/tmp/note-files');
  });

  test('a download folder is made under folders that are not there yet, one '
      'of its own each time', () async {
    final temp = Directory.systemTemp.createTempSync('note-download-test');
    addTearDown(() => temp.deleteSync(recursive: true));

    final first = await createNoteFileDownloadFolder(temp.path, '../f1');
    final second = await createNoteFileDownloadFolder(temp.path, '../f1');

    expect(first.existsSync(), isTrue);
    expect(first.parent.path, noteFileDownloadsPath(temp.path));
    expect(first.path, isNot(second.path));
    expect(first.path.split(RegExp(r'[/\\]')).last, startsWith('___f1-'));
  });
}
