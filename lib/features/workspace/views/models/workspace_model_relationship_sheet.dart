import 'package:flutter/material.dart';

import 'package:conduit/features/workspace/providers/workspace_model_relationships.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/middle_ellipsis_text.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';

/// A searchable multi-select sheet used by the model editor to attach
/// relationships (knowledge, tools, skills, filters, actions). Returns the new
/// selected id list on save, or null if dismissed. Ids that were selected but
/// no longer resolve to an option are preserved so unknown relationships are
/// never silently dropped.
class WorkspaceRelationshipSheet extends StatefulWidget {
  const WorkspaceRelationshipSheet({
    super.key,
    required this.title,
    required this.options,
    required this.selectedIds,
  });

  final String title;
  final List<WorkspaceRelationshipOption> options;
  final List<String> selectedIds;

  static Future<List<String>?> show(
    BuildContext context, {
    required String title,
    required List<WorkspaceRelationshipOption> options,
    required List<String> selectedIds,
  }) {
    return ThemedSheets.showCustom<List<String>>(
      context: context,
      builder: (_) => WorkspaceRelationshipSheet(
        title: title,
        options: options,
        selectedIds: selectedIds,
      ),
    );
  }

  @override
  State<WorkspaceRelationshipSheet> createState() =>
      _WorkspaceRelationshipSheetState();
}

class _WorkspaceRelationshipSheetState
    extends State<WorkspaceRelationshipSheet> {
  late final Set<String> _selected;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _selected = {...widget.selectedIds};
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<WorkspaceRelationshipOption> get _visible {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.options;
    return widget.options
        .where(
          (option) =>
              option.label.toLowerCase().contains(query) ||
              option.id.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  List<String> _result() {
    // Keep selected ids that are not in the available options (e.g. a stale or
    // server-managed relationship) so saving does not drop them.
    final known = widget.options.map((o) => o.id).toSet();
    final result = <String>[
      for (final option in widget.options)
        if (_selected.contains(option.id)) option.id,
      for (final id in widget.selectedIds)
        if (!known.contains(id) && _selected.contains(id)) id,
    ];
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final visible = _visible;

    return ConduitModalSheetSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(widget.title, style: theme.headingSmall),
              ),
              SheetCloseButton(
                tooltip: l10n.close,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          ConduitGlassSearchField(
            controller: _searchController,
            hintText: l10n.workspaceSearchHint,
            query: _query,
            onChanged: (value) => setState(() => _query = value),
            onClear: () {
              _searchController.clear();
              setState(() => _query = '');
            },
          ),
          const SizedBox(height: Spacing.sm),
          Flexible(
            child: widget.options.isEmpty
                ? Padding(
                    key: const Key('workspace-relationship-empty'),
                    padding: const EdgeInsets.all(Spacing.lg),
                    child: Text(
                      l10n.workspaceModelRelationshipEmpty,
                      textAlign: TextAlign.center,
                      style: theme.bodySmall?.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                  )
                : Material(
                    type: MaterialType.transparency,
                    child: ListView.builder(
                    key: const Key('workspace-relationship-list'),
                    shrinkWrap: true,
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final option = visible[index];
                      final selected = _selected.contains(option.id);
                      return CheckboxListTile(
                        key: Key('workspace-relationship-${option.id}'),
                        value: selected,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: MiddleEllipsisText(option.label),
                        subtitle: option.subtitle == null
                            ? null
                            : Text(
                                option.subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        onChanged: (value) => setState(() {
                          if (value == true) {
                            _selected.add(option.id);
                          } else {
                            _selected.remove(option.id);
                          }
                        }),
                      );
                    },
                    ),
                  ),
          ),
          const SizedBox(height: Spacing.sm),
          ConduitButton(
            key: const Key('workspace-relationship-save'),
            text: l10n.save,
            isFullWidth: true,
            onPressed: () => Navigator.of(context).pop(_result()),
          ),
        ],
      ),
    );
  }
}
