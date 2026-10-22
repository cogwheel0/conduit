import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_markdown/conduit_markdown.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/markdown/streaming_markdown_widget.dart';
import '../providers/text_to_speech_provider.dart';
import '../../hermes/providers/hermes_mobile_navigation.dart';

/// Message actions stay out of the timeline until the message is held.
class HermesMessageActions extends ConsumerWidget {
  const HermesMessageActions({
    super.key,
    required this.messageId,
    required this.text,
    required this.child,
    this.readOnly = false,
    this.streaming = false,
    this.onCopy,
    this.onSpeak,
  });

  final String messageId;
  final String text;
  final Widget child;
  final bool readOnly;
  final bool streaming;
  final VoidCallback? onCopy;
  final VoidCallback? onSpeak;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep the interaction owner mounted while the message completes. Adding
    // it only after streaming reparents/remounts the Markdown body and changes
    // the constraints of the bubble's content.
    if (text.trim().isEmpty || streaming) {
      return ScrollAwayContextMenu(
        enabled: false,
        actions: const [],
        child: child,
      );
    }
    final l10n = AppLocalizations.of(context)!;
    final tts = ref.watch(
      textToSpeechControllerProvider.select(
        (state) => (
          activeMessageId: state.activeMessageId,
          status: state.status,
          initialized: state.initialized,
          available: state.available,
        ),
      ),
    );
    final speaking =
        tts.activeMessageId == messageId &&
        (tts.status == TtsPlaybackStatus.speaking ||
            tts.status == TtsPlaybackStatus.loading ||
            tts.status == TtsPlaybackStatus.initializing ||
            tts.status == TtsPlaybackStatus.paused);
    final plainText = ConduitMarkdownPreprocessor.cleanText(text);
    final panel = ref.watch(hermesMobileModelPanelProvider);
    return ScrollAwayContextMenu(
      onDismissChanged: (dismiss) {
        if (dismiss == null) {
          panel.clear(this);
        } else {
          panel.register(this, dismiss);
        }
      },
      actions: [
        if (!readOnly)
          AdaptiveContextMenuAction(
            title: l10n.channelMessageReply,
            icon: Icons.reply_rounded,
            onPressed: () {
              final quote = text
                  .split('\n')
                  .map((line) => '> $line')
                  .join('\n');
              ref
                  .read(composerTextInsertionProvider.notifier)
                  .insert(
                    targetId: chatComposerTextInsertionTargetId,
                    text: '$quote\n\n',
                    separateParagraph: true,
                  );
              ref.read(inputFocusTriggerProvider.notifier).increment();
            },
          ),
        AdaptiveContextMenuAction(
          title: l10n.copy,
          icon: Icons.content_copy_outlined,
          onPressed:
              onCopy ?? () => Clipboard.setData(ClipboardData(text: text)),
        ),
        AdaptiveContextMenuAction(
          title: l10n.mobileMessageSelect,
          icon: Icons.text_fields_rounded,
          onPressed: () => showCompactMessageSelection(
            context,
            text: plainText,
            title: l10n.mobileSelectMessageText,
            hint: l10n.mobileSelectMessageTextHint,
            closeLabel: l10n.close,
            formattedContent: (context) => StreamingMarkdownWidget(
              key: const ValueKey('hermes-select-message-text'),
              content: text,
              isStreaming: false,
              enableTextSelection: true,
              stateScopeId: 'selection:$messageId',
            ),
          ),
        ),
        AdaptiveContextMenuAction(
          title: speaking
              ? l10n.mobileMessageStopSpeaking
              : l10n.mobileMessageSpeak,
          icon: speaking ? Icons.stop_rounded : Icons.volume_up_outlined,
          isDisabled: tts.initialized && !tts.available,
          onPressed:
              onSpeak ??
              () => ref
                  .read(textToSpeechControllerProvider.notifier)
                  .toggleForMessage(messageId: messageId, text: plainText),
        ),
      ],
      child: child,
    );
  }
}
