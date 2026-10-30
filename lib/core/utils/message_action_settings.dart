import '../../l10n/app_localizations.dart';

/// Stable action identifiers shared by the response footer and settings renderers.
List<({String id, String label, String symbol})> messageActionSettings(
  AppLocalizations l10n,
) => [
  (id: 'copy', label: l10n.copy, symbol: 'doc.on.doc'),
  (id: 'tts', label: l10n.ttsListen, symbol: 'speaker.wave.2'),
  (id: 'regenerate', label: l10n.regenerate, symbol: 'arrow.clockwise'),
  (
    id: 'merge',
    label: l10n.chatMergeResponsesAction,
    symbol: 'arrow.triangle.merge',
  ),
  (id: 'usage', label: l10n.usageInfo, symbol: 'info.circle'),
  (id: 'fork', label: l10n.chatBranchForkChat, symbol: 'arrow.triangle.branch'),
  (id: 'share', label: l10n.shareSystemSheet, symbol: 'square.and.arrow.up'),
  (id: 'delete', label: l10n.delete, symbol: 'trash'),
];
