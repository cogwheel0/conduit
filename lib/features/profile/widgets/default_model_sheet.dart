import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/model.dart';
import '../../../core/utils/model_icon_utils.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/model_list_tile.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/modal_safe_area.dart';
import '../../../core/providers/app_providers.dart';

/// A bottom sheet for selecting a default model from the available models.
class DefaultModelBottomSheet extends ConsumerStatefulWidget {
  final List<Model> models;
  final String? currentDefaultModelId;

  const DefaultModelBottomSheet({
    super.key,
    required this.models,
    required this.currentDefaultModelId,
  });

  @override
  ConsumerState<DefaultModelBottomSheet> createState() =>
      DefaultModelBottomSheetState();
}

class DefaultModelBottomSheetState
    extends ConsumerState<DefaultModelBottomSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<Model> _filteredModels = [];
  Timer? _searchDebounce;
  String? _selectedModelId;

  @override
  void initState() {
    super.initState();
    _selectedModelId = widget.currentDefaultModelId ?? 'auto-select';
    _filteredModels = _allModels();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  List<Model> _allModels() {
    return [
      const Model(id: 'auto-select', name: 'Auto-select'),
      ...widget.models,
    ];
  }

  void _filterModels(String query) {
    setState(() => _searchQuery = query);

    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 160), () {
      if (!mounted) return;

      final normalized = query.trim().toLowerCase();
      final allModels = _allModels();
      final filtered = normalized.isEmpty
          ? allModels
          : allModels.where((model) {
              final name = model.name.toLowerCase();
              final id = model.id.toLowerCase();
              return name.contains(normalized) || id.contains(normalized);
            }).toList();

      setState(() {
        _filteredModels = filtered;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).maybePop(),
            child: const SizedBox.shrink(),
          ),
        ),
        DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          maxChildSize: 0.92,
          minChildSize: 0.45,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: context.sidebarTheme.background,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppBorderRadius.bottomSheet),
                ),
                border: Border.all(
                  color: context.conduitTheme.dividerColor,
                  width: BorderWidth.regular,
                ),
                boxShadow: ConduitShadows.modal(context),
              ),
              child: ModalSheetSafeArea(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.modalPadding,
                  vertical: Spacing.modalPadding,
                ),
                child: Column(
                  children: [
                    const SheetHandle(),
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Scrollbar(
                              controller: scrollController,
                              child: _filteredModels.isEmpty
                                  ? Center(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            Platform.isIOS
                                                ? CupertinoIcons.search_circle
                                                : Icons.search_off,
                                            size: 48,
                                            color: context
                                                .conduitTheme
                                                .iconSecondary,
                                          ),
                                          const SizedBox(height: Spacing.md),
                                          Text(
                                            AppLocalizations.of(
                                              context,
                                            )!.noResults,
                                            style: AppTypography.bodyLargeStyle
                                                .copyWith(
                                                  color: context
                                                      .conduitTheme
                                                      .textSecondary,
                                                ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : ListView.builder(
                                      controller: scrollController,
                                      padding: const EdgeInsets.only(top: 120),
                                      itemCount: _filteredModels.length,
                                      itemBuilder: (context, index) {
                                        final model = _filteredModels[index];
                                        final isAutoSelect =
                                            model.id == 'auto-select';
                                        final isSelected = isAutoSelect
                                            ? _selectedModelId == null ||
                                                  _selectedModelId ==
                                                      'auto-select'
                                            : _selectedModelId == model.id;
                                        final api = ref.watch(
                                          apiServiceProvider,
                                        );
                                        final iconUrl = isAutoSelect
                                            ? null
                                            : resolveModelIconUrlForModel(
                                                api,
                                                model,
                                              );

                                        return ModelListTile(
                                          model: model,
                                          isSelected: isSelected,
                                          isAutoSelect: isAutoSelect,
                                          iconUrl: iconUrl,
                                          onTap: () {
                                            final selectedId = isAutoSelect
                                                ? 'auto-select'
                                                : model.id;
                                            Navigator.pop(context, selectedId);
                                          },
                                        );
                                      },
                                    ),
                            ),
                          ),
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  stops: const [0.0, 0.65, 1.0],
                                  colors: [
                                    context.sidebarTheme.background,
                                    context.sidebarTheme.background.withValues(
                                      alpha: 0.9,
                                    ),
                                    context.sidebarTheme.background.withValues(
                                      alpha: 0.0,
                                    ),
                                  ],
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(height: Spacing.md),
                                  ConduitGlassSearchField(
                                    controller: _searchController,
                                    hintText: AppLocalizations.of(
                                      context,
                                    )!.searchModels,
                                    onChanged: _filterModels,
                                    query: _searchQuery,
                                    onClear: () {
                                      _searchController.clear();
                                      _filterModels('');
                                    },
                                  ),
                                  const SizedBox(height: Spacing.md),
                                  Row(
                                    children: [
                                      Text(
                                        AppLocalizations.of(
                                          context,
                                        )!.availableModels,
                                        style: AppTypography.labelStyle
                                            .copyWith(
                                              fontWeight: FontWeight.w600,
                                              color: context
                                                  .conduitTheme
                                                  .textSecondary,
                                              letterSpacing: 0.2,
                                            ),
                                      ),
                                      const SizedBox(width: Spacing.xs),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: context.sidebarTheme.background
                                              .withValues(alpha: 0.6),
                                          borderRadius: BorderRadius.circular(
                                            AppBorderRadius.xs,
                                          ),
                                          border: Border.all(
                                            color: context
                                                .conduitTheme
                                                .dividerColor,
                                            width: BorderWidth.thin,
                                          ),
                                        ),
                                        child: Text(
                                          '${_filteredModels.length}',
                                          style: AppTypography.labelMediumStyle
                                              .copyWith(
                                                color: context
                                                    .conduitTheme
                                                    .textSecondary,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: Spacing.md),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
