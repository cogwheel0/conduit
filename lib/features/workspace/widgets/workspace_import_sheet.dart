import 'dart:convert';
import 'dart:io';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/workspace/models/workspace_common.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';

// ---------------------------------------------------------------------------
// Import result model + per-item runner (reused by every section importer).
// ---------------------------------------------------------------------------

/// Outcome of importing a single item.
@immutable
class WorkspaceImportItemResult {
  const WorkspaceImportItemResult({
    required this.index,
    required this.label,
    required this.succeeded,
    this.error,
  });

  final int index;
  final String label;
  final bool succeeded;
  final String? error;
}

/// Aggregated import outcome across every item.
@immutable
class WorkspaceImportReport {
  const WorkspaceImportReport(this.results);

  final List<WorkspaceImportItemResult> results;

  int get total => results.length;
  int get successCount => results.where((r) => r.succeeded).length;
  int get failureCount => total - successCount;
  bool get hasFailures => failureCount > 0;

  List<WorkspaceImportItemResult> get failures =>
      results.where((r) => !r.succeeded).toList(growable: false);
}

/// Applies [importItem] to each entry, capturing per-item failures instead of
/// aborting the whole batch on the first error. Never throws for item-level
/// failures — the failure is recorded on the returned report.
Future<WorkspaceImportReport> runWorkspaceImport(
  List<Map<String, dynamic>> items, {
  required Future<void> Function(Map<String, dynamic> item) importItem,
  String Function(Map<String, dynamic> item)? labelOf,
  String fallbackLabel = 'item',
}) async {
  final results = <WorkspaceImportItemResult>[];
  for (var index = 0; index < items.length; index++) {
    final item = items[index];
    final label = _resolveLabel(item, index, labelOf, fallbackLabel);
    try {
      await importItem(item);
      results.add(
        WorkspaceImportItemResult(
          index: index,
          label: label,
          succeeded: true,
        ),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace import item failed',
        scope: 'workspace/import',
        error: error,
        stackTrace: stackTrace,
        data: {'index': index},
      );
      results.add(
        WorkspaceImportItemResult(
          index: index,
          label: label,
          succeeded: false,
          error: error.toString(),
        ),
      );
    }
  }
  return WorkspaceImportReport(results);
}

String _resolveLabel(
  Map<String, dynamic> item,
  int index,
  String Function(Map<String, dynamic> item)? labelOf,
  String fallbackLabel,
) {
  if (labelOf != null) {
    final resolved = labelOf(item).trim();
    if (resolved.isNotEmpty) return resolved;
  }
  final name =
      item['name']?.toString() ??
      item['title']?.toString() ??
      item['id']?.toString();
  if (name != null && name.trim().isNotEmpty) return name.trim();
  return '$fallbackLabel ${index + 1}';
}

/// Coerces decoded JSON into a list of item maps. Accepts a bare list, a single
/// object, or an envelope of the form `{ "items": [...] }` / `{ "<key>": [...] }`.
List<Map<String, dynamic>> workspaceImportItemsFromJson(dynamic decoded) {
  if (decoded is List) {
    return workspaceJsonList(decoded);
  }
  if (decoded is Map) {
    final map = workspaceJsonMap(decoded);
    for (final value in map.values) {
      if (value is List) return workspaceJsonList(value);
    }
    // A single object is treated as a one-item import.
    return [map];
  }
  return const [];
}

typedef WorkspaceImporter =
    Future<WorkspaceImportReport> Function(List<Map<String, dynamic>> items);

/// Reads the contents of a user-picked JSON file, or null if cancelled.
typedef WorkspaceImportFilePicker = Future<String?> Function();

Future<String?> _defaultPickJsonFile() async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: const ['json'],
  );
  if (file == null) return null;
  final bytes = file.path != null
      ? await File(file.path!).readAsBytes()
      : await file.readAsBytes();
  return utf8.decode(bytes);
}

// ---------------------------------------------------------------------------
// Import sheet.
// ---------------------------------------------------------------------------

/// Bottom sheet that imports JSON items (via file pick or paste) and reports
/// per-item success/failure. The actual persistence is delegated to [importer]
/// so each section can wire its own endpoint while sharing this UI.
class WorkspaceImportSheet extends StatefulWidget {
  const WorkspaceImportSheet({
    super.key,
    required this.title,
    required this.importer,
    this.filePicker,
    this.labelOf,
  });

  final String title;
  final WorkspaceImporter importer;
  final WorkspaceImportFilePicker? filePicker;
  final String Function(Map<String, dynamic> item)? labelOf;

  static Future<WorkspaceImportReport?> show(
    BuildContext context, {
    required String title,
    required WorkspaceImporter importer,
    WorkspaceImportFilePicker? filePicker,
    String Function(Map<String, dynamic> item)? labelOf,
  }) {
    return ThemedSheets.showCustom<WorkspaceImportReport>(
      context: context,
      builder: (_) => WorkspaceImportSheet(
        title: title,
        importer: importer,
        filePicker: filePicker,
        labelOf: labelOf,
      ),
    );
  }

  @override
  State<WorkspaceImportSheet> createState() => _WorkspaceImportSheetState();
}

class _WorkspaceImportSheetState extends State<WorkspaceImportSheet> {
  final _controller = TextEditingController();
  bool _running = false;
  String? _errorKey;
  WorkspaceImportReport? _report;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final picker = widget.filePicker ?? _defaultPickJsonFile;
    try {
      final content = await picker();
      if (content == null || !mounted) return;
      setState(() {
        _controller.text = content;
        _errorKey = null;
      });
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace import file pick failed',
        scope: 'workspace/import',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() => _errorKey = 'read');
    }
  }

  Future<void> _run() async {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() => _errorKey = 'invalid');
      return;
    }
    late final List<Map<String, dynamic>> items;
    try {
      items = workspaceImportItemsFromJson(json.decode(raw));
    } catch (_) {
      setState(() => _errorKey = 'invalid');
      return;
    }
    if (items.isEmpty) {
      setState(() => _errorKey = 'empty');
      return;
    }
    setState(() {
      _running = true;
      _errorKey = null;
      _report = null;
    });
    try {
      final report = await widget.importer(items);
      if (!mounted) return;
      setState(() {
        _report = report;
        _running = false;
      });
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace import batch failed',
        scope: 'workspace/import',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _errorKey = 'batch';
        _running = false;
      });
    }
  }

  String _errorMessage(AppLocalizations l10n, String key) => switch (key) {
    'invalid' => l10n.workspaceImportInvalidJson,
    'empty' => l10n.workspaceImportEmpty,
    'read' => l10n.workspaceImportReadFailed,
    _ => l10n.workspaceImportBatchFailed,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final report = _report;

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
                onPressed: () => Navigator.of(context).pop(_report),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          if (report != null)
            Flexible(child: _reportView(context, l10n, report))
          else
            Flexible(child: _inputView(context, l10n)),
        ],
      ),
    );
  }

  Widget _inputView(BuildContext context, AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return ListView(
      shrinkWrap: true,
      children: [
        ConduitButton(
          key: const Key('workspace-import-pick'),
          text: l10n.workspaceImportChooseFile,
          icon: Icons.upload_file_outlined,
          isSecondary: true,
          isFullWidth: true,
          onPressed: _running ? null : _pickFile,
        ),
        const SizedBox(height: Spacing.md),
        Text(
          l10n.workspaceImportPasteLabel,
          style: theme.label?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.xs),
        AdaptiveTextField(
          key: const Key('workspace-import-json-field'),
          controller: _controller,
          minLines: 4,
          maxLines: 10,
          enabled: !_running,
          textInputAction: TextInputAction.newline,
          keyboardType: TextInputType.multiline,
          style: theme.code?.copyWith(color: theme.textPrimary),
          placeholder: l10n.workspaceImportPasteHint,
        ),
        if (_errorKey != null) ...[
          const SizedBox(height: Spacing.sm),
          Row(
            key: const Key('workspace-import-error'),
            children: [
              Icon(
                Icons.error_outline,
                size: IconSize.small,
                color: theme.error,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  _errorMessage(l10n, _errorKey!),
                  style: theme.bodySmall?.copyWith(color: theme.error),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: Spacing.md),
        ConduitButton(
          key: const Key('workspace-import-run'),
          text: l10n.workspaceImportRun,
          isLoading: _running,
          isFullWidth: true,
          onPressed: _running ? null : _run,
        ),
      ],
    );
  }

  Widget _reportView(
    BuildContext context,
    AppLocalizations l10n,
    WorkspaceImportReport report,
  ) {
    final theme = context.conduitTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.workspaceImportSummary(report.successCount, report.total),
          key: const Key('workspace-import-summary'),
          style: theme.bodyMedium?.copyWith(
            color: report.hasFailures ? theme.error : theme.success,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Flexible(
          child: ListView.builder(
            key: const Key('workspace-import-results'),
            shrinkWrap: true,
            itemCount: report.results.length,
            itemBuilder: (context, index) {
              final result = report.results[index];
              return AdaptiveListTile(
                key: Key('workspace-import-result-${result.index}'),
                padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
                leading: Icon(
                  result.succeeded
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                  color: result.succeeded ? theme.success : theme.error,
                ),
                title: Text(
                  result.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: result.succeeded
                    ? Text(l10n.workspaceImportItemImported)
                    : Text(
                        result.error ?? l10n.workspaceImportItemFailed,
                        style: theme.caption?.copyWith(color: theme.error),
                      ),
              );
            },
          ),
        ),
        const SizedBox(height: Spacing.sm),
        ConduitButton(
          key: const Key('workspace-import-done'),
          text: l10n.workspaceImportDone,
          isFullWidth: true,
          onPressed: () => Navigator.of(context).pop(report),
        ),
      ],
    );
  }
}
