import 'package:conduit_core/services/settings_service.dart'
    show messageActionIds;

import '../../l10n/app_localizations.dart';

/// Stable action identifiers shared by the response footer and settings
/// renderers, with their labels and SF Symbols. The ids and their order are
/// core's ([messageActionIds]), so every host lists the same actions.
List<({String id, String label, String symbol})> messageActionSettings(
  AppLocalizations l10n,
) => [
  for (final id in messageActionIds)
    switch (id) {
      'copy' => (id: id, label: l10n.copy, symbol: 'square.on.square'),
      'tts' => (id: id, label: l10n.ttsListen, symbol: 'speaker.wave.2'),
      'regenerate' => (
        id: id,
        label: l10n.regenerate,
        symbol: 'arrow.clockwise',
      ),
      'retry-without-effort' => (
        id: id,
        label: l10n.retryWithoutReasoningEffort,
        symbol: 'slash.circle',
      ),
      'merge' => (
        id: id,
        label: l10n.chatMergeResponsesAction,
        symbol: 'arrow.triangle.merge',
      ),
      'usage' => (id: id, label: l10n.usageInfo, symbol: 'info.circle'),
      'fork' => (
        id: id,
        label: l10n.chatBranchForkChat,
        symbol: 'arrow.triangle.branch',
      ),
      'share' => (
        id: id,
        label: l10n.shareSystemSheet,
        symbol: 'square.and.arrow.up',
      ),
      'delete' => (id: id, label: l10n.delete, symbol: 'trash'),
      _ => throw StateError('no label for message action $id'),
    },
];
