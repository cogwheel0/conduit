/// FTS5 MATCH query sanitizer (CDT-RFC-001 Phase 4 §G).
///
/// FTS5 MATCH syntax treats `"`, `(`, `)`, `*`, `:`, `^` and the bareword
/// operators `AND`/`OR`/`NOT`/`NEAR` as operators; an unbalanced quote or a
/// bare operator THROWS at query time (SQLite raises an "fts5: syntax error"
/// which surfaces as a SqliteException). This function turns arbitrary user
/// text into a safe prefix-AND match expression that can never raise.
///
/// Strategy: tokenize on Unicode whitespace, wrap each token as an FTS5
/// quoted phrase (escaping embedded `"` by doubling) so every special
/// character inside loses its operator meaning, then append a trailing `*` for
/// type-ahead prefix matching. Tokens are joined with implicit AND (a space).
///
/// Empty or whitespace-only input returns `''`; the caller MUST short-circuit
/// on `''` and return no results (never run `MATCH ''`).
library;

/// Matches any run of Unicode whitespace (covers ASCII spaces/tabs/newlines
/// plus NBSP and other Unicode spaces).
final RegExp _whitespace = RegExp(r'\s+', unicode: true);

/// Converts arbitrary [raw] user input into a safe FTS5 MATCH expression.
///
/// Returns `''` when the input has no indexable content (empty or whitespace).
/// The result, when non-empty, is always a syntactically valid MATCH
/// expression: a space-joined list of quoted-phrase prefix terms like
/// `"foo"* "bar"*`.
String toFtsMatchQuery(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';

  final terms = <String>[];
  for (final token in trimmed.split(_whitespace)) {
    if (token.isEmpty) continue;
    final term = _quoteToken(token);
    if (term == null) continue;
    terms.add(term);
  }

  if (terms.isEmpty) return '';
  return terms.join(' ');
}

/// Wraps a single [token] as an FTS5 quoted-phrase prefix term: `"<esc>"*`.
///
/// Embedded double-quotes are escaped by doubling them (`"` -> `""`), which is
/// how FTS5 (like SQL string literals) escapes a quote inside a quoted string.
/// Inside a quoted phrase every other special character is a literal, so
/// `(`, `)`, `*`, `:`, `^`, `AND`, `NEAR/2`, etc. all lose operator meaning.
///
/// The trailing `*` (placed AFTER the closing quote) requests a prefix match on
/// the phrase's final token — FTS5 accepts `"phrase"*`. Returns `null` when the
/// token contributes nothing after escaping (e.g. an empty string), so the
/// caller can skip it.
String? _quoteToken(String token) {
  if (token.isEmpty) return null;
  final escaped = token.replaceAll('"', '""');
  return '"$escaped"*';
}
