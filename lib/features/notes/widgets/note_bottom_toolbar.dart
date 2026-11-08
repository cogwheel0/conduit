import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/widgets.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';

/// What the note editor's toolbar menus offer.
enum NoteToolbarAction {
  dictation,
  recordAudio,
  enhance,
  generateTitle,
  copy,
  togglePin,
  delete,
}

/// The note editor's iOS 26 bottom toolbar, in the manner of Notes: voice and
/// AI on the leading side; Share, Pages and the note's other actions on the
/// trailing side.
///
/// On iOS 26 it takes the place of [NoteFloatingActions] and of the ⋯ menu
/// in the top bar. A read-only note shows only what reading allows: Pages,
/// Copy, and Pin.
class NoteBottomToolbar extends StatelessWidget {
  const NoteBottomToolbar({
    super.key,
    required this.readOnly,
    required this.isRecording,
    required this.isUploadingAudio,
    required this.isEnhancing,
    required this.isGeneratingTitle,
    required this.isPinned,
    required this.canShare,
    required this.hasPages,
    required this.onStopDictation,
    required this.onShare,
    required this.onPages,
    required this.onAction,
  });

  final bool readOnly;
  final bool isRecording;
  final bool isUploadingAudio;
  final bool isEnhancing;
  final bool isGeneratingTitle;
  final bool isPinned;

  /// Whether the Share button is offered (the note's access can be changed).
  final bool canShare;

  /// Whether the note has several pages, which the Pages button lists.
  final bool hasPages;

  final VoidCallback onStopDictation;
  final VoidCallback onShare;
  final VoidCallback onPages;
  final ValueChanged<NoteToolbarAction> onAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;

    return AdaptiveBottomToolbar(
      tint: theme.textPrimary,
      items: [
        if (!readOnly) ...[
          _voiceItem(l10n, theme.error),
          AdaptiveBottomToolbarMenu<NoteToolbarAction>(
            id: 'enhance',
            label: l10n.enhanceWithAI,
            sfSymbol: 'sparkles',
            enabled: !isEnhancing,
            items: [
              AdaptivePopupMenuItem<NoteToolbarAction>(
                value: NoteToolbarAction.enhance,
                label: l10n.enhanceNote,
                icon: 'wand.and.stars',
              ),
              AdaptivePopupMenuItem<NoteToolbarAction>(
                value: NoteToolbarAction.generateTitle,
                label: l10n.generateTitle,
                icon: 'textformat',
                enabled: !isGeneratingTitle,
              ),
            ],
            onSelected: onAction,
          ),
        ],
        const AdaptiveBottomToolbarSpace.flexible(id: 'space'),
        if (canShare && !readOnly)
          AdaptiveBottomToolbarButton(
            id: 'share',
            label: l10n.noteShare,
            sfSymbol: 'person.2',
            onPressed: onShare,
          ),
        if (hasPages)
          AdaptiveBottomToolbarButton(
            id: 'pages',
            label: l10n.notePages,
            sfSymbol: 'doc.on.doc',
            onPressed: onPages,
          ),
        AdaptiveBottomToolbarMenu<NoteToolbarAction>(
          id: 'more',
          label: l10n.more,
          sfSymbol: 'ellipsis',
          items: [
            if (!readOnly)
              AdaptivePopupMenuItem<NoteToolbarAction>(
                value: NoteToolbarAction.generateTitle,
                label: l10n.generateTitle,
                icon: 'sparkles',
                enabled: !isGeneratingTitle,
              ),
            AdaptivePopupMenuItem<NoteToolbarAction>(
              value: NoteToolbarAction.copy,
              label: l10n.copy,
              icon: 'square.on.square',
            ),
            AdaptivePopupMenuItem<NoteToolbarAction>(
              value: NoteToolbarAction.togglePin,
              label: isPinned ? l10n.unpin : l10n.pin,
              icon: isPinned ? 'pin.slash' : 'pin',
            ),
            // The delete endpoint takes the same people as an edit.
            if (!readOnly) ...[
              const AdaptivePopupMenuDivider(),
              AdaptivePopupMenuItem<NoteToolbarAction>(
                value: NoteToolbarAction.delete,
                label: l10n.delete,
                icon: 'trash',
                isDestructive: true,
              ),
            ],
          ],
          onSelected: onAction,
        ),
      ],
    );
  }

  /// Dictate: a menu of dictation and audio recording; a Stop button while
  /// dictating; unavailable while a recording uploads.
  AdaptiveBottomToolbarItem _voiceItem(AppLocalizations l10n, Color stopTint) {
    if (isUploadingAudio) {
      return AdaptiveBottomToolbarButton(
        id: 'voice',
        label: l10n.voiceOptions,
        sfSymbol: 'arrow.up.circle',
        onPressed: null,
      );
    }
    if (isRecording) {
      return AdaptiveBottomToolbarButton(
        id: 'voice',
        label: l10n.stopRecording,
        sfSymbol: 'stop.fill',
        prominent: true,
        tint: stopTint,
        onPressed: onStopDictation,
      );
    }
    return AdaptiveBottomToolbarMenu<NoteToolbarAction>(
      id: 'voice',
      label: l10n.voiceOptions,
      sfSymbol: 'mic',
      items: [
        AdaptivePopupMenuItem<NoteToolbarAction>(
          value: NoteToolbarAction.dictation,
          label: l10n.dictation,
          subtitle: l10n.dictationDescription,
          icon: 'keyboard',
        ),
        AdaptivePopupMenuItem<NoteToolbarAction>(
          value: NoteToolbarAction.recordAudio,
          label: l10n.recordAudio,
          subtitle: l10n.recordAudioDescription,
          icon: 'mic',
        ),
      ],
      onSelected: onAction,
    );
  }
}
