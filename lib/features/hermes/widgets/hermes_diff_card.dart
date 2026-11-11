import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/features/hermes/models/hermes_inline_diff.dart';
import 'package:conduit_core/models/chat_message.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/themed_sheets.dart';

/// The most files the card lists before it sums up the rest.
const int _kMaxListedFiles = 6;

/// The files a Hermes reply changed, with their added and removed line
/// counts, from the diffs its tools reported. Tapping a file opens its
/// coloured lines under its full path. Nothing shows when no tool reported
/// a diff.
class HermesChangedFilesCard extends StatefulWidget {
  const HermesChangedFilesCard({
    super.key,
    required this.statuses,
    this.workingDirectory,
  });

  final List<ChatStatusUpdate> statuses;

  /// The directory the chat runs its tools in, when Hermes reported it: a
  /// file inside it is listed under its path from there.
  final String? workingDirectory;

  @override
  State<HermesChangedFilesCard> createState() => _HermesChangedFilesCardState();
}

class _HermesChangedFilesCardState extends State<HermesChangedFilesCard> {
  // A streaming reply rebuilds per token; its status list is only replaced
  // when a tool reports, so the diffs are read again only then.
  late List<HermesDiffFile> _files = hermesChangedFiles(widget.statuses);

  @override
  void didUpdateWidget(covariant HermesChangedFilesCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.statuses, widget.statuses)) {
      _files = hermesChangedFiles(widget.statuses);
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    if (files.isEmpty) return const SizedBox.shrink();
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final added = files.fold(0, (sum, file) => sum + file.added);
    final removed = files.fold(0, (sum, file) => sum + file.removed);
    final listed = files.take(_kMaxListedFiles).toList();
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.sm),
      child: DecoratedBox(
        key: const ValueKey('hermes-changed-files'),
        decoration: BoxDecoration(
          color: theme.surfaceContainer,
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
          border: Border.all(color: theme.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                Spacing.sm,
                Spacing.md,
                Spacing.xs,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.difference_outlined,
                    size: 16,
                    color: theme.iconSecondary,
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      l10n.hermesChangedFiles(files.length),
                      style: AppTypography.labelStyle.copyWith(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _LineCounts(added: added, removed: removed),
                ],
              ),
            ),
            for (final (index, file) in listed.indexed)
              _FileRow(
                key: ValueKey('hermes-changed-file-$index'),
                file: file,
                workingDirectory: widget.workingDirectory,
                onTap: () => showHermesDiffSheet(
                  context,
                  files: files,
                  initialIndex: index,
                ),
              ),
            if (files.length > listed.length)
              _MoreRow(
                count: files.length - listed.length,
                onTap: () => showHermesDiffSheet(
                  context,
                  files: files,
                  initialIndex: listed.length,
                ),
              ),
            const SizedBox(height: Spacing.xs),
          ],
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    super.key,
    required this.file,
    required this.workingDirectory,
    required this.onTap,
  });

  final HermesDiffFile file;
  final String? workingDirectory;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final name = file.path.isEmpty ? l10n.hermesDiffUnnamedFile : file.name;
    final path = hermesDiffDisplayPath(
      file.path,
      workingDirectory: workingDirectory,
    );
    final separator = math.max(path.lastIndexOf('/'), path.lastIndexOf(r'\'));
    final folder = path.substring(0, separator + 1);
    return Semantics(
      button: true,
      label: '$name, ${l10n.hermesDiffLineCounts(file.added, file.removed)}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.xs + 2,
          ),
          child: Row(
            children: [
              Icon(
                Icons.insert_drive_file_outlined,
                size: 16,
                color: theme.iconSecondary,
              ),
              const SizedBox(width: Spacing.sm),
              // The name takes what it needs, up to most of the row; its
              // folder gets the rest.
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => Row(
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: folder.isEmpty
                              ? constraints.maxWidth
                              : constraints.maxWidth * 0.6,
                        ),
                        // Cut in the middle too: its extension stays.
                        child: MiddleEllipsisText(
                          name,
                          style: AppTypography.bodySmallStyle.copyWith(
                            color: theme.textPrimary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (folder.isNotEmpty) ...[
                        const SizedBox(width: Spacing.xs),
                        Expanded(
                          // Cut in the middle: the start names the
                          // project, the end the folders nearest the file.
                          child: MiddleEllipsisText(
                            folder,
                            style: AppTypography.labelSmallStyle.copyWith(
                              color: theme.textTertiary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              _LineCounts(added: file.added, removed: file.removed),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: theme.iconSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MoreRow extends StatelessWidget {
  const _MoreRow({required this.count, required this.onTap});

  final int count;
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
          vertical: Spacing.xs + 2,
        ),
        child: Text(
          AppLocalizations.of(context)!.hermesChangedFilesMore(count),
          style: AppTypography.labelSmallStyle.copyWith(
            color: theme.buttonPrimary,
          ),
        ),
      ),
    );
  }
}

class _LineCounts extends StatelessWidget {
  const _LineCounts({required this.added, required this.removed});

  final int added;
  final int removed;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final style = AppTypography.labelSmallStyle.copyWith(
      fontFamily: AppTypography.monospaceFontFamily,
      fontWeight: FontWeight.w600,
    );
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('+$added', style: style.copyWith(color: theme.success)),
          const SizedBox(width: Spacing.xs),
          Text('−$removed', style: style.copyWith(color: theme.error)),
        ],
      ),
    );
  }
}

/// Opens the lines of [files], starting at the one at [initialIndex].
Future<void> showHermesDiffSheet(
  BuildContext context, {
  required List<HermesDiffFile> files,
  int initialIndex = 0,
}) => ThemedSheets.showSurface<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  constraints: BoxConstraints(
    maxHeight: MediaQuery.sizeOf(context).height * 0.9,
  ),
  padding: EdgeInsets.zero,
  showHandle: false,
  builder: (_) => HermesDiffSheet(files: files, initialIndex: initialIndex),
);

/// One changed file's lines at a time, coloured by what changed, with the
/// line numbers Hermes' hunk headers give. Other files are a tap away.
class HermesDiffSheet extends StatefulWidget {
  const HermesDiffSheet({
    super.key,
    required this.files,
    this.initialIndex = 0,
  });

  final List<HermesDiffFile> files;
  final int initialIndex;

  @override
  State<HermesDiffSheet> createState() => _HermesDiffSheetState();
}

class _HermesDiffSheetState extends State<HermesDiffSheet> {
  late int _index = widget.initialIndex.clamp(0, widget.files.length - 1);

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final file = widget.files[_index];
    final numbered = file.lines.any(
      (line) => line.oldNumber != null || line.newNumber != null,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHandle(),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.md,
            Spacing.xs,
            Spacing.md,
            Spacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  file.path.isEmpty ? l10n.hermesDiffUnnamedFile : file.path,
                  style: AppTypography.labelStyle.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              _LineCounts(added: file.added, removed: file.removed),
            ],
          ),
        ),
        if (widget.files.length > 1)
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              itemCount: widget.files.length,
              separatorBuilder: (_, _) => const SizedBox(width: Spacing.xs),
              itemBuilder: (context, index) {
                final other = widget.files[index];
                return AdaptiveChip.choice(
                  key: ValueKey('hermes-diff-file-$index'),
                  label: Text(
                    other.path.isEmpty
                        ? l10n.hermesDiffUnnamedFile
                        : other.name,
                  ),
                  selected: index == _index,
                  onSelected: (_) => setState(() => _index = index),
                );
              },
            ),
          ),
        Flexible(
          child: ListView.builder(
            key: ValueKey('hermes-diff-lines-$_index'),
            padding: const EdgeInsets.fromLTRB(0, Spacing.sm, 0, Spacing.lg),
            itemCount: file.lines.length,
            itemBuilder: (context, index) => _DiffLineRow(
              line: file.lines[index],
              numbered: numbered,
            ),
          ),
        ),
      ],
    );
  }
}

class _DiffLineRow extends StatelessWidget {
  const _DiffLineRow({required this.line, required this.numbered});

  final HermesDiffLine line;
  final bool numbered;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final code = AppTypography.codeStyle.copyWith(fontSize: 12, height: 1.4);
    final (background, foreground, marker) = switch (line.kind) {
      HermesDiffLineKind.added => (
        theme.success.withValues(alpha: 0.14),
        theme.textPrimary,
        '+',
      ),
      HermesDiffLineKind.removed => (
        theme.error.withValues(alpha: 0.14),
        theme.textPrimary,
        '−',
      ),
      HermesDiffLineKind.hunk => (
        theme.info.withValues(alpha: 0.10),
        theme.textSecondary,
        '',
      ),
      HermesDiffLineKind.note => (null, theme.textTertiary, ''),
      HermesDiffLineKind.context => (null, theme.textSecondary, ' '),
    };
    if (line.kind == HermesDiffLineKind.note && line.text.isEmpty) {
      // Where one edit of a file ends and the next begins.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
        child: Container(height: 1, color: theme.dividerColor),
      );
    }
    final number = switch (line.kind) {
      HermesDiffLineKind.removed => line.oldNumber,
      _ => line.newNumber ?? line.oldNumber,
    };
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (numbered)
            SizedBox(
              width: 36,
              child: Text(
                number?.toString() ?? '',
                textAlign: TextAlign.end,
                style: code.copyWith(color: theme.textTertiary),
              ),
            ),
          SizedBox(
            width: 18,
            child: Text(
              marker,
              textAlign: TextAlign.center,
              style: code.copyWith(color: foreground),
            ),
          ),
          Expanded(
            child: Text(
              line.text,
              style: code.copyWith(
                color: foreground,
                fontStyle: line.kind == HermesDiffLineKind.note
                    ? FontStyle.italic
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
