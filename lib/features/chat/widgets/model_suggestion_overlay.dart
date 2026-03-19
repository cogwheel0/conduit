import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/model.dart';
import '../../../core/providers/app_providers.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'package:conduit/l10n/app_localizations.dart';

/// Autocomplete overlay that appears when the user types `@` to
/// switch the active AI model, similar to OpenWebUI.
class ModelSuggestionOverlay extends ConsumerWidget {
  const ModelSuggestionOverlay({
    required this.filteredModels,
    required this.selectionIndex,
    required this.onModelSelected,
    super.key,
  });

  /// Filter function applied to the full model list.
  final List<Model> Function(List<Model>) filteredModels;

  /// Index of the currently highlighted model in the filtered list.
  final int selectionIndex;

  /// Called when the user taps a model to select it.
  final ValueChanged<Model> onModelSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Brightness brightness = Theme.of(context).brightness;
    final overlayColor = context.conduitTheme.cardBackground;
    final borderColor = context.conduitTheme.cardBorder.withValues(
      alpha: brightness == Brightness.dark ? 0.6 : 0.4,
    );

    final AsyncValue<List<Model>> modelsAsync = ref.watch(
      modelsProvider,
    );
    final Model? currentModel = ref.watch(selectedModelProvider);

    return Container(
      decoration: BoxDecoration(
        color: overlayColor,
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(
          color: borderColor,
          width: BorderWidth.thin,
        ),
        boxShadow: [
          BoxShadow(
            color: context.conduitTheme.cardShadow.withValues(
              alpha: brightness == Brightness.dark ? 0.28 : 0.16,
            ),
            blurRadius: 22,
            offset: const Offset(0, 8),
            spreadRadius: -4,
          ),
        ],
      ),
      child: modelsAsync.when(
        data: (models) {
          final List<Model> filtered = filteredModels(models);
          if (filtered.isEmpty) {
            return _OverlayPlaceholder(
              leading: Icon(
                Icons.inbox_outlined,
                size: IconSize.medium,
                color: context.conduitTheme.textSecondary.withValues(
                  alpha: Alpha.medium,
                ),
              ),
              message: AppLocalizations.of(context)!.noResults,
            );
          }

          int activeIndex = selectionIndex;
          if (activeIndex < 0) {
            activeIndex = 0;
          } else if (activeIndex >= filtered.length) {
            activeIndex = filtered.length - 1;
          }

          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(
                vertical: Spacing.xs,
              ),
              shrinkWrap: true,
              physics: const ClampingScrollPhysics(),
              itemCount: filtered.length,
              separatorBuilder: (context, index) =>
                  const SizedBox(height: Spacing.xxs),
              itemBuilder: (context, index) {
                final model = filtered[index];
                final bool isSelected = index == activeIndex;
                final bool isCurrent =
                    currentModel?.id == model.id;
                final Color highlight = isSelected
                    ? context
                          .conduitTheme
                          .navigationSelectedBackground
                          .withValues(alpha: 0.4)
                    : Colors.transparent;

                final profileUrl = model.metadata
                    ?['profile_image_url'] as String?;

                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(
                      AppBorderRadius.card,
                    ),
                    onTap: () => onModelSelected(model),
                    child: Container(
                      decoration: BoxDecoration(
                        color: highlight,
                        borderRadius: BorderRadius.circular(
                          AppBorderRadius.card,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.sm,
                        vertical: Spacing.xs,
                      ),
                      child: Row(
                        children: [
                          _ModelAvatar(
                            profileUrl: profileUrl,
                            modelName: model.name,
                          ),
                          const SizedBox(width: Spacing.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(
                                  model.name,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                        fontWeight:
                                            FontWeight.w600,
                                        color: context
                                            .conduitTheme
                                            .textPrimary,
                                      ),
                                  maxLines: 1,
                                  overflow:
                                      TextOverflow.ellipsis,
                                ),
                                if (model.description != null &&
                                    model.description!
                                        .trim()
                                        .isNotEmpty)
                                  Padding(
                                    padding:
                                        const EdgeInsets.only(
                                      top: Spacing.xxs,
                                    ),
                                    child: Text(
                                      model.description!,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: context
                                                .conduitTheme
                                                .textSecondary,
                                          ),
                                      maxLines: 1,
                                      overflow:
                                          TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (isCurrent)
                            Padding(
                              padding: const EdgeInsets.only(
                                left: Spacing.xs,
                              ),
                              child: Icon(
                                !kIsWeb && Platform.isIOS
                                    ? CupertinoIcons
                                        .checkmark_alt
                                    : Icons.check,
                                size: IconSize.medium,
                                color: context
                                    .conduitTheme
                                    .buttonPrimary,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
        loading: () => _OverlayPlaceholder(
          leading: SizedBox(
            width: IconSize.large,
            height: IconSize.large,
            child: CircularProgressIndicator(
              strokeWidth: BorderWidth.regular,
              valueColor: AlwaysStoppedAnimation<Color>(
                context.conduitTheme.loadingIndicator,
              ),
            ),
          ),
        ),
        error: (error, stackTrace) => _OverlayPlaceholder(
          leading: Icon(
            Icons.error_outline,
            size: IconSize.medium,
            color: context.conduitTheme.error,
          ),
        ),
      ),
    );
  }
}

/// Small circular avatar for a model row.
class _ModelAvatar extends StatelessWidget {
  const _ModelAvatar({
    required this.profileUrl,
    required this.modelName,
  });

  final String? profileUrl;
  final String modelName;

  @override
  Widget build(BuildContext context) {
    const double size = 28;

    if (profileUrl != null && profileUrl!.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          profileUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              _fallback(context),
        ),
      );
    }
    return _fallback(context);
  }

  Widget _fallback(BuildContext context) {
    const double size = 28;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: context.conduitTheme.buttonPrimary.withValues(
          alpha: 0.12,
        ),
      ),
      child: Center(
        child: Icon(
          !kIsWeb && Platform.isIOS
              ? CupertinoIcons.sparkles
              : Icons.auto_awesome,
          size: IconSize.small,
          color: context.conduitTheme.buttonPrimary,
        ),
      ),
    );
  }
}

/// Placeholder shown when the model list is loading, empty,
/// or errored.
class _OverlayPlaceholder extends StatelessWidget {
  const _OverlayPlaceholder({
    required this.leading,
    this.message,
  });

  final Widget leading;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.md,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          leading,
          if (message != null) ...[
            const SizedBox(width: Spacing.sm),
            Flexible(
              child: Text(
                message!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(
                      color: context.conduitTheme.textSecondary,
                    ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
