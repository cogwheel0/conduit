import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';

import 'package:conduit_core/features/hermes/models/hermes_file_entry.dart';
import 'package:conduit_core/features/hermes/services/hermes_file_browser_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../providers/hermes_file_browser.dart';
import '../providers/hermes_mobile_files.dart';
import 'hermes_file_preview.dart';
import 'hermes_media_attachment.dart';
import 'package:conduit_core/features/hermes/models/hermes_media.dart';
import '../providers/hermes_media.dart';
import 'hermes_message_icon.dart';
import 'hermes_mobile_shell.dart' show HermesLoadError;
import 'hermes_mobile_shell.dart'
    show HermesAreaHeader, startHermesMobileConversation;

class HermesFilesArea extends ConsumerStatefulWidget {
  const HermesFilesArea({super.key});
  @override
  ConsumerState<HermesFilesArea> createState() => _FilesHomeState();
}

class _FilesHomeState extends ConsumerState<HermesFilesArea> {
  bool _folders = false;
  final _queryController = TextEditingController();
  Object? _connection;
  String _query = '';
  HermesFileCategory _category = HermesFileCategory.all;
  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(hermesApiServiceProvider);
    if (!identical(connection, _connection)) {
      _connection = connection;
      _queryController.clear();
      _query = '';
      _category = HermesFileCategory.all;
      _folders = false;
    }
    final service = ref.watch(hermesFileBrowserAccessProvider);
    if (_folders) {
      return _FileExplorer(
        key: ObjectKey(service),
        service: service,
        onExit: () => setState(() => _folders = false),
      );
    }
    final l = AppLocalizations.of(context)!;
    final library = ref.watch(hermesMobileFilesProvider);
    final live = ref.watch(hermesLiveFilesProvider);
    final liveIds = live.map((file) => file.identity).toSet();
    final all = [
      ...live,
      ...(library.asData?.value.files ?? const <HermesLibraryFile>[]).where(
        (file) => !liveIds.contains(file.identity),
      ),
    ];
    final files = all
        .where(
          (f) =>
              (_category == HermesFileCategory.all ||
                  f.category == _category) &&
              '${f.name} ${f.session.title}'.toLowerCase().contains(
                _query.toLowerCase(),
              ),
        )
        .toList();
    String label(HermesFileCategory c) => switch (c) {
      HermesFileCategory.all => l.mobileAllFiles,
      HermesFileCategory.artifacts => l.mobileArtifacts,
      HermesFileCategory.outputs => l.mobileOutputs,
      HermesFileCategory.uploads => l.mobileUploads,
    };
    return Column(
      children: [
        HermesAreaHeader(
          title: l.mobileFiles,
          action: service == null
              ? null
              : TextButton.icon(
                  key: const ValueKey('hermes-files-folders'),
                  onPressed: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    setState(() => _folders = true);
                  },
                  icon: const Icon(HermesMessageIcons.folder, size: 20),
                  label: Text(l.folders),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: CompactSearchField(
                  hint: l.mobileSearchFiles,
                  controller: _queryController,
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              CompactPopupMenu<HermesFileCategory>(
                tooltip: l.mobileFilterFiles,
                icon: const Icon(HermesMessageIcons.filter),
                choices: [
                  for (final c in HermesFileCategory.values)
                    CompactMenuChoice(c, label(c), selected: _category == c),
                ],
                onSelected: (c) => setState(() => _category = c),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(hermesMobileFilesProvider);
              await ref.read(hermesMobileFilesProvider.future);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (library.isLoading && all.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: AdaptiveProgressIndicator()),
                  ),
                if (library.hasError)
                  HermesLoadError(
                    onRetry: () => ref.invalidate(hermesMobileFilesProvider),
                  ),
                if (library.asData?.value.indexing == true)
                  const LinearProgressIndicator(),
                if (library.asData?.value.partial == true)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(l.mobileFilesPartial),
                  ),
                if (!library.isLoading &&
                    !library.hasError &&
                    library.asData?.value.indexing != true &&
                    files.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      _query.isEmpty
                          ? l.mobileNoFiles
                          : l.mobileNoSearchResults,
                    ),
                  ),
                for (final f in files)
                  CompactContentRow(
                    key: ValueKey('hermes-library-${f.identity}'),
                    leading: const Icon(HermesMessageIcons.file, size: 24),
                    title: Text(
                      f.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      f.session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: HermesMediaReference.fromPath(f.outputPath, name: f.name) == null ? const Icon(HermesMessageIcons.next, size: 18)
                        : CompactIconAction(tooltip: 'Download ${f.name}', icon: const Icon(Icons.download_outlined, size: 22),
                            onPressed: () => showHermesMedia(context, HermesMediaReference.fromPath(f.outputPath, name: f.name)!, sessionId: f.session.id, download: true)),
                    onTap: () => showHermesFilePreview(context, ref, f),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Reuses the file explorer while keeping navigation within this workspace.
class HermesScopedFilesArea extends ConsumerWidget {
  const HermesScopedFilesArea({
    super.key,
    required this.root,
    required this.profile,
    this.readOnly = false,
    this.composerTarget = chatComposerTextInsertionTargetId,
  });
  final String root, profile;
  final bool readOnly;
  final String composerTarget;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final base = ref.watch(hermesFileBrowserAccessProvider);
    if (base == null) {
      return const Center(child: Text('Files are unavailable.'));
    }
    final scoped = _ScopedFiles(base, root, readOnly, profile);
    final pinsKey = ref.watch(hermesFilePinStorageKeyProvider);
    return ProviderScope(
      key: ValueKey((root, profile, readOnly)),
      overrides: [
        hermesFileBrowserAccessProvider.overrideWithValue(scoped),
        hermesDirectoryProvider.overrideWith(
          (ref, path) => scoped.browseFiles(path: path),
        ),
        hermesFilePinStorageKeyProvider.overrideWithValue(
          pinsKey == null
              ? null
              : '$pinsKey.workspace.$profile.${Uri.encodeComponent(root)}',
        ),
      ],
      child: _FileExplorer(
        service: scoped,
        initialPath: root,
        embedded: true,
        composerTarget: composerTarget,
      ),
    );
  }
}

class _ScopedFiles implements HermesFileBrowserService {
  const _ScopedFiles(this.base, this.root, this.readOnly, this.profile);
  final HermesFileBrowserService base;
  final String root;
  final bool readOnly;
  final String profile;
  p.Context get _paths => p.Context(
    style: RegExp(r'^[A-Za-z]:[\\/]').hasMatch(root)
        ? p.Style.windows
        : p.Style.posix,
  );
  bool _inside(String path) =>
      _paths.equals(_paths.normalize(path), _paths.normalize(root)) ||
      _paths.isWithin(_paths.normalize(root), _paths.normalize(path));
  void _check(String path, [bool write = false]) {
    if (!_inside(path)) {
      throw ArgumentError('This path is outside the workspace.');
    }
    if (write && readOnly) throw StateError('These files are read-only.');
  }

  @override
  Future<HermesDirectory> browseFiles({
    String? path,
    CancelToken? cancelToken,
  }) async {
    _check(path ?? root);
    final directory = await base.browseFiles(
      path: path ?? root,
      cancelToken: cancelToken,
    );
    _check(directory.path);
    return HermesDirectory(
      path: directory.path,
      root: root,
      parent: directory.parent != null && _inside(directory.parent!)
          ? directory.parent
          : null,
      canChangePath: false,
      entries: directory.entries
          .where(
            (entry) =>
                _inside(entry.path) &&
                !entry.name.startsWith('.') &&
                !const {
                  'auth.json',
                  'config.yaml',
                  'profile.yaml',
                  'gateway_state.json',
                }.contains(entry.name),
          )
          .toList(),
    );
  }

  @override
  Future<void> createDirectory({
    required String directory,
    required String name,
  }) {
    _check(directory, true);
    return base.createDirectory(directory: directory, name: name);
  }

  @override
  Future<void> createFile({
    required String directory,
    required String name,
    required String content,
  }) {
    _check(directory, true);
    return base.createFile(directory: directory, name: name, content: content);
  }

  @override
  Future<String> readFileDataUrl(String path, {CancelToken? cancelToken}) {
    _check(path);
    return base.readFileDataUrl(path, cancelToken: cancelToken);
  }
}

class _FileExplorer extends ConsumerStatefulWidget {
  const _FileExplorer({
    super.key,
    required this.service,
    this.initialPath,
    this.embedded = false,
    this.onExit,
    this.composerTarget = chatComposerTextInsertionTargetId,
  });
  final HermesFileBrowserService? service;
  final String? initialPath;
  final bool embedded;
  final VoidCallback? onExit;
  final String composerTarget;
  @override
  ConsumerState<_FileExplorer> createState() => _FileExplorerState();
}

enum _FileAction { ask, pin, copy }

class _FileExplorerState extends ConsumerState<_FileExplorer> {
  String? _path;
  String _search = '';
  int _homeRevision = 0;
  bool _pinnedOnly = false;
  final List<({String? path, bool pinned})> _history = [];
  late final HermesFileBrowserBack _backNavigation;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    _backNavigation = ref.read(hermesFileBrowserBackProvider);
    _backNavigation.register(
      this,
      _back,
      home: () {
        if (widget.onExit != null) {
          widget.onExit!();
          return;
        }
        setState(() {
          _homeRevision++;
          _history.clear();
          _path = widget.initialPath;
          _pinnedOnly = false;
          _search = '';
        });
      },
    );
  }

  bool _back() {
    if (_history.isEmpty) {
      if (widget.onExit == null) return false;
      widget.onExit!();
      return true;
    }
    final previous = _history.removeLast();
    setState(() {
      _path = previous.path;
      _pinnedOnly = previous.pinned;
      _search = '';
    });
    return true;
  }

  @override
  void dispose() {
    _backNavigation.clear(this);
    super.dispose();
  }

  bool get _current =>
      mounted &&
      identical(widget.service, ref.read(hermesFileBrowserAccessProvider));

  void _browse(String? path) => setState(() {
    if (_path != path || _pinnedOnly) {
      _history.add((path: _path, pinned: _pinnedOnly));
      if (_history.length > 50) _history.removeAt(0);
    }
    _path = path;
    _pinnedOnly = false;
    _search = '';
  });

  void _notify(String text) => AdaptiveSnackBar.show(context, message: text);

  Future<void> _actions(HermesFileEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    final pins = ref.read(hermesFilePinsProvider).asData?.value ?? const [];
    final pinned = pins.any((pin) => pin.path == entry.path);
    final action = await showCompactConfigurationSheet<_FileAction>(
      context,
      (context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              entry.name,
              style: Theme.of(context).textTheme.titleMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              entry.path,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            for (final item in [
              (
                _FileAction.ask,
                Icons.chat_bubble_outline,
                l10n.mobileFilesAskHermes,
              ),
              (
                _FileAction.pin,
                pinned ? Icons.push_pin : Icons.push_pin_outlined,
                pinned ? l10n.unpin : l10n.pin,
              ),
              (_FileAction.copy, Icons.copy_outlined, l10n.mobileFilesCopyPath),
            ])
              CompactContentRow(
                leading: Icon(item.$2, size: 22),
                title: Text(item.$3),
                onTap: () => Navigator.of(context).pop(item.$1),
              ),
          ],
        ),
      ),
    );
    if (!_current || action == null) return;
    switch (action) {
      case _FileAction.ask:
        // The reference is a quoted path. No content is read and no turn is
        // sent until the user edits or sends the visible composer draft.
        if (widget.embedded) {
          ref
              .read(composerTextInsertionProvider.notifier)
              .insert(
                targetId: widget.composerTarget,
                text: entry.isDirectory
                    ? l10n.mobileFilesAskFolder(jsonEncode(entry.path))
                    : l10n.mobileFilesAskFile(jsonEncode(entry.path)),
                separateParagraph: true,
              );
          _notify('Added to the chat draft.');
          return;
        }
        await startHermesMobileConversation(
          ref,
          prefill: entry.isDirectory
              ? l10n.mobileFilesAskFolder(jsonEncode(entry.path))
              : l10n.mobileFilesAskFile(jsonEncode(entry.path)),
        );
      case _FileAction.pin:
        try {
          await ref.read(hermesFilePinsProvider.notifier).toggle(entry);
        } catch (_) {
          if (_current) _notify(l10n.mobileFilesPinError);
        }
      case _FileAction.copy:
        await Clipboard.setData(ClipboardData(text: entry.path));
    }
  }

  Future<void> _open(HermesFileEntry entry, {bool download = false}) async {
    if (entry.isDirectory) {
      _browse(entry.path);
      return;
    }
    final service = widget.service;
    if (service == null) return;
    if (service is _ScopedFiles) service._check(entry.path);
    final media = HermesMediaReference.fromPath(entry.path, name: entry.name, size: entry.size);
    if (media != null && ref.read(hermesMediaLeaseFactoryProvider) != null) {
      await showHermesMedia(context, media, profile: service is _ScopedFiles ? service.profile : null, download: download);
      return;
    }
    await showCompactConversationSheet(
      context,
      _ServerFilePreview(entry: entry, service: service),
    );
  }

  Future<void> _goToFolder(String path) async {
    final result = await showCompactConfigurationSheet<String>(
      context,
      (context) => _FolderLocation(initialPath: path),
    );
    if (_current && result != null) _browse(result);
  }

  Future<void> _create(HermesDirectory directory, bool folder) async {
    final service = widget.service;
    if (service == null) return;
    final created = await showCompactConfigurationSheet<bool>(
      context,
      (context) => _FileCreator(
        directory: directory.path,
        folder: folder,
        service: service,
      ),
    );
    if (!mounted || !_current || created != true) return;
    ref.invalidate(hermesDirectoryProvider(_path));
    _notify(AppLocalizations.of(context)!.mobileFilesCreated);
  }

  Widget _row(HermesFileEntry entry, Set<String> pins) {
    final l10n = AppLocalizations.of(context)!;
    final subtitle = _pinnedOnly
        ? entry.path
        : entry.isDirectory
        ? null
        : entry.size == null
        ? l10n.mobileFilesFile
        : _sizeLabel(entry.size!);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('hermes-explorer-entry-${entry.path}'),
        onTap: () => _open(entry),
        onLongPress: () => _actions(entry),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
          child: Row(
            children: [
              Icon(
                entry.isDirectory
                    ? Icons.folder_outlined
                    : Icons.insert_drive_file_outlined,
                color: entry.isDirectory
                    ? context.conduitTheme.textPrimary
                    : context.conduitTheme.textSecondary,
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.conduitTheme.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (pins.contains(entry.path))
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.push_pin, size: 16),
                ),
              if (!entry.isDirectory && ref.watch(hermesMediaLeaseFactoryProvider) != null)
                CompactIconAction(tooltip: 'Download ${entry.name}', icon: const Icon(Icons.download_outlined, size: 22),
                  onPressed: () => _open(entry, download: true)),
              CompactIconAction(
                key: ValueKey('hermes-explorer-actions-${entry.path}'),
                tooltip: '${l10n.mobileFilesActions}: ${entry.name}',
                icon: const Icon(Icons.more_horiz, size: 22),
                onPressed: () => _actions(entry),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _scopeTab({required String label, required bool pinned}) {
    final selected = _pinnedOnly == pinned;
    final theme = context.conduitTheme;
    return Semantics(
      key: ValueKey('hermes-explorer-${pinned ? 'pinned' : 'browse'}-state'),
      selected: selected,
      child: DecoratedBox(
        key: ValueKey(
          'hermes-explorer-${pinned ? 'pinned' : 'browse'}-indicator',
        ),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? theme.textPrimary : theme.dividerColor,
              width: selected ? 2 : 1,
            ),
          ),
        ),
        child: TextButton(
          key: ValueKey('hermes-explorer-${pinned ? 'pinned' : 'browse'}'),
          onPressed: () => setState(() {
            _pinnedOnly = pinned;
            _search = '';
          }),
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            foregroundColor: theme.textPrimary,
          ),
          child: Text(label),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (widget.service == null) {
      return Column(
        children: [
          if (!widget.embedded)
            HermesAreaHeader(
              title: widget.onExit == null ? l10n.mobileFiles : l10n.folders,
              leading: widget.onExit == null
                  ? null
                  : CompactIconAction(
                      tooltip: l10n.back,
                      icon: const Icon(HermesMessageIcons.back),
                      key: const ValueKey('hermes-explorer-back'),
                      onPressed: () {
                        _back();
                      },
                    ),
            ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.mobileFilesUnavailable),
              ),
            ),
          ),
        ],
      );
    }
    final directory = ref.watch(hermesDirectoryProvider(_path));
    final pins = ref.watch(hermesFilePinsProvider);
    final listing = directory.asData?.value;
    final pinnedEntries = pins.asData?.value ?? const <HermesFileEntry>[];
    final pinnedPaths = pinnedEntries.map((entry) => entry.path).toSet();
    final browsePins = !_pinnedOnly && _search.isEmpty
        ? pinnedEntries.take(5).toList()
        : const <HermesFileEntry>[];
    final browsePinnedPaths = browsePins.map((entry) => entry.path).toSet();
    final currentPath = listing?.path ?? _path;
    final entries =
        (_pinnedOnly
                ? pinnedEntries
                : listing?.entries ?? const <HermesFileEntry>[])
            .where(
              (entry) =>
                  entry.name.toLowerCase().contains(_search.toLowerCase()) &&
                  !browsePinnedPaths.contains(entry.path),
            )
            .toList()
          ..sort((a, b) {
            if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
    return Column(
      children: [
        if (!widget.embedded)
          HermesAreaHeader(
            title: widget.onExit == null ? l10n.mobileFiles : l10n.folders,
            leading: widget.onExit == null
                ? null
                : CompactIconAction(
                    tooltip: l10n.back,
                    icon: const Icon(HermesMessageIcons.back),
                    key: const ValueKey('hermes-explorer-back'),
                    onPressed: () {
                      _back();
                    },
                  ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: _scopeTab(label: l10n.mobileFilesBrowse, pinned: false),
              ),
              Expanded(child: _scopeTab(label: l10n.pinned, pinned: true)),
              if (widget.service is! _ScopedFiles ||
                  !(widget.service as _ScopedFiles).readOnly)
                CompactPopupMenu<bool>(
                  key: const ValueKey('hermes-explorer-create'),
                  tooltip: l10n.mobileFilesCreateHere,
                  icon: const Icon(Icons.add, size: 22),
                  onSelected: (folder) {
                    if (listing != null) _create(listing, folder);
                  },
                  choices: listing == null || _pinnedOnly
                      ? const []
                      : [
                          CompactMenuChoice(false, l10n.mobileFilesNewFile),
                          CompactMenuChoice(true, l10n.newFolder),
                        ],
                ),
            ],
          ),
        ),
        if (!_pinnedOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 16, 4),
            child: Row(
              children: [
                CompactIconAction(
                  key: const ValueKey('hermes-explorer-home'),
                  tooltip: l10n.mobileFilesHome,
                  icon: const Icon(Icons.home_outlined, size: 22),
                  onPressed: () => _browse(null),
                ),
                CompactIconAction(
                  key: const ValueKey('hermes-explorer-parent'),
                  tooltip: l10n.mobileFilesParent,
                  icon: const Icon(Icons.arrow_upward, size: 22),
                  onPressed: listing?.parent == null
                      ? null
                      : () => _browse(listing!.parent),
                ),
                Expanded(
                  child: Tooltip(
                    message: currentPath ?? l10n.mobileFilesHome,
                    child: TextButton(
                      key: const ValueKey('hermes-explorer-path'),
                      onPressed: listing?.canChangePath == false
                          ? null
                          : () => _goToFolder(listing?.path ?? _path ?? ''),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              currentPath == null
                                  ? l10n.mobileFilesHome
                                  : _folderName(currentPath),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: context.conduitTheme.textPrimary,
                                  ),
                            ),
                          ),
                          if (listing?.canChangePath != false)
                            const Padding(
                              padding: EdgeInsets.only(left: 8),
                              child: Icon(Icons.edit_outlined, size: 16),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: CompactSearchField(
            key: ValueKey(
              'hermes-explorer-search-$_path-$_pinnedOnly-$_homeRevision',
            ),
            hint: l10n.mobileSearchFiles,
            onChanged: (value) => setState(() => _search = value),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              if (_pinnedOnly) {
                ref.invalidate(hermesFilePinsProvider);
                await ref.read(hermesFilePinsProvider.future);
              } else {
                ref.invalidate(hermesDirectoryProvider(_path));
                try {
                  await ref.read(hermesDirectoryProvider(_path).future);
                } catch (_) {
                  /* Render the error below. */
                }
              }
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                if ((_pinnedOnly ? pins.isLoading : directory.isLoading))
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: AdaptiveProgressIndicator()),
                  )
                else if ((_pinnedOnly
                    ? pins.hasError
                    : directory.hasError)) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      _pinnedOnly
                          ? l10n.mobileFilesPinError
                          : l10n.mobileFilesLoadError,
                    ),
                  ),
                  AdaptiveButton(
                    label: l10n.retry,
                    style: AdaptiveButtonStyle.plain,
                    onPressed: () {
                      if (_pinnedOnly) {
                        ref.invalidate(hermesFilePinsProvider);
                      } else {
                        ref.invalidate(hermesDirectoryProvider(_path));
                      }
                    },
                  ),
                ] else if (entries.isEmpty && browsePins.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      _search.isNotEmpty
                          ? l10n.mobileNoSearchResults
                          : _pinnedOnly
                          ? l10n.mobileFilesPinnedEmpty
                          : l10n.mobileFilesEmptyFolder,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: context.conduitTheme.textSecondary),
                    ),
                  )
                else ...[
                  if (browsePins.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(
                        l10n.pinned,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    for (final entry in browsePins) _row(entry, pinnedPaths),
                    if (entries.isNotEmpty) const Divider(height: 24),
                  ],
                  for (final entry in entries) _row(entry, pinnedPaths),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String _folderName(String path) {
  final paths = p.Context(
    style: RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)
        ? p.Style.windows
        : p.Style.posix,
  );
  return paths.basename(paths.normalize(path));
}

String _sizeLabel(int size) => size < 1024
    ? '$size B'
    : size < 1024 * 1024
    ? '${(size / 1024).toStringAsFixed(1)} KB'
    : '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';

class _FolderLocation extends StatefulWidget {
  const _FolderLocation({required this.initialPath});
  final String initialPath;
  @override
  State<_FolderLocation> createState() => _FolderLocationState();
}

class _FolderLocationState extends State<_FolderLocation> {
  late final _controller = TextEditingController(text: widget.initialPath);
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go() {
    if (hermesFilePath(_controller.text.trim()) != null) {
      Navigator.of(context).pop(_controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.mobileFilesGoToFolder,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          ConduitInput(
            key: const ValueKey('hermes-explorer-location-input'),
            controller: _controller,
            label: l10n.mobileFilesPathHint,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          AdaptiveButton(
            label: l10n.mobileFilesGoToFolder,
            onPressed: hermesFilePath(_controller.text.trim()) == null
                ? null
                : _go,
          ),
        ],
      ),
    );
  }
}

class _FileCreator extends ConsumerStatefulWidget {
  const _FileCreator({
    required this.directory,
    required this.folder,
    required this.service,
  });
  final String directory;
  final bool folder;
  final HermesFileBrowserService service;
  @override
  ConsumerState<_FileCreator> createState() => _FileCreatorState();
}

class _FileCreatorState extends ConsumerState<_FileCreator> {
  final _name = TextEditingController();
  final _content = TextEditingController();
  bool _busy = false;
  bool _failed = false;
  bool _invalid = false;
  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy ||
        !identical(widget.service, ref.read(hermesFileBrowserAccessProvider))) {
      return;
    }
    if (!hermesFileNameIsValid(_name.text)) {
      setState(() => _invalid = true);
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
      _invalid = false;
    });
    try {
      if (widget.folder) {
        await widget.service.createDirectory(
          directory: widget.directory,
          name: _name.text,
        );
      } else {
        await widget.service.createFile(
          directory: widget.directory,
          name: _name.text,
          content: _content.text,
        );
      }
      if (mounted &&
          identical(
            widget.service,
            ref.read(hermesFileBrowserAccessProvider),
          )) {
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final current = identical(
      widget.service,
      ref.watch(hermesFileBrowserAccessProvider),
    );
    return PopScope(
      canPop: !_busy,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              MediaQuery.viewInsetsOf(context).bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.folder ? l10n.newFolder : l10n.mobileFilesNewFile,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  widget.directory,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                ConduitInput(
                  key: const ValueKey('hermes-explorer-name'),
                  controller: _name,
                  label: widget.folder
                      ? l10n.folderName
                      : l10n.mobileFilesFileName,
                  errorText: _invalid ? l10n.mobileFilesInvalidName : null,
                  enabled: !_busy && current,
                ),
                if (!widget.folder) ...[
                  const SizedBox(height: 16),
                  ConduitInput(
                    key: const ValueKey('hermes-explorer-content'),
                    controller: _content,
                    label: l10n.mobileFilesContent,
                    minLines: 3,
                    maxLines: 6,
                    enabled: !_busy && current,
                  ),
                ],
                if (_failed || !current)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(l10n.mobileFilesCreateError),
                  ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: AdaptiveButton(
                        label: l10n.cancel,
                        style: AdaptiveButtonStyle.plain,
                        onPressed: _busy
                            ? null
                            : () => Navigator.of(context).pop(false),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: AdaptiveButton.child(
                        key: const ValueKey('hermes-explorer-save'),
                        onPressed: _busy || !current ? null : _save,
                        child: _busy
                            ? const AdaptiveProgressIndicator()
                            : Text(l10n.create),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ServerFilePreview extends ConsumerStatefulWidget {
  const _ServerFilePreview({required this.entry, required this.service});
  final HermesFileEntry entry;
  final HermesFileBrowserService service;
  @override
  ConsumerState<_ServerFilePreview> createState() => _ServerFilePreviewState();
}

class _ServerFilePreviewState extends ConsumerState<_ServerFilePreview> {
  static const _maximumPreviewBytes = 1024 * 1024;
  final _cancel = CancelToken();
  Future<String>? _data;
  @override
  void initState() {
    super.initState();
    final size = widget.entry.size;
    if (size == null || size >= 0 && size <= _maximumPreviewBytes) {
      _data = _readPreview();
    }
  }

  Future<String> _readPreview() async {
    var size = widget.entry.size;
    if (size == null) {
      // Restored pins contain paths rather than stale file metadata. Resolve
      // the size through the server before downloading a pinned file.
      final index = widget.entry.path.lastIndexOf(RegExp(r'[/\\]'));
      if (index < 0) throw const FormatException('Missing file metadata');
      final parent = widget.entry.path.substring(0, index == 0 ? 1 : index);
      final listing = await widget.service.browseFiles(
        path: parent,
        cancelToken: _cancel,
      );
      final matches = listing.entries.where(
        (entry) => entry.path == widget.entry.path && !entry.isDirectory,
      );
      if (matches.isNotEmpty) size = matches.first.size;
    }
    if (!mounted ||
        _cancel.isCancelled ||
        size == null ||
        size < 0 ||
        size > _maximumPreviewBytes) {
      throw const FormatException('File is too large to preview');
    }
    return widget.service.readFileDataUrl(
      widget.entry.path,
      cancelToken: _cancel,
    );
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  Widget _preview(String raw) {
    final l10n = AppLocalizations.of(context)!;
    try {
      final data = UriData.parse(raw);
      final bytes = data.contentAsBytes();
      if (bytes.length > _maximumPreviewBytes) {
        return Text(l10n.mobileFilesPreviewUnavailable);
      }
      if (data.mimeType.startsWith('image/')) {
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => Text(l10n.mobileFilesPreviewUnavailable),
        );
      }
      final text =
          data.mimeType.startsWith('text/') ||
          RegExp(
            r'\.(md|txt|json|yaml|yml|toml|py|dart|js|ts|kt|swift|sh|csv|log)$',
            caseSensitive: false,
          ).hasMatch(widget.entry.name);
      return text
          ? SelectableText(
              utf8.decode(bytes.take(100000).toList(), allowMalformed: true),
            )
          : Text(l10n.mobileFilesPreviewUnavailable);
    } catch (_) {
      return Text(l10n.mobileFilesPreviewUnavailable);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final current = identical(
      widget.service,
      ref.watch(hermesFileBrowserAccessProvider),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.entry.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              CompactIconAction(
                tooltip: l10n.close,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          Text(
            widget.entry.path,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Expanded(
            child: current && _data != null
                ? FutureBuilder<String>(
                    future: _data,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return Column(
                          children: [
                            Text(l10n.mobileFilesPreviewUnavailable),
                            AdaptiveButton(
                              label: l10n.retry,
                              style: AdaptiveButtonStyle.plain,
                              onPressed: () => setState(() {
                                _data = _readPreview();
                              }),
                            ),
                          ],
                        );
                      }
                      if (!snapshot.hasData) {
                        return const Center(child: AdaptiveProgressIndicator());
                      }
                      return SingleChildScrollView(
                        child: _preview(snapshot.data!),
                      );
                    },
                  )
                : Text(l10n.mobileFilesPreviewUnavailable),
          ),
        ],
      ),
    );
  }
}
