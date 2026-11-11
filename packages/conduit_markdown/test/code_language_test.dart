import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:test/test.dart';

void main() {
  test('common ids and aliases get their proper names', () {
    expect(codeLanguageDisplayName('python'), 'Python');
    expect(codeLanguageDisplayName('py'), 'Python');
    expect(codeLanguageDisplayName('js'), 'JavaScript');
    expect(codeLanguageDisplayName('TypeScript'), 'TypeScript');
    expect(codeLanguageDisplayName('cpp'), 'C++');
    expect(codeLanguageDisplayName('c++'), 'C++');
    expect(codeLanguageDisplayName('csharp'), 'C#');
    expect(codeLanguageDisplayName('objc'), 'Objective-C');
    expect(codeLanguageDisplayName('json'), 'JSON');
    expect(codeLanguageDisplayName(' yml '), 'YAML');
    expect(codeLanguageDisplayName('sh'), 'Shell');
  });

  test('plain text has no language name', () {
    expect(codeLanguageDisplayName(''), isNull);
    expect(codeLanguageDisplayName('plaintext'), isNull);
    expect(codeLanguageDisplayName('Text'), isNull);
  });

  test('unknown ids are title-cased word by word', () {
    expect(codeLanguageDisplayName('foolang'), 'Foolang');
    expect(codeLanguageDisplayName('my-lang'), 'My-Lang');
    expect(codeLanguageDisplayName('shell_session'), 'Shell Session');
  });

  test('unknown ids written with capitals keep their spelling', () {
    expect(codeLanguageDisplayName('PostScript'), 'PostScript');
  });
}
