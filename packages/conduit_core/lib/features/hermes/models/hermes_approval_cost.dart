/// A number as Hermes formats a cost: `5`, `1,250`, `0.25`.
const String _amount = r'\d{1,3}(?:,\d{3})*(?:\.\d+)?|\d+(?:\.\d+)?';

/// `Costs about 5 credits.`, `Costs 2-5 credits (per image).`
/// (`tools/mcp_tool_costs.py` `cost_sentence`).
final RegExp _costSentence = RegExp(
  '(?:^|(?<=\\s))Costs (?:about (?<about>$_amount)|'
  '(?<low>$_amount)-(?<high>$_amount)) (?<unit>[^().\\n]{1,40}?)'
  '(?: \\((?<note>[^)\\n]{1,200})\\))?\\.(?=\\s|\$)',
);

/// `This chat has used about 20 credits on 'shop' (limit 50).`
final RegExp _spentSentence = RegExp(
  "(?:^|(?<=\\s))This chat has used about (?<spent>$_amount) "
  "(?<unit>[^().'\\n]{1,40}?) on '(?<server>[^'\\n]{1,128})'"
  '(?: \\(limit (?<limit>$_amount)\\))?\\.(?=\\s|\$)',
);

/// `Spend limit for this chat on 'shop': 50 credits.`
final RegExp _limitSentence = RegExp(
  "(?:^|(?<=\\s))Spend limit for this chat on '(?<server>[^'\\n]{1,128})': "
  '(?<limit>$_amount) (?<unit>[^.\\n]{1,40}?)\\.(?=\\s|\$)',
);

/// The two ways Hermes says a call would pass the chat's spend limit
/// (`tools/mcp_tool_handlers.py`).
final RegExp _overLimitSentence = RegExp(
  "(?:^|(?<=\\s))(?:This call goes past the chat's spend limit\\.|"
  "MCP tool '[^'\\n]{1,128}' on server '[^'\\n]{1,128}' would take this "
  'chat past its spend limit\\.)(?=\\s|\$)',
);

/// What a paid MCP tool's approval says about its price, read from the
/// fixed sentences Hermes puts in the approval's text.
final class HermesApprovalCost {
  const HermesApprovalCost({
    this.cost,
    this.approximate = false,
    this.note,
    this.spent,
    this.limit,
    this.server,
    this.overLimit = false,
    this.remainder = '',
  });

  /// The call's price as Hermes wrote it: `5 credits`, `2-5 credits`.
  final String? cost;

  /// Whether [cost] is one estimate ("about") rather than a range.
  final bool approximate;

  /// Hermes' note on the price, such as `per image`.
  final String? note;

  /// What the chat spent on the server so far: `20 credits`.
  final String? spent;

  /// The chat's spend limit on the server: `50`, or `50 credits` when the
  /// chat spent nothing yet.
  final String? limit;

  final String? server;

  /// Whether this call would take the chat past its spend limit; Hermes
  /// then takes the approval for this call only.
  final bool overLimit;

  /// The approval's text without the sentences read here.
  final String remainder;

  bool get hasDetails =>
      cost != null || spent != null || limit != null || overLimit;

  Map<String, Object?> toJson() => {
    'cost': ?cost,
    if (approximate) 'approximate': true,
    'note': ?note,
    'spent': ?spent,
    'limit': ?limit,
    'server': ?server,
    if (overLimit) 'overLimit': true,
  };

  static HermesApprovalCost? fromJson(Object? raw) {
    if (raw is! Map) return null;
    String? text(String key) {
      final value = raw[key];
      return value is String && value.isNotEmpty && value.length <= 200
          ? value
          : null;
    }

    final cost = HermesApprovalCost(
      cost: text('cost'),
      approximate: raw['approximate'] == true,
      note: text('note'),
      spent: text('spent'),
      limit: text('limit'),
      server: text('server'),
      overLimit: raw['overLimit'] == true,
    );
    return cost.hasDetails ? cost : null;
  }
}

/// The price, spend and limit an approval's [texts] state, from the first
/// text that states any; null when none does. Text Conduit does not
/// recognise stays in [HermesApprovalCost.remainder] as it was.
HermesApprovalCost? parseHermesApprovalCost(Iterable<String?> texts) {
  for (final text in texts) {
    if (text == null || text.isEmpty || text.length > 16384) continue;
    final cost = _parse(text);
    if (cost != null) return cost;
  }
  return null;
}

HermesApprovalCost? _parse(String text) {
  final costMatch = _costSentence.firstMatch(text);
  final spentMatch = _spentSentence.firstMatch(text);
  final limitMatch = spentMatch == null
      ? _limitSentence.firstMatch(text)
      : null;
  final overLimit = _overLimitSentence.hasMatch(text);
  if (costMatch == null &&
      spentMatch == null &&
      limitMatch == null &&
      !overLimit) {
    return null;
  }
  String? cost;
  var approximate = false;
  if (costMatch != null) {
    final unit = costMatch.namedGroup('unit')!.trim();
    final about = costMatch.namedGroup('about');
    approximate = about != null;
    cost = about != null
        ? '$about $unit'
        : '${costMatch.namedGroup('low')}–'
              '${costMatch.namedGroup('high')} $unit';
  }
  // Each sentence read leaves one space behind, however many sat in a
  // row; everything else (an arguments block's indentation) is untouched.
  final remainder = text
      .replaceAll(_overLimitSentence, '\u0000')
      .replaceAll(_costSentence, '\u0000')
      .replaceAll(_spentSentence, '\u0000')
      .replaceAll(_limitSentence, '\u0000')
      .replaceAll(RegExp('(?:[ \\t]*\u0000)+[ \\t]*'), ' ')
      .replaceAll(RegExp(' \n'), '\n')
      .trim();
  return HermesApprovalCost(
    cost: cost,
    approximate: approximate,
    note: costMatch?.namedGroup('note')?.trim(),
    spent: spentMatch == null
        ? null
        : '${spentMatch.namedGroup('spent')} '
              '${spentMatch.namedGroup('unit')!.trim()}',
    limit:
        spentMatch?.namedGroup('limit') ??
        (limitMatch == null
            ? null
            : '${limitMatch.namedGroup('limit')} '
                  '${limitMatch.namedGroup('unit')!.trim()}'),
    server:
        spentMatch?.namedGroup('server') ?? limitMatch?.namedGroup('server'),
    overLimit: overLimit,
    remainder: remainder,
  );
}
