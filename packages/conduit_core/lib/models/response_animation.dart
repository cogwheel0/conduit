/// Device-local choices for the small response indicator.
enum ResponseIndicatorStyle {
  scan('04 Scan', 2600),
  fold('06 Fold', 2700),
  facets('08 Facets', 3300),
  gather('09 Gather', 3000),
  exchange('14 Exchange', 2500);

  const ResponseIndicatorStyle(this.label, this.cycleMilliseconds);

  final String label;
  final int cycleMilliseconds;

  static const thinkingChoices = [scan, fold, facets, gather];
  static const skillChoices = [exchange, fold];

  static ResponseIndicatorStyle fromStorage(
    String? value, {
    required List<ResponseIndicatorStyle> choices,
    required ResponseIndicatorStyle fallback,
  }) => choices.where((style) => style.name == value).firstOrNull ?? fallback;
}

enum ResponseFinishStyle {
  fade('Fade out'),
  shrink('Shrink and fade'),
  clear('Clear immediately');

  const ResponseFinishStyle(this.label);
  final String label;

  static ResponseFinishStyle fromStorage(String? value) =>
      values.where((style) => style.name == value).firstOrNull ?? fade;
}
