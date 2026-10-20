import 'package:checks/checks.dart';
import 'package:conduit_core/features/terminal/controllers/terminal_controller_gateways.dart';
import 'package:test/test.dart';

void main() {
  // The download name comes from the server's Content-Disposition header, so it
  // is untrusted input reaching a filesystem destination.
  test('download names cannot steer the save location', () {
    String sanitize(String name) => safeTerminalFileName(name);

    check(sanitize('report.txt')).equals('report.txt');
    check(sanitize('../../etc/passwd')).equals('.._.._etc_passwd');
    check(sanitize('/etc/passwd')).equals('_etc_passwd');
    check(sanitize(r'..\..\evil.exe')).equals('.._.._evil.exe');
    check(sanitize('a:b*c?"d<e>f|g.txt')).equals('a_b_c__d_e_f_g.txt');
    check(sanitize('line\nbreak\x00.txt')).equals('line_break_.txt');

    // A direction override would disguise the extension in a save dialog.
    check(sanitize('report\u202Egnp.exe')).equals('report_gnp.exe');
    check(sanitize('a\u200Eb\u061Cc\u2066d\u2069.txt')).equals('a_b_c_d_.txt');

    // Characters that cannot steer a path are kept, so distinct names stay
    // distinct.
    check(sanitize('报告 (final).pdf')).equals('报告 (final).pdf');
    check(sanitize('报告.pdf')).not((it) => it.equals(sanitize('結果.pdf')));

    // Pure dot components survive character sanitization but name a directory,
    // so they must fall back rather than produce an unwritable target.
    for (final name in <String>['', '.', '..']) {
      check(sanitize(name)).startsWith('terminal_file_');
    }
  });
}
