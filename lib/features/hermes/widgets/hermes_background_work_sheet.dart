import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/features/hermes/models/hermes_background_work.dart';
import 'package:conduit_core/features/hermes/providers/hermes_background_work_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_room_projection.dart'
    show formatHermesRoomElapsed;

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/themed_sheets.dart';

/// The share of the screen a subagent's output may take before it scrolls.
const double _kMaxOutputHeightFraction = 0.4;

/// The open chat's subagents and background processes: read, steer and
/// stop a subagent, or kill a process.
Future<void> showHermesBackgroundWorkSheet(BuildContext context) =>
    ThemedSheets.showSurface<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      ),
      padding: EdgeInsets.zero,
      // The sheet draws its own handle so its list scrolls within it.
      showHandle: false,
      builder: (_) => const HermesBackgroundWorkSheet(),
    );

/// A short message under the sheet's title, about the last action.
typedef _Notice = ({String text, bool error});

class HermesBackgroundWorkSheet extends ConsumerStatefulWidget {
  const HermesBackgroundWorkSheet({super.key});

  @override
  ConsumerState<HermesBackgroundWorkSheet> createState() =>
      _HermesBackgroundWorkSheetState();
}

class _HermesBackgroundWorkSheetState
    extends ConsumerState<HermesBackgroundWorkSheet> {
  /// The subagent shown in full, when one is.
  String? _selected;
  final Set<String> _killing = {};
  _Notice? _notice;

  /// Moves the elapsed times on while the sheet is open.
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _kill(HermesBackgroundProcess process) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.hermesProcessKillTitle,
      message: l10n.hermesProcessKillMessage(process.command),
      confirmText: l10n.hermesProcessKill,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _killing.add(process.id);
      _notice = null;
    });
    _Notice notice;
    try {
      final result = await ref
          .read(hermesBackgroundWorkProvider.notifier)
          .kill(process.id);
      final error = result.error;
      notice = switch (result.status) {
        HermesProcessKillStatus.killed => (
          text: l10n.hermesProcessKilled,
          error: false,
        ),
        HermesProcessKillStatus.alreadyExited ||
        HermesProcessKillStatus.notFound => (
          text: l10n.hermesProcessAlreadyStopped,
          error: false,
        ),
        HermesProcessKillStatus.failed => (
          text: error == null
              ? l10n.hermesBackgroundActionFailed
              : l10n.hermesProcessKillFailed(error),
          error: true,
        ),
      };
    } catch (_) {
      notice = (text: l10n.hermesBackgroundActionFailed, error: true);
    }
    if (!mounted) return;
    setState(() {
      _killing.remove(process.id);
      _notice = notice;
    });
  }

  @override
  Widget build(BuildContext context) {
    final work = ref.watch(hermesBackgroundWorkProvider);
    final storedId = ref.watch(hermesOpenSessionIdProvider);
    final selected = _selected;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHandle(),
        Flexible(
          child: selected != null && storedId != null
              ? _SubagentDetail(
                  key: ValueKey('hermes-subagent-$selected'),
                  subagent: (storedId: storedId, subagentId: selected),
                  listed: work?.subagent(selected),
                  onBack: () => setState(() => _selected = null),
                )
              : _list(context, work),
        ),
      ],
    );
  }

  Widget _list(BuildContext context, HermesBackgroundWork? work) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final processes =
        work?.processes.where((process) => process.running).toList() ??
        const <HermesBackgroundProcess>[];
    final subagents = work?.subagents ?? const <HermesSubagent>[];
    final notice = _notice;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.xs,
        Spacing.lg,
        Spacing.lg,
      ),
      children: [
        Text(
          l10n.hermesBackgroundWorkTitle,
          style: AppTypography.titleMediumStyle.copyWith(
            color: theme.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (notice != null) ...[
          const SizedBox(height: Spacing.xs),
          _NoticeText(notice: notice),
        ],
        if (work == null)
          const Padding(
            padding: EdgeInsets.all(Spacing.xl),
            child: Center(child: AdaptiveProgressIndicator()),
          )
        else if (subagents.isEmpty && processes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
            child: Text(
              l10n.hermesBackgroundWorkEmpty,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ),
        if (subagents.isNotEmpty) ...[
          _SectionLabel(text: l10n.hermesBackgroundAgents),
          for (final subagent in subagents)
            _SubagentRow(
              subagent: subagent,
              onTap: () => setState(() {
                _selected = subagent.id;
                _notice = null;
              }),
            ),
        ],
        if (processes.isNotEmpty) ...[
          _SectionLabel(text: l10n.hermesBackgroundProcesses),
          for (final process in processes)
            _ProcessRow(
              process: process,
              killing: _killing.contains(process.id),
              onKill: () => _kill(process),
            ),
        ],
      ],
    );
  }
}

/// How long ago [startedAt] was, as a short duration; null when unknown.
String? _elapsed(DateTime? startedAt) {
  if (startedAt == null) return null;
  final elapsed = DateTime.now().difference(startedAt);
  return formatHermesRoomElapsed(elapsed.isNegative ? Duration.zero : elapsed);
}

/// "synthetic-model · 1m05s · last tool: web_search".
String _subagentDetails(AppLocalizations l10n, HermesSubagent subagent) {
  final lastTool = subagent.lastTool;
  return [
    ?subagent.model,
    if (subagent.status == 'queued')
      l10n.hermesSubagentQueued
    else if (subagent.running)
      ?_elapsed(subagent.startedAt),
    if (lastTool != null) l10n.hermesSubagentLastTool(lastTool),
  ].join(' · ');
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Spacing.lg, bottom: Spacing.xs),
    child: Text(
      text,
      style: AppTypography.bodySmallStyle.copyWith(
        color: context.conduitTheme.textSecondary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _NoticeText extends StatelessWidget {
  const _NoticeText({required this.notice});

  final _Notice notice;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Semantics(
      liveRegion: true,
      child: Text(
        notice.text,
        style: AppTypography.bodySmallStyle.copyWith(
          color: notice.error ? theme.error : theme.textSecondary,
        ),
      ),
    );
  }
}

class _SubagentRow extends StatelessWidget {
  const _SubagentRow({required this.subagent, required this.onTap});

  final HermesSubagent subagent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final details = _subagentDetails(l10n, subagent);
    final goal = subagent.goal.isEmpty ? subagent.id : subagent.goal;
    return Semantics(
      button: true,
      child: GestureDetector(
        key: ValueKey('hermes-subagent-row-${subagent.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsetsDirectional.only(
            start: subagent.depth.clamp(0, 3) * Spacing.md,
            top: Spacing.sm,
            bottom: Spacing.sm,
          ),
          child: Row(
            children: [
              Icon(
                subagent.running
                    ? Icons.account_tree_outlined
                    : Icons.check_circle_rounded,
                size: 20,
                color: subagent.running ? theme.buttonPrimary : theme.success,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      goal,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (details.isNotEmpty)
                      Text(
                        details,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.labelSmallStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: theme.iconSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProcessRow extends StatelessWidget {
  const _ProcessRow({
    required this.process,
    required this.killing,
    required this.onKill,
  });

  final HermesBackgroundProcess process;
  final bool killing;
  final VoidCallback onKill;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final elapsed = _elapsed(process.startedAt);
    return Padding(
      key: ValueKey('hermes-process-row-${process.id}'),
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Row(
        children: [
          Icon(Icons.terminal_rounded, size: 20, color: theme.buttonPrimary),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  process.command,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.codeStyle.copyWith(
                    color: theme.textPrimary,
                    fontSize: 13,
                  ),
                ),
                if (elapsed != null)
                  Text(
                    elapsed,
                    style: AppTypography.labelSmallStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          if (killing)
            const Padding(
              padding: EdgeInsets.all(Spacing.sm),
              child: SizedBox.square(
                dimension: 18,
                child: AdaptiveProgressIndicator(),
              ),
            )
          else
            ConduitIconButton(
              key: ValueKey('hermes-process-kill-${process.id}'),
              icon: Icons.stop_circle_outlined,
              tooltip: l10n.hermesProcessKillLabel,
              iconColor: theme.error,
              isCompact: true,
              onPressed: onKill,
            ),
        ],
      ),
    );
  }
}

/// One subagent in full: its live output, Steer and Stop.
class _SubagentDetail extends ConsumerStatefulWidget {
  const _SubagentDetail({
    super.key,
    required this.subagent,
    required this.listed,
    required this.onBack,
  });

  final HermesSubagentRef subagent;

  /// The chat's latest list entry for it; null once it is gone.
  final HermesSubagent? listed;
  final VoidCallback onBack;

  @override
  ConsumerState<_SubagentDetail> createState() => _SubagentDetailState();
}

class _SubagentDetailState extends ConsumerState<_SubagentDetail> {
  final _steer = TextEditingController();

  /// What the list said of it last, kept once it finishes.
  HermesSubagent? _known;
  bool _busy = false;
  _Notice? _notice;

  @override
  void initState() {
    super.initState();
    _known = widget.listed;
    _steer.addListener(_changed);
  }

  @override
  void didUpdateWidget(_SubagentDetail old) {
    super.didUpdateWidget(old);
    _known = widget.listed ?? _known;
  }

  @override
  void dispose() {
    _steer.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  bool get _finished => !(widget.listed?.running ?? false);

  Future<void> _run(Future<_Notice> Function(AppLocalizations l10n) act) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _notice = null;
    });
    _Notice notice;
    try {
      notice = await act(l10n);
    } catch (_) {
      notice = (text: l10n.hermesBackgroundActionFailed, error: true);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _notice = notice;
    });
  }

  Future<void> _sendSteer() {
    final text = _steer.text.trim();
    if (text.isEmpty) return Future.value();
    return _run((l10n) async {
      final queued = await ref
          .read(hermesBackgroundWorkProvider.notifier)
          .steer(widget.subagent.subagentId, text);
      if (!queued) {
        return (text: l10n.hermesSubagentSteerRejected, error: true);
      }
      if (mounted) _steer.clear();
      return (text: l10n.hermesSubagentSteerQueued, error: false);
    });
  }

  Future<void> _stop() => _run((l10n) async {
    final found = await ref
        .read(hermesBackgroundWorkProvider.notifier)
        .stop(widget.subagent.subagentId);
    return found
        ? (text: l10n.hermesSubagentStopped, error: false)
        : (text: l10n.hermesSubagentFinished, error: false);
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final view = ref.watch(hermesSubagentTailProvider(widget.subagent));
    final known = _known;
    final finished = _finished;
    final canSteer =
        !finished && !_busy && (widget.listed?.acceptingSteer ?? false);
    final details = known == null ? '' : _subagentDetails(l10n, known);
    final notice = _notice;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(
        Spacing.md,
        0,
        Spacing.lg,
        Spacing.lg,
      ),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConduitIconButton(
              key: const ValueKey('hermes-subagent-back'),
              icon: Icons.chevron_left_rounded,
              tooltip: l10n.back,
              isCompact: true,
              onPressed: widget.onBack,
            ),
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: Spacing.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      known == null || known.goal.isEmpty
                          ? widget.subagent.subagentId
                          : known.goal,
                      style: AppTypography.bodyMediumStyle.copyWith(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (details.isNotEmpty)
                      Text(
                        details,
                        style: AppTypography.labelSmallStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.md),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: Spacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (finished) ...[
                _NoticeText(
                  notice: (text: l10n.hermesSubagentFinished, error: false),
                ),
                const SizedBox(height: Spacing.sm),
              ],
              _SectionLabel(text: l10n.hermesSubagentOutput),
              _Output(view: view),
              const SizedBox(height: Spacing.md),
              AdaptiveTextField(
                key: const ValueKey('hermes-subagent-steer-field'),
                controller: _steer,
                placeholder: l10n.hermesSubagentSteerHint,
                minLines: 1,
                maxLines: 4,
                enabled: canSteer,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: Spacing.sm),
              ConduitButton(
                key: const ValueKey('hermes-subagent-steer'),
                text: l10n.hermesSubagentSteer,
                isFullWidth: true,
                isLoading: _busy,
                onPressed: canSteer && _steer.text.trim().isNotEmpty
                    ? _sendSteer
                    : null,
              ),
              const SizedBox(height: Spacing.sm),
              ConduitButton(
                key: const ValueKey('hermes-subagent-stop'),
                text: l10n.hermesSubagentStop,
                isDestructive: true,
                isFullWidth: true,
                onPressed: finished || _busy ? null : _stop,
              ),
              if (notice != null) ...[
                const SizedBox(height: Spacing.sm),
                _NoticeText(notice: notice),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The end of a subagent's transcript, newest line at the bottom.
class _Output extends StatelessWidget {
  const _Output({required this.view});

  final HermesSubagentTailView view;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final tail = view.tail;
    final hint = AppTypography.labelSmallStyle.copyWith(
      color: theme.textSecondary,
    );
    final Widget body;
    if (view.failed) {
      body = Text(l10n.hermesSubagentOutputFailed, style: hint);
    } else if (tail == null) {
      body = const Center(
        child: SizedBox.square(
          dimension: 18,
          child: AdaptiveProgressIndicator(),
        ),
      );
    } else if (!tail.available || tail.text.trim().isEmpty) {
      body = Text(l10n.hermesSubagentNoOutput, style: hint);
    } else {
      body = ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight:
              MediaQuery.sizeOf(context).height * _kMaxOutputHeightFraction,
        ),
        // Reversed, so the newest output shows and stays in view.
        child: SingleChildScrollView(
          key: const ValueKey('hermes-subagent-output'),
          reverse: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (tail.truncated)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.xs),
                  child: Text(l10n.hermesSubagentOutputTruncated, style: hint),
                ),
              Text(
                tail.text.trimRight(),
                style: AppTypography.codeStyle.copyWith(
                  color: theme.textPrimary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.codeBackground,
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        border: Border.all(color: theme.cardBorder),
      ),
      child: Padding(padding: const EdgeInsets.all(Spacing.sm), child: body),
    );
  }
}
