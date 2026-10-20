import 'package:conduit_core/features/web_search/services/web_page_extractor.dart';
import 'package:conduit_core/features/web_search/services/web_page_fetcher.dart';
import 'package:test/test.dart';

ExtractedWebPage _extract(String body, {String contentType = 'text/html'}) =>
    extractReadableText(
      FetchedWebPage(
        url: Uri.parse('https://example.com/post'),
        contentType: contentType,
        body: body,
        truncated: false,
      ),
    );

final _paragraph = 'Dart compiles to native code and JavaScript. ' * 8;

void main() {
  test('keeps the article structure and drops page furniture', () {
    final page = _extract('''
<html>
<head>
  <title>Ignored title</title>
  <meta property="og:title" content="Dart 3.13 released">
  <script>var tracking = "script text";</script>
</head>
<body>
  <header><nav><a href="/">Home</a> | <a href="/about">About</a></nav></header>
  <div class="cookie-banner">We use cookies. Accept all?</div>
  <article>
    <h1>Dart 3.13</h1>
    <p>$_paragraph</p>
    <h2>What changed</h2>
    <ul><li>Faster <code>build_runner</code></li><li>New lints</li></ul>
    <pre>void main() {
  print('hi');
}</pre>
  </article>
  <aside>Popular posts</aside>
  <footer>Copyright</footer>
</body>
</html>''');

    expect(page.title, 'Dart 3.13 released');
    expect(page.text, startsWith('# Dart 3.13'));
    expect(page.text, contains('## What changed'));
    expect(page.text, contains('- Faster `build_runner`'));
    expect(page.text, contains("```\nvoid main() {\n  print('hi');\n}\n```"));
    for (final furniture in [
      'Home',
      'cookies',
      'Popular posts',
      'Copyright',
      'script text',
    ]) {
      expect(page.text, isNot(contains(furniture)), reason: furniture);
    }
  });

  test('a content wrapper with a sidebar-like class is kept', () {
    final page = _extract('''
<html><body>
  <div class="layout has-sidebar"><p>$_paragraph</p></div>
  <div class="sidebar">Popular posts</div>
</body></html>''');

    expect(page.text, contains('Dart compiles to native code'));
    expect(page.text, isNot(contains('Popular posts')));
  });

  test('an article keeps its own header and code keeps its fence', () {
    final page = _extract('''
<html><body>
  <header>Site navigation</header>
  <article>
    <header><h1>Release notes</h1><p>By the Dart team</p></header>
    <p>$_paragraph</p>
    <pre>echo "```"
done</pre>
  </article>
</body></html>''');

    expect(page.text, contains('By the Dart team'));
    expect(page.text, isNot(contains('Site navigation')));
    // A fence longer than the backticks inside keeps the block intact.
    expect(page.text, contains('````\necho "```"\ndone\n````'));
  });

  test('plain text keeps its indentation', () {
    final page = _extract(
      '- item\n    - nested\n\n    code()',
      contentType: 'text/markdown',
    );
    expect(page.text, '- item\n    - nested\n\n    code()');
  });

  test('plain text is returned without HTML parsing', () {
    final page = _extract(
      '# Notes\n\n\n\n<b>not a tag</b>\n',
      contentType: 'text/plain',
    );
    expect(page.text, '# Notes\n\n<b>not a tag</b>');
  });
}
