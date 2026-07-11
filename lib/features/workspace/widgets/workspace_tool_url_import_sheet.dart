import 'package:flutter/material.dart';

import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/workspace/models/workspace_common.dart';
import 'package:conduit/features/workspace/models/workspace_tool_content.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';

/// Loads a tool definition from a URL. Returns the raw tool map, or null.
typedef WorkspaceToolUrlLoader =
    Future<Map<String, dynamic>> Function(String url);

/// Admin-only bottom sheet that imports a tool from a raw or GitHub URL.
///
/// GitHub `tree`/`blob` URLs are normalized to their `raw.githubusercontent.com`
/// form before the load, matching the server's `github_url_to_raw_url`. On
/// success the loaded tool map is returned so the caller can prefill an unsaved
/// create editor (never a silent server-side create).
class WorkspaceToolUrlImportSheet extends StatefulWidget {
  const WorkspaceToolUrlImportSheet({super.key, required this.loader});

  final WorkspaceToolUrlLoader loader;

  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    required WorkspaceToolUrlLoader loader,
  }) {
    return ThemedSheets.showCustom<Map<String, dynamic>>(
      context: context,
      builder: (_) => WorkspaceToolUrlImportSheet(loader: loader),
    );
  }

  @override
  State<WorkspaceToolUrlImportSheet> createState() =>
      _WorkspaceToolUrlImportSheetState();
}

class _WorkspaceToolUrlImportSheetState
    extends State<WorkspaceToolUrlImportSheet> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _errorKey;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final raw = _controller.text.trim();
    final uri = Uri.tryParse(raw);
    if (raw.isEmpty || uri == null || !uri.hasScheme || !uri.isAbsolute) {
      setState(() => _errorKey = 'invalid');
      return;
    }
    final normalized = WorkspaceToolContent.githubUrlToRawUrl(raw);
    // Only forward GitHub tool URLs to the server's fetch endpoint; reject
    // internal/link-local/metadata hosts before any network call.
    if (!WorkspaceToolContent.isAllowedImportUrl(normalized)) {
      setState(() => _errorKey = 'host');
      return;
    }
    setState(() {
      _loading = true;
      _errorKey = null;
    });
    try {
      final tool = await widget.loader(normalized);
      if (!mounted) return;
      Navigator.of(context).pop(tool);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'tool url import failed',
        scope: 'workspace/tools',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorKey = 'failed';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return ConduitModalSheetSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.workspaceToolImportUrlTitle,
                  style: theme.headingSmall,
                ),
              ),
              SheetCloseButton(
                tooltip: l10n.close,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            l10n.workspaceToolImportUrlLabel,
            style: theme.label?.copyWith(color: theme.textSecondary),
          ),
          const SizedBox(height: Spacing.xs),
          TextField(
            key: const Key('workspace-tool-url-field'),
            controller: _controller,
            enabled: !_loading,
            keyboardType: TextInputType.url,
            autocorrect: false,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _loading ? null : _run(),
            style: theme.code?.copyWith(color: theme.textPrimary),
            decoration: InputDecoration(
              hintText: l10n.workspaceToolImportUrlHint,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
          if (_errorKey != null) ...[
            const SizedBox(height: Spacing.sm),
            Row(
              key: const Key('workspace-tool-url-error'),
              children: [
                Icon(
                  Icons.error_outline,
                  size: IconSize.small,
                  color: theme.error,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    switch (_errorKey) {
                      'invalid' => l10n.workspaceToolImportUrlInvalid,
                      'host' => l10n.workspaceToolImportUrlHost,
                      _ => l10n.workspaceToolImportUrlFailed,
                    },
                    style: theme.bodySmall?.copyWith(color: theme.error),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: Spacing.md),
          ConduitButton(
            key: const Key('workspace-tool-url-run'),
            text: l10n.workspaceToolImportUrl,
            isLoading: _loading,
            isFullWidth: true,
            onPressed: _loading ? null : _run,
          ),
        ],
      ),
    );
  }
}

/// Applies front-matter overrides from a loaded/import tool payload, mirroring
/// Open WebUI's ImportModal: an id defaults to `nameToId(name)`, a front-matter
/// `title` overrides the name, and the description falls back to the name.
Map<String, dynamic> normalizeImportedTool(Map<String, dynamic> tool) {
  final result = Map<String, dynamic>.from(tool);
  final name = result['name']?.toString() ?? '';
  final content = result['content']?.toString() ?? '';
  final rawId = result['id']?.toString().trim() ?? '';
  final frontmatter = WorkspaceToolContent.parseFrontmatter(content);

  final title = frontmatter['title']?.trim();
  final resolvedName = (title != null && title.isNotEmpty) ? title : name;
  result['name'] = resolvedName;
  // Derive the id from the original name *before* the front-matter title
  // override (matching upstream's ImportModal), so a payload like
  // `{name: 'main', content: '---\ntitle: Web Search\n---'}` keeps id `main`
  // rather than retargeting to `web_search`.
  result['id'] = rawId.isNotEmpty
      ? rawId
      : WorkspaceToolContent.nameToId(name.isNotEmpty ? name : resolvedName);

  final meta = workspaceJsonMap(result['meta']);
  final fmDescription = frontmatter['description']?.trim();
  meta['description'] = (fmDescription != null && fmDescription.isNotEmpty)
      ? fmDescription
      : (meta['description']?.toString() ?? resolvedName);
  result['meta'] = meta;
  return result;
}
