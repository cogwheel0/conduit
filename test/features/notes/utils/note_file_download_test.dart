import 'package:conduit/features/notes/utils/note_file_download.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('two files of one name download to different places', () {
    final first = noteFileDownloadPath('/tmp', fileId: 'f1', name: 'Plan.pdf');
    final second = noteFileDownloadPath('/tmp', fileId: 'f2', name: 'Plan.pdf');

    expect(first, isNot(second));
    expect(first, endsWith('/Plan.pdf'));
  });

  test('a name or id cannot leave the download folder', () {
    expect(
      noteFileDownloadPath('/tmp', fileId: '../x', name: '../../etc/passwd'),
      '/tmp/note-files/___x/.._.._etc_passwd',
    );
  });
}
