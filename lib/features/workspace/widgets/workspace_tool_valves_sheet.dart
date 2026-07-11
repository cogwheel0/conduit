import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/conduit_loading.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'workspace_valve_form.dart';

/// Bottom sheet that edits a tool's server valves and per-user valves using
/// dynamic forms driven by the server's valve specs. Mirrors Open WebUI's
/// `ValvesModal`, including the `array` string↔list conversion on load/save.
class WorkspaceToolValvesSheet extends ConsumerStatefulWidget {
  const WorkspaceToolValvesSheet({super.key, required this.toolId});

  final String toolId;

  static Future<void> show(BuildContext context, {required String toolId}) {
    return ThemedSheets.showCustom<void>(
      context: context,
      builder: (_) => WorkspaceToolValvesSheet(toolId: toolId),
    );
  }

  @override
  ConsumerState<WorkspaceToolValvesSheet> createState() =>
      _WorkspaceToolValvesSheetState();
}

class _WorkspaceToolValvesSheetState
    extends ConsumerState<WorkspaceToolValvesSheet> {
  bool _userScope = false;
  bool _loading = true;
  bool _saving = false;
  bool _loadError = false;

  WorkspaceValveSpec? _serverSpec;
  WorkspaceValveSpec? _userSpec;
  Map<String, dynamic> _serverValues = {};
  Map<String, dynamic> _userValues = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = false;
    });
    final notifier = ref.read(workspaceToolsProvider.notifier);
    try {
      final serverSpec = await notifier.toolValvesSpec(widget.toolId);
      final serverValues = await notifier.toolValves(widget.toolId);
      final userSpec = await notifier.userToolValvesSpec(widget.toolId);
      final userValues = await notifier.userToolValves(widget.toolId);
      if (!mounted) return;
      setState(() {
        _serverSpec = serverSpec;
        _userSpec = userSpec;
        _serverValues = _hydrate(serverSpec, serverValues);
        _userValues = _hydrate(userSpec, userValues);
        _loading = false;
      });
    } catch (error, stackTrace) {
      DebugLogger.error(
        'tool valves load failed',
        scope: 'workspace/tools',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = true;
      });
    }
  }

  /// Joins `array`-typed values into comma strings for editing, matching the
  /// upstream load path.
  Map<String, dynamic> _hydrate(
    WorkspaceValveSpec? spec,
    Map<String, dynamic> values,
  ) {
    final result = Map<String, dynamic>.from(values);
    if (spec == null) return result;
    spec.properties.forEach((property, raw) {
      final propSpec = raw is Map ? raw : const {};
      if (propSpec['type'] == 'array') {
        final current = result[property];
        result[property] = current is List ? current.join(', ') : current;
      }
    });
    return result;
  }

  /// Splits comma strings back into lists for `array`-typed values before
  /// submit, matching the upstream save path.
  Map<String, dynamic> _serialize(
    WorkspaceValveSpec? spec,
    Map<String, dynamic> values,
  ) {
    final result = Map<String, dynamic>.from(values);
    if (spec == null) return result;
    spec.properties.forEach((property, raw) {
      final propSpec = raw is Map ? raw : const {};
      if (propSpec['type'] == 'array') {
        final current = result[property];
        if (current is String) {
          result[property] = current
              .split(',')
              .map((v) => v.trim())
              .where((v) => v.isNotEmpty)
              .toList(growable: false);
        }
      }
    });
    return result;
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = ref.read(workspaceToolsProvider.notifier);
    setState(() => _saving = true);
    try {
      if (_userScope) {
        await notifier.updateUserToolValves(
          widget.toolId,
          _serialize(_userSpec, _userValues),
        );
      } else {
        await notifier.updateToolValves(
          widget.toolId,
          _serialize(_serverSpec, _serverValues),
        );
      }
      if (!mounted) return;
      AdaptiveSnackBar.show(
        context,
        message: l10n.workspaceToolValvesSaved,
        type: AdaptiveSnackBarType.success,
      );
      Navigator.of(context).pop();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'tool valves save failed',
        scope: 'workspace/tools',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() => _saving = false);
      AdaptiveSnackBar.show(
        context,
        message: l10n.workspaceToolValvesSaveFailed,
        type: AdaptiveSnackBarType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final spec = _userScope ? _userSpec : _serverSpec;

    return ConduitModalSheetSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(l10n.workspaceToolValvesTitle, style: theme.headingSmall),
              ),
              SheetCloseButton(
                tooltip: l10n.close,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          SegmentedButton<bool>(
            key: const Key('workspace-tool-valves-scope'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: false,
                label: Text(l10n.workspaceToolValvesServer),
              ),
              ButtonSegment(
                value: true,
                label: Text(l10n.workspaceToolValvesUser),
              ),
            ],
            selected: {_userScope},
            onSelectionChanged: _saving
                ? null
                : (value) => setState(() => _userScope = value.first),
          ),
          const SizedBox(height: Spacing.sm),
          if (_loading)
            Padding(
              padding: const EdgeInsets.all(Spacing.lg),
              child: Center(child: ConduitLoading.inline(context: context)),
            )
          else if (_loadError)
            Padding(
              key: const Key('workspace-tool-valves-error'),
              padding: const EdgeInsets.symmetric(vertical: Spacing.md),
              child: Text(
                l10n.workspaceToolValvesLoadFailed,
                style: theme.bodySmall?.copyWith(color: theme.error),
              ),
            )
          else
            Flexible(
              child: SingleChildScrollView(
                child: WorkspaceValveForm(
                  key: ValueKey('workspace-tool-valve-form-$_userScope'),
                  spec: spec ?? const WorkspaceValveSpec(schema: {}),
                  initialValues: _userScope ? _userValues : _serverValues,
                  enabled: !_saving,
                  onChanged: (values) {
                    if (_userScope) {
                      _userValues = values;
                    } else {
                      _serverValues = values;
                    }
                  },
                ),
              ),
            ),
          const SizedBox(height: Spacing.md),
          ConduitButton(
            key: const Key('workspace-tool-valves-save'),
            text: l10n.save,
            isLoading: _saving,
            isFullWidth: true,
            onPressed: (_loading || _loadError || _saving) ? null : _save,
          ),
        ],
      ),
    );
  }
}
