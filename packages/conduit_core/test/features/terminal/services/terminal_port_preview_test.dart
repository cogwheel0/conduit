import 'package:checks/checks.dart';
import 'package:conduit_core/features/terminal/services/terminal_port_preview.dart';
import 'package:test/test.dart';

void main() {
  final owui = Uri.parse('https://owui.test/base/api/v1/terminals/t1');
  const session = TerminalBrowserSession(id: 'sid', token: 'ticket.part');
  const view = 'https://owui.test/base/api/v1/terminals/t1/browser/view/'
      'sid/ticket.part';

  group('through a browser session', () {
    final navigator = TerminalPreviewNavigator.session(
      terminalBaseUri: owui,
      session: session,
    );

    test('frames pages the way Open WebUI builds them', () {
      check(
        navigator.pageUri(Uri.parse('http://localhost:5173/docs?x=1#top')),
      ).equals(Uri.parse('$view/frame/http/localhost%3A5173/docs?x=1#top'));
      check(
        navigator.pageUri(Uri.parse('http://localhost:5173')),
      ).equals(Uri.parse('$view/frame/http/localhost%3A5173/'));
      check(
        navigator.pageUri(Uri.parse('https://[::1]:8443/a')),
      ).equals(Uri.parse('$view/frame/https/%5B%3A%3A1%5D%3A8443/a'));
      check(navigator.headers).isEmpty();
      check(navigator.usesSession).isTrue();
      check(navigator.pagesOpenElsewhere).isTrue();
      // Open Terminal's session script sends forms through the session.
      check(navigator.formTarget).isNull();
    });

    test('reads the address back from a framed page', () {
      for (final remote in [
        'http://localhost:5173/docs?x=1#top',
        'http://localhost:5173/',
        'https://example.com/path/to',
        'https://[::1]:8443/a',
      ]) {
        final uri = Uri.parse(remote);
        check(
          navigator.remoteUri(navigator.pageUri(uri)),
          because: remote,
        ).equals(uri);
      }
      check(navigator.remoteUri(Uri.parse('$view/runtime.js'))).isNull();
      check(navigator.remoteUri(Uri.parse('$view/frame/ftp/x/y'))).isNull();
      // A page can name any address; one whose escapes are not UTF-8 is
      // none of the terminal's, and the rules still answer for it.
      for (final authority in ['%FF', '%E2%82']) {
        final page = Uri.parse('$view/frame/http/$authority/');
        check(navigator.remoteUri(page), because: authority).isNull();
        check(
          navigator.decide(page),
          because: authority,
        ).isA<TerminalPreviewAllow>();
      }
      check(
        navigator.remoteUri(
          Uri.parse('https://other.test/base/api/v1/terminals/t1/browser/'
              'view/sid/ticket.part/frame/http/localhost%3A1/'),
        ),
      ).isNull();
    });

    test('keeps the terminal\'s pages and sends the rest out', () {
      check(
        navigator.decide(Uri.parse('$view/frame/http/localhost%3A5173/a')),
      ).isA<TerminalPreviewAllow>();
      check(
        navigator.decide(Uri.parse('$view/frame/https/example.com/a?b=1')),
      ).isA<TerminalPreviewOpenExternally>().has((d) => d.uri, 'uri').equals(
        Uri.parse('https://example.com/a?b=1'),
      );
      // A popup or a link the page reported, at its address on the machine.
      check(
        navigator.decide(Uri.parse('http://localhost:3000/x')),
      ).isA<TerminalPreviewLoad>()
        ..has((d) => d.uri, 'uri').equals(
          Uri.parse('$view/frame/http/localhost%3A3000/x'),
        )
        ..has((d) => d.headers, 'headers').isEmpty();
      check(
        navigator.decide(Uri.parse('https://example.com/')),
      ).isA<TerminalPreviewOpenExternally>();
      // The session's own resources, and nothing else of Open WebUI's.
      check(
        navigator.decide(Uri.parse('$view/runtime.js')),
      ).isA<TerminalPreviewAllow>();
      check(
        navigator.decide(Uri.parse('https://owui.test/base/')),
      ).isA<TerminalPreviewBlock>();
      check(
        navigator.decide(Uri.parse('https://owui.test/base/api/v1/chats/')),
      ).isA<TerminalPreviewBlock>();
      check(
        navigator.decide(Uri.parse('mailto:dev@example.com')),
      ).isA<TerminalPreviewOpenExternally>();
      check(
        navigator.decide(Uri.parse('about:blank')),
      ).isA<TerminalPreviewAllow>();
    });
  });

  group('through Open WebUI\'s port proxy', () {
    final navigator = TerminalPreviewNavigator.proxy(
      terminalBaseUri: owui,
      bearerToken: ' jwt ',
    );
    const proxy = 'https://owui.test/base/api/v1/terminals/t1/proxy';

    test('maps pages to the proxy and back', () {
      check(
        navigator.pageUri(Uri.parse('http://localhost:3000/a/b?c=d#e')),
      ).equals(Uri.parse('$proxy/3000/a/b?c=d#e'));
      check(
        navigator.pageUri(Uri.parse('http://localhost:3000')),
      ).equals(Uri.parse('$proxy/3000/'));
      check(
        navigator.remoteUri(Uri.parse('$proxy/3000/a/b?c=d#e')),
      ).equals(Uri.parse('http://localhost:3000/a/b?c=d#e'));
      check(
        navigator.remoteUri(Uri.parse('$proxy/3000')),
      ).equals(Uri.parse('http://localhost:3000/'));
      check(navigator.remoteUri(Uri.parse('$proxy/nope/'))).isNull();
      check(navigator.remoteUri(Uri.parse('$proxy/70000/'))).isNull();
      check(navigator.headers).deepEquals({'Authorization': 'Bearer jwt'});
      check(navigator.pagesOpenElsewhere).isFalse();
      // A form the page posts could not carry the credential.
      check(navigator.formTarget).isNull();
    });

    test('makes each page load itself, with the credential', () {
      final page = Uri.parse('$proxy/3000/next');
      check(navigator.decide(page)).isA<TerminalPreviewLoad>()
        ..has((d) => d.uri, 'uri').equals(page)
        ..has((d) => d.headers, 'headers').deepEquals({
          'Authorization': 'Bearer jwt',
        });
      check(
        navigator.decide(page, reissued: true),
      ).isA<TerminalPreviewAllow>();
      check(navigator.decide(page, history: true)).isA<TerminalPreviewAllow>();
    });

    test('follows a reported link into the proxy', () {
      // What Open WebUI's rewritten page posts for a link to another page.
      check(
        navigator.decide(Uri.parse('http://localhost:3000/about?q=1')),
      ).isA<TerminalPreviewLoad>().has((d) => d.uri, 'uri').equals(
        Uri.parse('$proxy/3000/about?q=1'),
      );
      check(
        navigator.decide(Uri.parse('http://127.0.0.1:8080/')),
      ).isA<TerminalPreviewLoad>().has((d) => d.uri, 'uri').equals(
        Uri.parse('$proxy/8080/'),
      );
    });

    test('never opens Open WebUI itself in the preview', () {
      for (final page in [
        'https://owui.test/base/',
        'https://owui.test/base/api/v1/chats/',
        'https://owui.test/base/api/v1/terminals/t1/files/list',
      ]) {
        check(
          navigator.decide(Uri.parse(page)),
          because: page,
        ).isA<TerminalPreviewBlock>();
      }
      check(
        navigator.decide(Uri.parse('https://docs.example.com/')),
      ).isA<TerminalPreviewOpenExternally>();
    });
  });

  test('the proxy of a direct terminal without a key needs no credential', () {
    final navigator = TerminalPreviewNavigator.proxy(
      terminalBaseUri: Uri.parse('http://10.0.0.5:8000/'),
    );
    final page = navigator.pageUri(Uri.parse('http://localhost:3000/'));

    check(page).equals(Uri.parse('http://10.0.0.5:8000/proxy/3000/'));
    check(navigator.decide(page)).isA<TerminalPreviewAllow>();
    check(navigator.headers).isEmpty();
    check(navigator.pagesOpenElsewhere).isTrue();
    // Open Terminal's proxy shows pages as they are, so their forms aimed at
    // the terminal's machine are sent through it by the app's script.
    check(navigator.formTarget).equals('http://10.0.0.5:8000/proxy');
  });

  test('the preview starts at the port and names it briefly', () {
    final preview = TerminalPortPreview(port: 5173, terminalBaseUri: owui);

    check(preview.startUri).equals(Uri.parse('http://localhost:5173/'));
    check(
      TerminalPreviewNavigator.displayAddress(preview.startUri),
    ).equals('localhost:5173');
    check(
      TerminalPreviewNavigator.displayAddress(
        Uri.parse('http://localhost:5173/docs?page=2'),
      ),
    ).equals('localhost:5173/docs?page=2');
    check(isTerminalLocalUri(Uri.parse('http://0.0.0.0:1/'))).isTrue();
    check(isTerminalLocalUri(Uri.parse('http://example.com/'))).isFalse();
    check(isTerminalLocalUri(Uri.parse('ftp://localhost/'))).isFalse();
  });
}
