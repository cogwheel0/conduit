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
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/horizontal_overflow_fade.dart';
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
/// model into a grid. Each tab is capped at [maxTabWidthFactor] of the row so a
/// long model name ellipsizes instead of pushing the other tabs off screen.
/// Picking a tab only chooses which response is shown; the caller decides what
/// that does to the transcript.
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

  /// The widest a single tab may grow, as a share of the row's width.
  static const double maxTabWidthFactor = 0.6;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      container: true,
      label: l10n.chatComparisonTabsLabel,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxTabWidth = constraints.hasBoundedWidth
              ? constraints.maxWidth * maxTabWidthFactor
              : double.infinity;
          return HorizontalOverflowFade(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final slot in group.slots)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(
                        end: Spacing.xs,
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: maxTabWidth),
                        child: _ComparisonTab(
                          key: ValueKey<String>(
                            'comparison-tab-${slot.index}',
                          ),
                          label: chatComparisonSlotLabel(l10n, group, slot),
                          status: _statusOf(slot.current),
                          selected: slot.answers.any(
                            (answer) => answer.messageId == activeMessageId,
                          ),
                          onTap: () => onSelected(slot.current),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static _ComparisonTabStatus? _statusOf(ChatComparisonAnswer answer) {
    if (answer.error != null) return _ComparisonTabStatus.failed;
    if (answer.isStreaming) return _ComparisonTabStatus.responding;
    return null;
  }
}

enum _ComparisonTabStatus { responding, failed }

/// A quiet pill: the active tab gets a light primary tint and border, like the
/// composer's feature pills, so the row never shouts over the response.
class _ComparisonTab extends StatefulWidget {
  const _ComparisonTab({
    super.key,
    required this.label,
    required this.status,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final _ComparisonTabStatus? status;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ComparisonTab> createState() => _ComparisonTabState();
}

class _ComparisonTabState extends State<_ComparisonTab> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  void _handleTap() {
    // Picking the tab already on screen changes nothing, so it stays silent.
    if (!widget.selected) ConduitHaptics.selectionClick();
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final selected = widget.selected;
    final status = switch (widget.status) {
      _ComparisonTabStatus.failed => l10n.chatComparisonSlotFailed,
      _ComparisonTabStatus.responding => l10n.chatComparisonSlotResponding,
      null => null,
    };
    final statusColor = widget.status == _ComparisonTabStatus.failed
        ? theme.error
        : theme.textSecondary;
    final background = selected
        ? theme.buttonPrimary.withValues(alpha: 0.10)
        : Colors.transparent;
    final borderColor = selected
        ? theme.buttonPrimary.withValues(alpha: 0.4)
        : theme.cardBorder;
    final textColor = selected ? theme.textPrimary : theme.textSecondary;
    final semanticLabel = status == null
        ? widget.label
        : '${widget.label}, $status';
    final duration = context.motionDuration(const Duration(milliseconds: 200));

    return Semantics(
      button: true,
      selected: selected,
      label: semanticLabel,
      onTap: _handleTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: _handleTap,
        child: ConstrainedBox(
          // The pill stays compact; the hit area keeps the full touch target.
          constraints: const BoxConstraints(
            minHeight: TouchTarget.minimum,
            minWidth: TouchTarget.minimum,
          ),
          child: Align(
            widthFactor: 1,
            heightFactor: 1,
            child: AnimatedOpacity(
              opacity: _pressed ? 0.6 : 1,
              duration: duration,
              child: AnimatedContainer(
                duration: duration,
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.md,
                  vertical: Spacing.sm - 2,
                ),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(AppBorderRadius.round),
                  border: Border.all(
                    color: borderColor,
                    width: BorderWidth.thin,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.labelMediumStyle.copyWith(
                          color: textColor,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          letterSpacing: AppTypography.letterSpacingNormal,
                        ),
                      ),
                    ),
                    if (status != null) ...[
                      const SizedBox(width: Spacing.xs),
                      Text(
                        status,
                        key: const ValueKey<String>('comparison-tab-status'),
                        maxLines: 1,
                        style: AppTypography.labelMediumStyle.copyWith(
                          color: statusColor,
                          letterSpacing: AppTypography.letterSpacingNormal,
                        ),
                      ),
                    ],
                  ],
                ),
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
            constraints: const BoxConstraints(
              minHeight: TouchTarget.minimum,
              minWidth: TouchTarget.minimum,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    UiUtils.platformIcon(
                      ios: CupertinoIcons.stop_fill,
                      android: Icons.stop_rounded,
                    ),
                    size: IconSize.chip,
                    color: theme.textPrimary,
                  ),
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

/// Asks which of a turn's finished responses to merge. Resolves to the chosen
/// responses in slot order, or null when the sheet is dismissed. Every response
/// in [candidates] starts chosen, so merging them all is one tap.
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

  /// A short, single-paragraph preview of a response for its row.
  static String _preview(String text) {
    final flat = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    const limit = 200;
    final characters = flat.characters;
    // Counted in characters, so an emoji at the cut is never split.
    return characters.length <= limit
        ? flat
        : '${characters.take(limit)}…';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final ready = _chosen.length >= 2;
    return ConduitModalSheetSurface(
      child: Column(
        key: const ValueKey<String>('merge-sources-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ComparisonSheetHeader(title: l10n.chatMergeResponsesAction),
          const SizedBox(height: Spacing.xs),
          Text(
            l10n.chatMergeChooseDescription,
            style: theme.bodySmall?.copyWith(color: theme.textSecondary),
          ),
          const SizedBox(height: Spacing.sm),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final answer in widget.candidates)
                    _mergeSourceTile(context, answer),
                ],
              ),
            ),
          ),
          const SizedBox(height: Spacing.md),
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
    );
  }

  Widget _mergeSourceTile(BuildContext context, ChatComparisonAnswer answer) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final chosen = _chosen.contains(answer.messageId);
    return AdaptiveSelectionTile(
      key: ValueKey<String>('merge-source-${answer.messageId}'),
      title: chatComparisonSlotLabel(
        l10n,
        widget.group,
        widget.group.slotAt(answer.slot)!,
      ),
      subtitle: _preview(answer.sourceText),
      selected: chosen,
      // A many-choice list: an empty circle says a row can still be added.
      trailing: Icon(
        chosen
            ? UiUtils.platformIcon(
                ios: CupertinoIcons.checkmark_circle_fill,
                android: Icons.check_circle,
              )
            : UiUtils.platformIcon(
                ios: CupertinoIcons.circle,
                android: Icons.radio_button_unchecked,
              ),
        size: IconSize.medium,
        color: chosen ? theme.buttonPrimary : theme.iconSecondary,
      ),
      onTap: () => setState(() {
        if (!_chosen.remove(answer.messageId)) _chosen.add(answer.messageId);
      }),
    );
  }
}

/// The standard sheet header: a left-aligned title and a close button.
class _ComparisonSheetHeader extends StatelessWidget {
  const _ComparisonSheetHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              title,
              style: theme.headingSmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: Spacing.sm),
        SheetCloseButton(
          tooltip: l10n.close,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
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

  String _slotTitle(AppLocalizations l10n, int index) =>
      index == 0 ? l10n.chatCompareFirstModel : l10n.chatCompareSecondModel;

  Future<void> _pick(int index) async {
    final l10n = AppLocalizations.of(context)!;
    await ThemedSheets.showCustom<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ModelSelectorSheet(
        models: widget.models,
        // The picker speaks for this slot: its title and its checkmark are
        // the slot's, not the chat's model.
        title: _slotTitle(l10n, index),
        selectedModelId: _slots[index]?.id,
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
    return ConduitModalSheetSurface(
      child: Column(
        key: const ValueKey<String>('comparison-setup-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ComparisonSheetHeader(title: l10n.chatCompareModelsAction),
          const SizedBox(height: Spacing.xs),
          Text(
            l10n.chatCompareModelsDescription,
            style: theme.bodySmall?.copyWith(color: theme.textSecondary),
          ),
          const SizedBox(height: Spacing.md),
          for (var index = 0; index < _slots.length; index++) ...[
            _ComparisonSlotRow(
              key: ValueKey<String>('comparison-slot-$index'),
              title: _slotTitle(l10n, index),
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
                ? () => Navigator.of(context).pop(<Model>[
                    for (final slot in _slots) slot!,
                  ])
                : null,
          ),
        ],
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
            const SizedBox(width: Spacing.sm),
            Icon(
              UiUtils.platformIcon(
                ios: CupertinoIcons.chevron_forward,
                android: Icons.chevron_right,
              ),
              size: IconSize.small,
              color: theme.iconSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// The display names of [modelIds], looked up in [models] and falling back to
/// the id when a model is unknown or unnamed. Repeats are listed once.
List<String> comparisonModelNames(
  Iterable<String> modelIds,
  Iterable<Model>? models,
) {
  final byId = <String, Model>{
    for (final model in models ?? const <Model>[]) model.id: model,
  };
  final names = <String>{};
  for (final id in modelIds) {
    final name = byId[id]?.name.trim();
    names.add(name == null || name.isEmpty ? id : name);
  }
  return names.toList(growable: false);
}

/// Words for a refused comparison. Nothing was sent or saved when this shows.
///
/// Pass the server's [models] so the message names models the way the picker
/// does; without them it falls back to model ids.
String comparisonAdmissionMessage(
  AppLocalizations l10n,
  ComparisonAdmissionException error, {
  Iterable<Model>? models,
}) {
  var names = comparisonModelNames(error.modelIds, models);
  if (names.isEmpty) names = [l10n.chatComparisonUnnamedModel];
  final count = names.length;
  final listed = names.length == 1
      ? names.single
      : l10n.chatCompareModelPair(
          names.sublist(0, names.length - 1).join(', '),
          names.last,
        );
  return switch (error.reason) {
    ComparisonAdmissionFailure.unavailable => l10n.chatCompareErrorUnavailable,
    ComparisonAdmissionFailure.wrongModelCount =>
      l10n.chatCompareErrorUnavailable,
    ComparisonAdmissionFailure.modelUnavailable =>
      l10n.chatCompareErrorModelUnavailable(listed, count),
    ComparisonAdmissionFailure.visionUnsupported =>
      l10n.chatCompareErrorVision(listed, count),
    ComparisonAdmissionFailure.terminalConflict =>
      l10n.chatCompareErrorTerminal(listed, count),
    ComparisonAdmissionFailure.interpreterUnsupported =>
      l10n.chatCompareErrorInterpreter(listed, count),
    ComparisonAdmissionFailure.settingsConflict =>
      error.conflict?.source == ComparisonConflictSource.chatOverride
          ? l10n.chatCompareErrorEffortOverride(listed, count)
          : l10n.chatCompareErrorEffortPicker,
  };
}
