import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show ComparisonAdmissionException, ComparisonAdmissionFailure;
import 'package:conduit_core/features/chat/services/chat_comparison_service.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart'
    show directModelRegistryProvider;
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart'
    show hasReservedDirectIdentity;
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/models/chat_comparison.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/modal_safe_area.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/themed_sheets.dart';
import 'model_selector_sheet.dart';

/// The label a slot's tab carries. Slots that ran the same model are told
/// apart by their position, so two runs of one model never read as one.
String chatComparisonSlotLabel(
  AppLocalizations l10n,
  ChatComparisonGroup group,
  ChatComparisonSlot slot,
) {
  final name = slot.current.label;
  final shared = group.slots
      .where((other) => other.current.label == name)
      .length;
  if (name.isEmpty) {
    return l10n.chatComparisonSlotLabel(
      l10n.chatComparisonUnnamedModel,
      slot.index + 1,
    );
  }
  return shared > 1 ? l10n.chatComparisonSlotLabel(name, slot.index + 1) : name;
}

/// One tab per model slot of a saved or running comparison.
///
/// The tabs scroll sideways on a narrow phone rather than squeezing every
/// model into a grid. Picking a tab only chooses which answer is shown; the
/// caller decides what that does to the transcript.
class ChatComparisonTabs extends StatelessWidget {
  const ChatComparisonTabs({
    super.key,
    required this.group,
    required this.activeMessageId,
    required this.onSelected,
  });

  final ChatComparisonGroup group;
  final String activeMessageId;
  final ValueChanged<ChatComparisonAnswer> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      container: true,
      label: l10n.chatComparisonTabsLabel,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final slot in group.slots)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: Spacing.xs),
                child: _ComparisonTab(
                  label: chatComparisonSlotLabel(l10n, group, slot),
                  status: _statusLabel(l10n, slot.current),
                  selected: slot.answers.any(
                    (answer) => answer.messageId == activeMessageId,
                  ),
                  onTap: () => onSelected(slot.current),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String? _statusLabel(
    AppLocalizations l10n,
    ChatComparisonAnswer answer,
  ) {
    if (answer.error != null) return l10n.chatComparisonSlotFailed;
    if (answer.isStreaming) return l10n.chatComparisonSlotResponding;
    return null;
  }
}

class _ComparisonTab extends StatelessWidget {
  const _ComparisonTab({
    required this.label,
    required this.status,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String? status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final foreground = selected ? theme.buttonPrimaryText : theme.textPrimary;
    final semanticLabel = status == null ? label : '$label, $status';
    return Semantics(
      button: true,
      selected: selected,
      label: semanticLabel,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: selected ? theme.buttonPrimary : theme.surfaceContainer,
        borderRadius: BorderRadius.circular(theme.radiusMd),
        child: InkWell(
          borderRadius: BorderRadius.circular(theme.radiusMd),
          onTap: () {
            ConduitHaptics.selectionClick();
            onTap();
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.small.copyWith(
                      color: foreground,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (status != null) ...[
                    const SizedBox(width: Spacing.xs),
                    Text(
                      status!,
                      style: AppTypography.small.copyWith(
                        color: foreground.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A saved merged response shown beside the answer it was made from. The
/// answer itself is never replaced by it.
class ChatMergedResponsePanel extends StatelessWidget {
  const ChatMergedResponsePanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Semantics(
      container: true,
      label: l10n.chatMergedResponseTitle,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: theme.surfaceContainer,
          borderRadius: BorderRadius.circular(theme.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.chatMergedResponseTitle,
              style: AppTypography.small.copyWith(
                color: theme.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: Spacing.xs),
            child,
          ],
        ),
      ),
    );
  }
}

/// A compact Stop for ONE answer of a comparison that is still being written.
/// It leaves every other answer of the turn running; the whole-turn Stop is a
/// different control. Not tied to Advanced: a running comparison always keeps
/// its controls.
class ChatComparisonAnswerStopButton extends StatelessWidget {
  const ChatComparisonAnswerStopButton({super.key, required this.onStop});

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Semantics(
      button: true,
      label: l10n.chatComparisonStopAnswerAction,
      excludeSemantics: true,
      onTap: onStop,
      child: Material(
        color: theme.surfaceContainer,
        borderRadius: BorderRadius.circular(theme.radiusMd),
        child: InkWell(
          borderRadius: BorderRadius.circular(theme.radiusMd),
          onTap: () {
            ConduitHaptics.selectionClick();
            onStop();
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.stop_rounded, size: 18, color: theme.textPrimary),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    l10n.chatComparisonStopAnswerAction,
                    style: AppTypography.small.copyWith(
                      color: theme.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks which of a turn's finished answers to merge. Resolves to the chosen
/// answers in slot order, or null when the sheet is dismissed. Every answer in
/// [candidates] starts chosen, so merging them all is one tap.
Future<List<ChatComparisonAnswer>?> showMergeSourcesSheet(
  BuildContext context, {
  required ChatComparisonGroup group,
  required List<ChatComparisonAnswer> candidates,
}) {
  return ThemedSheets.showCustom<List<ChatComparisonAnswer>>(
    context: context,
    isScrollControlled: true,
    builder: (_) => ChatMergeSourcesSheet(group: group, candidates: candidates),
  );
}

class ChatMergeSourcesSheet extends StatefulWidget {
  const ChatMergeSourcesSheet({
    super.key,
    required this.group,
    required this.candidates,
  });

  final ChatComparisonGroup group;
  final List<ChatComparisonAnswer> candidates;

  @override
  State<ChatMergeSourcesSheet> createState() => _ChatMergeSourcesSheetState();
}

class _ChatMergeSourcesSheetState extends State<ChatMergeSourcesSheet> {
  late final Set<String> _chosen = {
    for (final answer in widget.candidates) answer.messageId,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final ready = _chosen.length >= 2;
    return Container(
      decoration: BoxDecoration(
        color: theme.surfaceBackground,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.bottomSheet),
        ),
      ),
      child: ModalSheetSafeArea(
        padding: const EdgeInsets.fromLTRB(
          Spacing.modalPadding,
          Spacing.sm,
          Spacing.modalPadding,
          Spacing.modalPadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            const SizedBox(height: Spacing.sm),
            Text(
              l10n.chatMergeResponsesAction,
              textAlign: TextAlign.center,
              style: AppTypography.titleLargeStyle.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: theme.textPrimary,
              ),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              l10n.chatMergeChooseDescription,
              textAlign: TextAlign.center,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
            const SizedBox(height: Spacing.md),
            Flexible(
              // The sheet paints its own background; the rows' ink needs a
              // Material of its own to draw on.
              child: Material(
                type: MaterialType.transparency,
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final answer in widget.candidates)
                        CheckboxListTile(
                          key: ValueKey<String>(
                            'merge-source-${answer.messageId}',
                          ),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _chosen.contains(answer.messageId),
                          onChanged: (checked) => setState(() {
                            if (checked ?? false) {
                              _chosen.add(answer.messageId);
                            } else {
                              _chosen.remove(answer.messageId);
                            }
                          }),
                          title: Text(
                            chatComparisonSlotLabel(
                              l10n,
                              widget.group,
                              widget.group.slotAt(answer.slot)!,
                            ),
                            style: AppTypography.bodyLargeStyle.copyWith(
                              fontWeight: FontWeight.w500,
                              color: theme.textPrimary,
                            ),
                          ),
                          subtitle: Text(
                            answer.sourceText.trim(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.small.copyWith(
                              color: theme.textSecondary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: Spacing.sm),
            ConduitButton(
              text: l10n.chatMergeResponsesAction,
              isFullWidth: true,
              onPressed: ready
                  ? () => Navigator.of(context).pop(<ChatComparisonAnswer>[
                      for (final answer in widget.candidates)
                        if (_chosen.contains(answer.messageId)) answer,
                    ])
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

/// The models a comparison may use: the server's own, visible ones. Direct,
/// Apple and Hermes models belong to other transports and are never mixed in.
List<Model> comparisonCandidateModels(WidgetRef ref, List<Model> all) {
  final registry = ref.read(directModelRegistryProvider);
  return [
    for (final model in all)
      if (!model.isHidden &&
          !isHermesModel(model) &&
          registry.resolve(model) == null &&
          !hasReservedDirectIdentity(model))
        model,
  ];
}

/// Asks which models to compare. Returns them in slot order, or null when the
/// sheet is dismissed. Duplicates are allowed: the same model twice is a valid
/// comparison, and its answers are told apart by position.
Future<List<Model>?> showComparisonSetupSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  final List<Model> all =
      ref.read(modelsProvider).asData?.value ??
      await ref.read(modelsProvider.future);
  if (!context.mounted) return null;
  final candidates = comparisonCandidateModels(ref, all);
  final selected = ref.read(selectedModelProvider);
  final initialFirst =
      selected != null && candidates.any((model) => model.id == selected.id)
      ? candidates.firstWhere((model) => model.id == selected.id)
      : null;
  return ThemedSheets.showCustom<List<Model>>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        ComparisonSetupSheet(models: candidates, initialFirst: initialFirst),
  );
}

class ComparisonSetupSheet extends StatefulWidget {
  const ComparisonSetupSheet({
    super.key,
    required this.models,
    this.initialFirst,
  });

  final List<Model> models;
  final Model? initialFirst;

  @override
  State<ComparisonSetupSheet> createState() => _ComparisonSetupSheetState();
}

class _ComparisonSetupSheetState extends State<ComparisonSetupSheet> {
  late final List<Model?> _slots = <Model?>[widget.initialFirst, null];

  Future<void> _pick(int index) async {
    await ThemedSheets.showCustom<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ModelSelectorSheet(
        models: widget.models,
        onPick: (model) {
          if (mounted) setState(() => _slots[index] = model);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final ready = _slots.every((slot) => slot != null);
    return Container(
      decoration: BoxDecoration(
        color: theme.surfaceBackground,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.bottomSheet),
        ),
      ),
      child: ModalSheetSafeArea(
        padding: const EdgeInsets.fromLTRB(
          Spacing.modalPadding,
          Spacing.sm,
          Spacing.modalPadding,
          Spacing.modalPadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            const SizedBox(height: Spacing.sm),
            Text(
              l10n.chatCompareModelsAction,
              textAlign: TextAlign.center,
              style: AppTypography.titleLargeStyle.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: theme.textPrimary,
              ),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              l10n.chatCompareModelsDescription,
              textAlign: TextAlign.center,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
            const SizedBox(height: Spacing.md),
            for (var index = 0; index < _slots.length; index++) ...[
              _ComparisonSlotRow(
                key: ValueKey<String>('comparison-slot-$index'),
                title: index == 0
                    ? l10n.chatCompareFirstModel
                    : l10n.chatCompareSecondModel,
                model: _slots[index],
                placeholder: l10n.chatCompareChooseModel,
                onTap: () => _pick(index),
              ),
              const SizedBox(height: Spacing.sm),
            ],
            const SizedBox(height: Spacing.sm),
            ConduitButton(
              text: l10n.chatCompareStart,
              isFullWidth: true,
              onPressed: ready
                  ? () =>
                        Navigator.of(context)
                            .pop(<Model>[for (final slot in _slots) slot!])
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _ComparisonSlotRow extends StatelessWidget {
  const _ComparisonSlotRow({
    super.key,
    required this.title,
    required this.model,
    required this.placeholder,
    required this.onTap,
  });

  final String title;
  final Model? model;
  final String placeholder;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final chosen = model?.name.trim();
    return Semantics(
      button: true,
      label:
          '$title, ${chosen == null || chosen.isEmpty ? placeholder : chosen}',
      excludeSemantics: true,
      onTap: onTap,
      child: ConduitCard(
        onTap: onTap,
        padding: const EdgeInsets.all(Spacing.md),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTypography.small.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    chosen == null || chosen.isEmpty ? placeholder : chosen,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyLargeStyle.copyWith(
                      fontWeight: FontWeight.w500,
                      color: chosen == null
                          ? theme.textSecondary
                          : theme.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: theme.iconSecondary),
          ],
        ),
      ),
    );
  }
}

/// Words for a refused comparison. Nothing was sent or saved when this shows.
String comparisonAdmissionMessage(
  AppLocalizations l10n,
  ComparisonAdmissionException error,
) {
  final models = error.modelIds.toSet().join(', ');
  return switch (error.reason) {
    ComparisonAdmissionFailure.unavailable => l10n.chatCompareErrorUnavailable,
    ComparisonAdmissionFailure.wrongModelCount =>
      l10n.chatCompareErrorUnavailable,
    ComparisonAdmissionFailure.modelUnavailable =>
      l10n.chatCompareErrorModelUnavailable(models),
    ComparisonAdmissionFailure.visionUnsupported => l10n.chatCompareErrorVision(
      models,
    ),
    ComparisonAdmissionFailure.terminalConflict =>
      l10n.chatCompareErrorTerminal(models),
    ComparisonAdmissionFailure.interpreterUnsupported =>
      l10n.chatCompareErrorInterpreter(models),
    ComparisonAdmissionFailure.settingsConflict =>
      error.conflict?.source == ComparisonConflictSource.chatOverride
          ? l10n.chatCompareErrorEffortOverride(models)
          : l10n.chatCompareErrorEffortPicker,
  };
}
