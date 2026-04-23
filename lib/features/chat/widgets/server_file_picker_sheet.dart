import 'dart:async';
import 'dart:io' show Platform;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/file_info.dart';
import '../../../core/providers/app_providers.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/file_type_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/modal_safe_area.dart';
import '../../../shared/widgets/sheet_handle.dart';

/// Bottom sheet for attaching files that already exist on the server.
class ServerFilePickerSheet extends ConsumerStatefulWidget {
  const ServerFilePickerSheet({super.key, required this.onSelected});

  final ValueChanged<FileInfo> onSelected;

  @override
  ConsumerState<ServerFilePickerSheet> createState() =>
      _ServerFilePickerSheetState();
}

class _ServerFilePickerSheetState extends ConsumerState<ServerFilePickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _query = value.trim());
    });
  }

  Future<void> _refreshFiles() async {
    if (_query.isEmpty) {
      await ref.read(userFilesProvider.notifier).refresh();
      return;
    }

    ref.invalidate(searchUserFilesProvider(_query));
    await ref.read(searchUserFilesProvider(_query).future);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final filesAsync = _query.isEmpty
        ? ref.watch(userFilesProvider)
        : ref.watch(searchUserFilesProvider(_query));

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.78,
      minChildSize: 0.45,
      maxChildSize: 0.92,
      builder: (_, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.surfaceBackground,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppBorderRadius.bottomSheet),
            ),
            border: Border.all(
              color: theme.dividerColor,
              width: BorderWidth.thin,
            ),
            boxShadow: ConduitShadows.modal(context),
          ),
          child: ModalSheetSafeArea(
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.xs,
              Spacing.md,
              0,
            ),
            child: Column(
              children: [
                const SheetHandle(),
                const SizedBox(height: Spacing.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.files,
                    style: AppTypography.bodyLargeStyle.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                ConduitGlassSearchField(
                  controller: _searchController,
                  hintText: l10n.searchFiles,
                  onChanged: _onSearchChanged,
                  query: _query,
                  onClear: () {
                    _searchController.clear();
                    _onSearchChanged('');
                  },
                ),
                const SizedBox(height: Spacing.sm),
                Expanded(
                  child: filesAsync.when(
                    data: (files) {
                      if (files.isEmpty) {
                        return Center(
                          child: Text(
                            l10n.noItemsToDisplay,
                            style: AppTypography.bodySmallStyle.copyWith(
                              color: theme.textSecondary,
                            ),
                          ),
                        );
                      }

                      return RefreshIndicator(
                        onRefresh: _refreshFiles,
                        child: ListView.separated(
                          controller: scrollController,
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: files.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: Spacing.xs),
                          itemBuilder: (context, index) {
                            final file = files[index];
                            return _ServerFileTile(
                              file: file,
                              onTap: () {
                                Navigator.of(context).pop();
                                widget.onSelected(file);
                              },
                            );
                          },
                        ),
                      );
                    },
                    loading: () => const Center(
                      child: CircularProgressIndicator(
                        strokeWidth: BorderWidth.thin,
                      ),
                    ),
                    error: (error, _) => ErrorStateWidget(
                      message: l10n.failedToLoadFiles,
                      error: error,
                      onRetry: _retry,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _retry() {
    unawaited(_refreshFiles());
  }
}

class _ServerFileTile extends StatelessWidget {
  const _ServerFileTile({required this.file, required this.onTap});

  final FileInfo file;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final extension = file.extension;
    final accentColor = FileTypeUtils.colorForExtension(
      extension,
      fallback: theme.buttonPrimary,
    );

    return ConduitCard(
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppBorderRadius.small),
                border: Border.all(
                  color: accentColor.withValues(alpha: 0.18),
                  width: BorderWidth.thin,
                ),
              ),
              child: Icon(
                FileTypeUtils.iconForExtension(extension),
                color: accentColor,
                size: IconSize.md,
              ),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyMediumStyle.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    _buildSubtitle(context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodySmallStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Icon(
              Platform.isIOS
                  ? CupertinoIcons.add_circled_solid
                  : Icons.add_circle_rounded,
              color: theme.buttonPrimary,
              size: IconSize.md,
            ),
          ],
        ),
      ),
    );
  }

  String _buildSubtitle(BuildContext context) {
    final sizeText = FileTypeUtils.formatFileSize(file.size);
    final updatedText = _formatUpdatedAt(context, file.updatedAt);
    if (sizeText.isEmpty) {
      return updatedText;
    }
    return '$sizeText • $updatedText';
  }

  String _formatUpdatedAt(BuildContext context, DateTime timestamp) {
    if (DateUtils.isSameDay(DateTime.now(), timestamp)) {
      return TimeOfDay.fromDateTime(timestamp).format(context);
    }

    return MaterialLocalizations.of(context).formatShortDate(timestamp);
  }
}
