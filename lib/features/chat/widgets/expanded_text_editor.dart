import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

import 'dart:io' show Platform;

import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'package:conduit/l10n/app_localizations.dart';

/// Full-screen bottom sheet editor shown when the chat input grows large.
///
/// Uses [showModalBottomSheet] so Flutter's built-in drag-to-dismiss gesture
/// works naturally — drag the handle at the top (or anywhere outside the text
/// field) downward to close. The send button mirrors the compact chat input.
class ExpandedTextEditorSheet extends StatefulWidget {
  const ExpandedTextEditorSheet({
    super.key,
    required this.controller,
    required this.onSend,
  });

  final TextEditingController controller;
  final VoidCallback onSend;

  @override
  State<ExpandedTextEditorSheet> createState() =>
      _ExpandedTextEditorSheetState();
}

class _ExpandedTextEditorSheetState extends State<ExpandedTextEditorSheet> {
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.trim().isNotEmpty;
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    // Guard: the controller may already be disposed by the time this runs
    // (the .then() callback on the modal future disposes it first).
    try {
      widget.controller.removeListener(_onTextChanged);
    } catch (_) {}
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = widget.controller.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final viewInsets = MediaQuery.of(context).viewInsets;
    final viewPadding = MediaQuery.of(context).viewPadding;
    // Match the dense (compact) chat input button — 36px, medium size.
    const double buttonSize = 36.0;

    final iconColor = _hasText
        ? theme.buttonPrimaryText
        : theme.textPrimary.withValues(alpha: Alpha.disabled);
    final sendIcon = Icon(
      Platform.isIOS ? CupertinoIcons.arrow_up : Icons.arrow_upward,
      size: IconSize.small + 1,
      color: iconColor,
    );

    final Widget sendButton;
    if (!kIsWeb && Platform.isIOS) {
      sendButton = AdaptiveButton.child(
        onPressed: _hasText ? widget.onSend : null,
        enabled: _hasText,
        style: AdaptiveButtonStyle.prominentGlass,
        color: theme.buttonPrimary,
        size: AdaptiveButtonSize.medium,
        minSize: const Size(buttonSize, buttonSize),
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(buttonSize),
        useSmoothRectangleBorder: false,
        child: sendIcon,
      );
    } else {
      sendButton = SizedBox(
        width: buttonSize,
        height: buttonSize,
        child: Material(
          color: _hasText ? theme.buttonPrimary : theme.surfaceContainerHighest,
          shape: CircleBorder(
            side: BorderSide(
              color: _hasText ? theme.buttonPrimary : theme.cardBorder,
              width: BorderWidth.thin,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _hasText ? widget.onSend : null,
            customBorder: const CircleBorder(),
            child: Center(child: sendIcon),
          ),
        ),
      );
    }

    // useSafeArea: true on the showModalBottomSheet call already constrains
    // the sheet to the safe area — no manual height calculation needed.
    return Material(
      color: Colors.transparent,
      child: Container(
        height: double.infinity,
        decoration: BoxDecoration(
          color: theme.surfaceBackground,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppBorderRadius.bottomSheet),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle — primary dismiss affordance.
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: Spacing.sm),
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Text editor
            Expanded(
              child: TextField(
                controller: widget.controller,
                autofocus: true,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: AppTypography.chatMessageStyle.copyWith(
                  color: theme.textPrimary,
                  height: 1.5,
                ),
                decoration: context.conduitInputStyles
                    .borderless(hint: l10n.messageHintText)
                    .copyWith(
                      contentPadding: const EdgeInsets.fromLTRB(
                        Spacing.md,
                        Spacing.xs,
                        Spacing.md,
                        Spacing.sm,
                      ),
                      isDense: true,
                    ),
              ),
            ),
            // Bottom bar — send button, keyboard-aware.
            Padding(
              padding: EdgeInsets.fromLTRB(
                Spacing.screenPadding,
                Spacing.sm,
                Spacing.screenPadding,
                viewInsets.bottom > 0
                    ? viewInsets.bottom + Spacing.sm
                    : Spacing.md + viewPadding.bottom,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [sendButton],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
