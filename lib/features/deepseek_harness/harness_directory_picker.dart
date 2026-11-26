import 'package:conduit_core/features/deepseek_harness/deepseek_harness.dart';
import 'package:conduit_core/features/deepseek_harness/deepseek_harness_client.dart';
import 'package:flutter/services.dart'
    show SmartDashesType, SmartQuotesType, TextInputAction;
import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/theme_extensions.dart';
import '../../shared/widgets/adaptive_route_shell.dart';
import '../../shared/widgets/adaptive_toolbar_components.dart';
import '../../shared/widgets/platform_ui/platform_ui.dart';
import '../../shared/widgets/platform_ui/vocabulary.dart';
import '../../shared/widgets/themed_sheets.dart';

/// Selects a working directory on the authenticated Harness server.
Future<HarnessWorkspace?> showHarnessWorkspacePicker(
  BuildContext context,
  DeepSeekHarnessClient client,
) => ThemedSheets.showFullscreenPage<HarnessWorkspace>(
  context: context,
  builder: (_) => _DirectoryPicker(client: client),
);

enum _Input { path, folderName }

class _DirectoryPicker extends StatefulWidget {
  const _DirectoryPicker({required this.client});
  final DeepSeekHarnessClient client;

  @override
  State<_DirectoryPicker> createState() => _DirectoryPickerState();
}

class _DirectoryPickerState extends State<_DirectoryPicker> {
  final _text = TextEditingController();
  HarnessDirectoryListing? _listing;
  _Input? _input;
  String? _error;
  String? _requestedPath;
  bool _retryBrowse = false;
  bool _manualOnly = false;
  bool _showHidden = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _browse();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _browse([String? path]) async {
    if (_busy) return;
    _requestedPath = path;
    setState(() {
      _busy = true;
      _retryBrowse = false;
      _error = null;
    });
    try {
      final listing = await widget.client.listDirectories(path);
      if (mounted) setState(() => _listing = listing);
    } catch (error) {
      if (mounted) {
        setState(() {
          if (path == null &&
              error is HarnessWorkspaceException &&
              error.issue == HarnessWorkspaceIssue.browseUnavailable) {
            _manualOnly = true;
            _input = _Input.path;
          } else {
            _error = _errorMessage(error, browsing: true);
            _retryBrowse = true;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _errorMessage(Object error, {bool browsing = false}) {
    final l10n = AppLocalizations.of(context)!;
    return switch (error) {
      HarnessWorkspaceException(issue: HarnessWorkspaceIssue.invalidPath) =>
        l10n.deepSeekHarnessInvalidPath,
      HarnessWorkspaceException(issue: HarnessWorkspaceIssue.directoryExists) =>
        l10n.deepSeekHarnessDirectoryExists,
      HarnessWorkspaceException(
        issue: HarnessWorkspaceIssue.browseUnavailable,
      ) =>
        l10n.deepSeekHarnessBrowseFailed,
      DeepSeekHarnessException(reason: DeepSeekHarnessFailure.unauthorized) =>
        l10n.deepSeekHarnessUnauthorized,
      DeepSeekHarnessException(reason: DeepSeekHarnessFailure.untrustedHost) =>
        l10n.deepSeekHarnessUntrustedHost,
      _ when browsing => l10n.deepSeekHarnessBrowseFailed,
      _ when _input == _Input.folderName => l10n.failedToCreateFolder,
      _ => l10n.deepSeekHarnessCreateFailed,
    };
  }

  void _edit(_Input? input) {
    if (_busy) return;
    _text.clear();
    setState(() {
      _input = input;
      _error = null;
      _retryBrowse = false;
    });
    if (input == null && _listing == null) _browse(_requestedPath);
  }

  Future<void> _submit() async {
    if (_busy || ModalRoute.of(context)?.isCurrent != true) return;
    final name = _text.text;
    final creatingFolder = _input == _Input.folderName;
    final path = _input == _Input.path ? name : _listing?.path;
    final l10n = AppLocalizations.of(context)!;
    if (creatingFolder &&
        (name.trim().isEmpty ||
            name == '.' ||
            name == '..' ||
            name.contains(RegExp(r'[/\\\x00]')))) {
      setState(() => _error = l10n.deepSeekHarnessInvalidFolderName);
      return;
    }
    if (path == null || path.trim().isEmpty) {
      setState(() => _error = l10n.deepSeekHarnessInvalidPath);
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _retryBrowse = false;
      _error = null;
    });
    try {
      if (creatingFolder) {
        final child = await widget.client.createDirectory(path, name);
        if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
        setState(() {
          _busy = false;
          _input = null;
          _listing = null;
        });
        await _browse(child);
      } else {
        final result = await widget.client.createWorkspace(path);
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).pop(result);
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final listing = _listing;
    final input = _input;
    final parent = listing != null && listing.crumbs.length > 1
        ? listing.crumbs[listing.crumbs.length - 2]
        : null;
    final entries = input == null
        ? listing?.entries ?? const <HarnessDirectoryEntry>[]
        : const <HarnessDirectoryEntry>[];
    final hasHidden = entries.any((entry) => entry.hidden);
    final visible = hasHidden && !_showHidden
        ? entries.where((entry) => !entry.hidden).toList(growable: false)
        : entries;
    return AdaptiveRouteShell(
      bodySafeArea: true,
      safeAreaTop: false,
      appBar: AdaptiveAppBar(
        title: l10n.deepSeekHarnessNewWorkspace,
        leading: ConduitAdaptiveAppBarIconButton(
          icon: Icons.close,
          iosSymbol: 'xmark',
          semanticLabel: l10n.cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(Spacing.pagePadding),
        itemCount: 1 + visible.length,
        itemBuilder: (context, index) {
          if (index > 0) {
            final entry = visible[index - 1];
            return AdaptiveListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(entry.name),
              trailing: const Icon(Icons.chevron_right),
              enabled: !_busy,
              onTap: () => _browse(entry.path),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                input == _Input.path
                    ? l10n.deepSeekHarnessEnterExistingPath
                    : l10n.deepSeekHarnessChooseServerFolder,
              ),
              if (listing != null) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  listing.path,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
              const SizedBox(height: Spacing.md),
              if (input != null) ...[
                Text(
                  input == _Input.path
                      ? l10n.deepSeekHarnessEnterFolderPath
                      : l10n.folderName,
                ),
                const SizedBox(height: Spacing.sm),
                Semantics(
                  label: input == _Input.path
                      ? l10n.deepSeekHarnessEnterFolderPath
                      : l10n.folderName,
                  child: AdaptiveTextField(
                    key: ValueKey(input),
                    controller: _text,
                    autofocus: true,
                    enabled: !_busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    smartDashesType: SmartDashesType.disabled,
                    smartQuotesType: SmartQuotesType.disabled,
                    autofillHints: null,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                AdaptiveButton(
                  label: input == _Input.path
                      ? l10n.deepSeekHarnessUseFolder
                      : l10n.create,
                  onPressed: _busy ? null : _submit,
                ),
                if (!_manualOnly)
                  AdaptiveButton(
                    label: l10n.cancel,
                    style: AdaptiveButtonStyle.plain,
                    onPressed: _busy ? null : () => _edit(null),
                  ),
              ] else ...[
                if (listing != null)
                  AdaptiveButton(
                    label: l10n.deepSeekHarnessUseFolder,
                    onPressed: _busy ? null : _submit,
                  ),
                Wrap(
                  children: [
                    if (listing != null)
                      AdaptiveButton(
                        label: l10n.newFolder,
                        style: AdaptiveButtonStyle.plain,
                        onPressed: _busy
                            ? null
                            : () => _edit(_Input.folderName),
                      ),
                    AdaptiveButton(
                      label: l10n.deepSeekHarnessEnterFolderPath,
                      style: AdaptiveButtonStyle.plain,
                      onPressed: _busy ? null : () => _edit(_Input.path),
                    ),
                  ],
                ),
              ],
              if (_busy) const Center(child: AdaptiveProgressIndicator()),
              if (_error case final error?)
                Semantics(liveRegion: true, child: Text(error)),
              if (_retryBrowse)
                AdaptiveButton(
                  label: l10n.retry,
                  style: AdaptiveButtonStyle.plain,
                  onPressed: () => _browse(_requestedPath),
                ),
              if (hasHidden)
                AdaptiveListTile(
                  title: Text(l10n.deepSeekHarnessShowHiddenFolders),
                  trailing: AdaptiveSwitch(
                    value: _showHidden,
                    semanticLabel: l10n.deepSeekHarnessShowHiddenFolders,
                    onChanged: (value) => setState(() => _showHidden = value),
                  ),
                  onTap: () => setState(() => _showHidden = !_showHidden),
                ),
              if (input == null && parent != null)
                AdaptiveListTile(
                  leading: const Icon(Icons.arrow_upward),
                  title: Text(l10n.deepSeekHarnessParentFolder),
                  enabled: !_busy,
                  onTap: () => _browse(parent.path),
                ),
              if (input == null && listing != null && !_busy)
                if (listing.truncated)
                  Text(l10n.deepSeekHarnessMoreFolders)
                else if (listing.entries.isEmpty)
                  Text(l10n.deepSeekHarnessNoSubfolders),
            ],
          );
        },
      ),
    );
  }
}
