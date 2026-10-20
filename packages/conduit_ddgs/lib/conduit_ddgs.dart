/// Web search without a search service: scrapes DuckDuckGo, Brave, Bing and
/// Mojeek, with Wikipedia's API as a last resort.
///
/// Derived from the MIT-licensed `ddgs` package; see `VENDORED.md`.
library;

export 'src/ddgs.dart';
export 'src/engine.dart' show SearchEngine, SearchEngineRequest;
export 'src/engines/bing.dart' show BingEngine;
export 'src/engines/brave.dart' show BraveEngine;
export 'src/engines/duckduckgo.dart' show DuckDuckGoEngine;
export 'src/engines/mojeek.dart' show MojeekEngine;
export 'src/engines/wikipedia.dart' show WikipediaEngine;
export 'src/exceptions.dart';
export 'src/search_query.dart';
export 'src/search_result.dart';
