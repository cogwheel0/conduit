# Vendored from `ddgs`

This package is derived from [`ddgs`](https://pub.dev/packages/ddgs) 0.3.2
(<https://github.com/kamranxdev/ddgs>, MIT, see `LICENSE`), itself a Dart
port of the Python [`ddgs`](https://github.com/deedy5/ddgs) library.

It is vendored rather than depended on because 0.3.2 could not be used
as-is:

- it pins `xml ^6.3.0`, which conflicts with the workspace's `xml ^7`, even
  though no library code imports `xml`;
- the DuckDuckGo engine read each result's *display* URL text instead of its
  link, so every `href` was a bare host fragment;
- the Wikipedia engine requested the JSON API but parsed the response as
  HTML, so it could never return a result;
- `proxy` and `verify` were accepted and ignored, engine errors went to
  `print`, requests could not be cancelled, and every engine created its own
  `http.Client`.

## What changed

- Only the text engines that return results from a plain HTTP client are
  kept: DuckDuckGo, Brave, Bing, Mojeek and Wikipedia. Google (JavaScript
  only), Yahoo, Startpage, Ecosia, Qwant and Yandex were dropped after live
  probes on 2026-09-29 returned errors, captchas or empty pages.
- The caller owns the `http.Client`; requests are `AbortableRequest`s so a
  search can be cancelled mid-flight.
- Results are typed (`WebSearchResult`), links are unwrapped from engine
  redirectors, ads are skipped, and captcha / rate-limit pages count as a
  `blocked` `SearchEngineException` instead of parsing as zero results.
- `Ddgs.search` tries engines in a fixed order, stops at the first engine
  with results, and cools a blocked engine down instead of retrying it on
  every query.
- Repeated URLs keep their first position but the copy with the longer
  snippet, so DuckDuckGo's "Official site" card doesn't hide the organic
  result's title.
- Images, videos, news, maps, translations, instant answers, streaming,
  caching and the CLI were removed.

## Maintaining the scrapers

`dart run tool/live_smoke.dart [query]` queries every engine for real and
reports results, blocks (`~`) and empty answers (`∅`). Engines block
aggressively, so a single run from a busy address proves little; a parser is
broken when an engine keeps answering with results pages that parse to
nothing.

When markup changes, capture a fresh page through Dart's HTTP client (not
curl: DuckDuckGo challenges curl's TLS fingerprint where it serves Dart),
strip scripts and styles, check it for anything identifying, replace the
fixture under `test/fixtures/`, and adjust the selectors in
`lib/src/engines/`. `mojeek_results.html` and
`duckduckgo_wrapped_links.html` are hand-written; every other fixture was
captured on 2026-09-29.
