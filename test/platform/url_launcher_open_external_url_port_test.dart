import 'package:conduit/platform/url_launcher_open_external_url_port.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only web addresses are handed to the browser', () async {
    const port = UrlLauncherOpenExternalUrlPort();
    // Refused before the platform is asked, so no plugin is needed here.
    expect(await port.open(Uri.parse('javascript:alert(1)')), isFalse);
    expect(await port.open(Uri.parse('file:///etc/passwd')), isFalse);
    expect(await port.open(Uri.parse('conduit://callback')), isFalse);
  });
}
