import 'package:checks/checks.dart';
import 'package:conduit_core/features/web_embed/web_embed_document.dart';
import 'package:test/test.dart';

void main() {
  group('isRemoteWebEmbedSource', () {
    test('recognizes http, https and protocol-relative URLs', () {
      for (final source in [
        'http://host/page',
        'https://host/page',
        '//host/page',
        '  https://host/page',
        '\n//host/page  ',
      ]) {
        check(because: source, isRemoteWebEmbedSource(source)).isTrue();
      }
    });

    test('treats anything else as inline HTML', () {
      for (final source in ['<p>hi</p>', 'ftp://host', 'host/page', '']) {
        check(because: source, isRemoteWebEmbedSource(source)).isFalse();
      }
    });
  });

  group('resolveRemoteWebEmbedUri', () {
    test('resolves // to https', () {
      check(resolveRemoteWebEmbedUri('//host/page?x=1').toString())
          .equals('https://host/page?x=1');
    });

    test('ignores surrounding whitespace, as the remote check does', () {
      check(resolveRemoteWebEmbedUri('  //host/page').toString())
          .equals('https://host/page');
      check(resolveRemoteWebEmbedUri('  https://host/page \n').toString())
          .equals('https://host/page');
    });

    test('keeps http and https as given', () {
      check(resolveRemoteWebEmbedUri('http://host:8080/a').toString())
          .equals('http://host:8080/a');
    });

    test('is null for inline HTML', () {
      check(resolveRemoteWebEmbedUri('<p>hi</p>')).isNull();
    });

    test('is null when no host is named', () {
      check(resolveRemoteWebEmbedUri('https://')).isNull();
      check(resolveRemoteWebEmbedUri('//')).isNull();
      check(resolveRemoteWebEmbedUri('http:///page')).isNull();
    });
  });
}
