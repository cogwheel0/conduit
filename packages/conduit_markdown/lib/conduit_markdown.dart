/// Markdown preprocessing and the parsers that turn a model's output into a
/// block model.
///
/// Pure Dart with no Flutter and no `dart:io`, so the desktop renderer can
/// import it: parsing happens once, here, and each front-end only turns the
/// resulting blocks into its own widgets or DOM.
library;

export 'src/citation_parser.dart';
export 'src/details_block_syntax.dart';
export 'src/embed_utils.dart';
export 'src/markdown_preprocessor.dart';
export 'src/mention_inline_syntax.dart';
export 'src/message_segments.dart';
export 'src/reasoning_parser.dart';
export 'src/semantic_details.dart';
export 'src/speech_text.dart';
export 'src/tool_calls_parser.dart';
