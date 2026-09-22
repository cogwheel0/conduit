import 'package:highlight/highlight_core.dart';
import 'package:highlight/languages/bash.dart';
import 'package:highlight/languages/cpp.dart';
import 'package:highlight/languages/cs.dart';
import 'package:highlight/languages/css.dart';
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/diff.dart';
import 'package:highlight/languages/dockerfile.dart';
import 'package:highlight/languages/elixir.dart';
import 'package:highlight/languages/go.dart';
import 'package:highlight/languages/graphql.dart';
import 'package:highlight/languages/haskell.dart';
import 'package:highlight/languages/ini.dart';
import 'package:highlight/languages/java.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/kotlin.dart';
import 'package:highlight/languages/less.dart';
import 'package:highlight/languages/lua.dart';
import 'package:highlight/languages/makefile.dart';
import 'package:highlight/languages/markdown.dart';
import 'package:highlight/languages/nginx.dart';
import 'package:highlight/languages/objectivec.dart';
import 'package:highlight/languages/perl.dart';
import 'package:highlight/languages/php.dart';
import 'package:highlight/languages/powershell.dart';
import 'package:highlight/languages/protobuf.dart';
import 'package:highlight/languages/python.dart';
import 'package:highlight/languages/r.dart';
import 'package:highlight/languages/ruby.dart';
import 'package:highlight/languages/rust.dart';
import 'package:highlight/languages/scala.dart';
import 'package:highlight/languages/scss.dart';
import 'package:highlight/languages/sql.dart';
import 'package:highlight/languages/swift.dart';
import 'package:highlight/languages/typescript.dart';
import 'package:highlight/languages/xml.dart';
import 'package:highlight/languages/yaml.dart';

/// The languages a code block can be highlighted in (WP-3.5).
///
/// Its own library, and one that never imports Jaspr: the language modes are
/// top-level names like `css` and `code`, and half of them collide with the
/// DOM element functions. Keeping them apart is cheaper than prefixing
/// thirty-eight imports.
///
/// Registered explicitly rather than through `package:highlight/highlight.dart`,
/// whose top-level instance pulls in all 190 definitions -- close to two
/// megabytes of Dart that dart2js cannot tree-shake, because the
/// `allLanguages` map references every one. These are what people paste into
/// a chat. Anything else renders as plain monospace, which is what every
/// block did before this existed.
final Map<String, Mode> codeLanguages = <String, Mode>{
  'bash': bash,
  'cpp': cpp,
  'csharp': cs,
  'css': css,
  'dart': dart,
  'diff': diff,
  'dockerfile': dockerfile,
  'elixir': elixir,
  'go': go,
  'graphql': graphql,
  'haskell': haskell,
  'ini': ini,
  'java': java,
  'javascript': javascript,
  'json': json,
  'kotlin': kotlin,
  'less': less,
  'lua': lua,
  'makefile': makefile,
  'markdown': markdown,
  'nginx': nginx,
  'objectivec': objectivec,
  'perl': perl,
  'php': php,
  'powershell': powershell,
  'protobuf': protobuf,
  'python': python,
  'r': r,
  'ruby': ruby,
  'rust': rust,
  'scala': scala,
  'scss': scss,
  'sql': sql,
  'swift': swift,
  'typescript': typescript,
  'xml': xml,
  'yaml': yaml,
};

final Highlight codeHighlighter = Highlight()..registerLanguages(codeLanguages);

/// The registered language [info] names, or null if none does.
///
/// Fences carry whatever the author typed -- `sh`, `yml`, `c++`, `Dockerfile`,
/// or a word plus attributes like ```` ```js title="a.js" ```` -- so an exact
/// lookup misses most of them, and a block tagged `js` rendering plain looks
/// like the highlighter is broken rather than unasked.
String? resolveLanguage(String? info) {
  if (info == null) return null;
  final word = info.trim().split(RegExp(r'[\s,:{]')).first.toLowerCase();
  if (word.isEmpty) return null;
  final canonical = languageAliases[word] ?? word;
  return codeLanguages.containsKey(canonical) ? canonical : null;
}

/// What people actually write in a fence, mapped to what is registered.
const Map<String, String> languageAliases = <String, String>{
  'sh': 'bash',
  'zsh': 'bash',
  'shell': 'bash',
  'console': 'bash',
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'node': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'py': 'python',
  'python3': 'python',
  'rb': 'ruby',
  'rs': 'rust',
  'golang': 'go',
  // highlight.js 9, which this port mirrors, has no separate C grammar;
  // its C++ one handles both.
  'c': 'cpp',
  'c++': 'cpp',
  'cc': 'cpp',
  'h': 'cpp',
  'hpp': 'cpp',
  'cs': 'csharp',
  'c#': 'csharp',
  'objc': 'objectivec',
  'yml': 'yaml',
  'html': 'xml',
  'svg': 'xml',
  'xhtml': 'xml',
  'md': 'markdown',
  'ps1': 'powershell',
  'pwsh': 'powershell',
  'docker': 'dockerfile',
  'make': 'makefile',
  'toml': 'ini',
  'conf': 'ini',
  'patch': 'diff',
  'proto': 'protobuf',
  'psql': 'sql',
  'mysql': 'sql',
  'sqlite': 'sql',
  'kt': 'kotlin',
  'ex': 'elixir',
  'exs': 'elixir',
  'hs': 'haskell',
  'pl': 'perl',
};
