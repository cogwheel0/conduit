import 'package:checks/checks.dart';
import 'package:conduit/features/terminal/controllers/terminal_controller_gateways.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The download name comes from the server's Content-Disposition header, so it
  // is untrusted input reaching a filesystem destination.
  test('download names cannot steer the save location', () {
    String sanitize(String name) =>
        DefaultTerminalBrowserPlatformGateway.safeFileName(name);

    check(sanitize('report.txt')).equals('report.txt');
    check(sanitize('../../etc/passwd')).equals('.._.._etc_passwd');
    check(sanitize('/etc/passwd')).equals('_etc_passwd');
    check(sanitize('a b;rm -rf.txt')).equals('a_b_rm_-rf.txt');

    // Pure dot components survive character sanitization but name a directory,
    // so they must fall back rather than produce an unwritable target.
    for (final name in <String>['', '.', '..']) {
      check(sanitize(name)).startsWith('terminal_file_');
    }
  });
}
