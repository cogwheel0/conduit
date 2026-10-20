// Live check of every engine against the real services. Not run in CI:
// results depend on the network, and repeated runs from one address earn
// captchas.
//
//   cd packages/conduit_ddgs && dart run tool/live_smoke.dart [query]
//
// A captcha or rate limit (~) says nothing about the parsers. An empty
// answer (∅) is ambiguous: Bing, for one, serves a real "no results" page to
// clients it suspects of scraping. Exits non-zero only when every engine
// that answered came back empty, the signature of changed markup; rerun
// with another query before trusting a single ∅.
import 'dart:io';

import 'package:conduit_ddgs/conduit_ddgs.dart';
import 'package:http/http.dart' as http;

Future<void> main(List<String> args) async {
  final text = args.isEmpty ? 'dart programming language' : args.join(' ');
  final query = SearchQuery(text, region: SearchRegion('us-en'));
  final client = http.Client();
  final ddgs = Ddgs(client: client);
  var answered = 0;
  var withResults = 0;

  for (final id in SearchEngineId.values) {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await ddgs.search(query, engine: id, maxResults: 3);
      final ms = stopwatch.elapsedMilliseconds;
      answered++;
      if (response.results.isEmpty) {
        stdout.writeln('∅ ${id.displayName}: answered, no results (${ms}ms)');
        continue;
      }
      withResults++;
      stdout.writeln(
        '✓ ${id.displayName}: ${response.results.length} (${ms}ms)',
      );
      for (final result in response.results) {
        stdout.writeln('    ${result.url}  ${result.title}');
      }
    } on WebSearchUnavailableException catch (error) {
      final failure = error.failures.single;
      stdout.writeln(
        '~ ${id.displayName}: ${failure.kind.name}'
        '${failure.statusCode == null ? '' : ' (HTTP ${failure.statusCode})'}',
      );
    }
  }
  client.close();
  exit(answered > 0 && withResults == 0 ? 1 : 0);
}
