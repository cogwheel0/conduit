import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/features/hermes/models/hermes_room.dart';
import 'package:conduit_core/features/hermes/services/hermes_room_projection.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import 'hermes_room_avatars.dart';

/// The most bots the mention list shows at once.
const int _kMaxMentionRows = 5;

/// A room's message field: @mention completion for its bots, Send, and
/// Stop while the room works and nothing is typed.
class HermesRoomComposer extends StatefulWidget {
  const HermesRoomComposer({
    super.key,
    required this.members,
    required this.onSend,
    this.onStop,
    this.enabled = true,
    this.sending = false,
  });

  final List<HermesRoomMember> members;

  /// Sends the words; true once Hermes has them, which clears the field.
  final Future<bool> Function(String text) onSend;

  /// Stops the room's work; shown instead of Send while nothing is typed.
  final VoidCallback? onStop;
  final bool enabled;
  final bool sending;

  @override
  State<HermesRoomComposer> createState() => _HermesRoomComposerState();
}

class _HermesRoomComposerState extends State<HermesRoomComposer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  HermesRoomMentionQuery? _mention;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged() {
    final selection = _controller.selection;
    final mention = selection.isValid && selection.isCollapsed
        ? hermesRoomMentionQuery(_controller.text, selection.baseOffset)
        : null;
    setState(() => _mention = mention);
  }

  void _insert(String handle) {
    final mention = _mention;
    if (mention == null) return;
    final next = insertHermesRoomMention(
      _controller.text,
      mention,
      _controller.selection.baseOffset,
      handle,
    );
    _controller.value = TextEditingValue(
      text: next.text,
      selection: TextSelection.collapsed(offset: next.caret),
    );
    _focus.requestFocus();
  }

  Future<void> _send() async {
    final typed = _controller.text;
    final text = typed.trim();
    if (text.isEmpty || widget.sending || !widget.enabled) return;
    // The field stays editable while Hermes answers: words typed since
    // the send are the next message, so they stay.
    if (await widget.onSend(text) && mounted && _controller.text == typed) {
      _controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final typed = _controller.text.trim().isNotEmpty;
    final mention = _mention;
    final candidates = mention == null
        ? const <HermesRoomMember>[]
        : hermesRoomMentionCandidates(
            widget.members,
            mention.query,
          ).take(_kMaxMentionRows).toList();
    final everyone =
        mention != null &&
        'everyone'.startsWith(mention.query.toLowerCase());
    final stop = widget.onStop;
    final showStop = stop != null && !typed && !widget.sending;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.enabled && (candidates.isNotEmpty || everyone))
          Container(
            key: const ValueKey<String>('hermes-room-mentions'),
            margin: const EdgeInsets.only(bottom: Spacing.xs),
            padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
            decoration: BoxDecoration(
              color: theme.surfaceBackground,
              borderRadius: BorderRadius.circular(AppBorderRadius.card),
              border: Border.all(color: theme.cardBorder),
              boxShadow: ConduitShadows.card(context),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final member in candidates)
                  _MentionRow(
                    key: ValueKey<String>(
                      'hermes-room-mention-${member.handle}',
                    ),
                    leading: HermesRoomMemberAvatar(member: member, size: 24),
                    title: member.name,
                    handle: member.handle,
                    onTap: () => _insert(member.handle),
                  ),
                if (everyone)
                  _MentionRow(
                    key: const ValueKey<String>('hermes-room-mention-everyone'),
                    leading: Icon(
                      Icons.groups_outlined,
                      size: 24,
                      color: theme.iconSecondary,
                    ),
                    title: l10n.hermesRoomEveryone,
                    handle: 'everyone',
                    onTap: () => _insert('everyone'),
                  ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(
            Spacing.md,
            Spacing.xs,
            Spacing.xs,
            Spacing.xs,
          ),
          decoration: BoxDecoration(
            color: theme.inputBackground,
            borderRadius: BorderRadius.circular(AppBorderRadius.card),
            border: Border.all(color: theme.inputBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
                  child: Shortcuts(
                    shortcuts: const {
                      SingleActivator(LogicalKeyboardKey.enter, meta: true):
                          _SendIntent(),
                      SingleActivator(LogicalKeyboardKey.enter, control: true):
                          _SendIntent(),
                    },
                    child: Actions(
                      actions: {
                        _SendIntent: CallbackAction<_SendIntent>(
                          onInvoke: (_) => _send(),
                        ),
                      },
                      child: AdaptiveTextField(
                        key: const ValueKey<String>('hermes-room-composer'),
                        controller: _controller,
                        focusNode: _focus,
                        placeholder: l10n.hermesRoomMessageHint,
                        enabled: widget.enabled,
                        minLines: 1,
                        maxLines: 6,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        style: AppTypography.chatMessageStyle.copyWith(
                          color: theme.textPrimary,
                        ),
                        padding: EdgeInsets.zero,
                        cupertinoDecoration: const BoxDecoration(),
                        decoration: context.conduitInputStyles
                            .borderless()
                            .copyWith(
                              isCollapsed: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: Spacing.xs),
              if (showStop)
                ConduitIconButton(
                  key: const ValueKey<String>('hermes-room-stop'),
                  icon: Icons.stop_rounded,
                  tooltip: l10n.hermesRoomStopWork,
                  isActive: true,
                  isCompact: true,
                  onPressed: stop,
                )
              else
                ConduitIconButton(
                  key: const ValueKey<String>('hermes-room-send'),
                  icon: Icons.arrow_upward_rounded,
                  tooltip: l10n.send,
                  isActive: typed,
                  isCompact: true,
                  onPressed: typed && widget.enabled && !widget.sending
                      ? _send
                      : null,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SendIntent extends Intent {
  const _SendIntent();
}

class _MentionRow extends StatelessWidget {
  const _MentionRow({
    super.key,
    required this.leading,
    required this.title,
    required this.handle,
    required this.onTap,
  });

  final Widget leading;
  final String title;
  final String handle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.xs,
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: Spacing.sm),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.standard.copyWith(
                  color: theme.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Text(
              '@$handle',
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
