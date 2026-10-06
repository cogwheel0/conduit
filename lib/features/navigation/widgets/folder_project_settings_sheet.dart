import 'dart:async';

import 'package:collection/collection.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';
import '../../../shared/widgets/modal_safe_area.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../workspace/providers/workspace_providers.dart';

/// Opens the project settings editor for [folder].
///
/// The signed-in account is captured here, before anything is awaited, and the
/// editor holds it until it saves: it is not looked up again on Save.
Future<void> showFolderProjectSettings(
  BuildContext context,
  WidgetRef ref,
  Folder folder,
) {
  final owner = ref.read(foldersProvider.notifier).captureProjectOwner();
  if (owner == null) {
    UiUtils.showMessage(context, AppLocalizations.of(context)!.errorMessage);
    return Future<void>.value();
  }
  return showAdaptiveSelectionSheet<void>(
    context: context,
    builder: (_) => FolderProjectSettingsSheet(folder: folder, owner: owner),
  );
}

/// Edits a folder's project defaults: the system prompt, the knowledge that
/// is attached to its chats, and the ordered default models a new chat starts
/// with. Only what the person changed is saved.
class FolderProjectSettingsSheet extends ConsumerStatefulWidget {
  const FolderProjectSettingsSheet({
    super.key,
    required this.folder,
    required this.owner,
  });

  final Folder folder;
  final FolderProjectOwner owner;

  @override
  ConsumerState<FolderProjectSettingsSheet> createState() =>
      _FolderProjectSettingsSheetState();
}

enum _PickerKind { knowledge, models }

class _Option {
  const _Option(this.id, this.label, this.type);

  final String id;
  final String label;

  /// `collection` or `file` for knowledge, `model` for models.
  final String type;
}

class _Picker {
  _Picker(this.kind, this.taken);

  final _PickerKind kind;

  /// What the folder already has, which is not offered again.
  final Set<String> taken;

  /// Every option shown so far. A choice resolves against this, so it keeps its
  /// name and type after a search has replaced the list it was made in.
  final Map<String, _Option> known = <String, _Option>{};
  final List<String> selected = <String>[];
  String query = '';

  /// The models, or the person's own files: read once and narrowed here.
  List<_Option>? fixed;
  bool fixedLoading = true;
  bool fixedFailed = false;

  /// The knowledge bases, asked of the server a page at a time for
  /// [collectionQuery] (null until the first page arrives).
  List<_Option> collections = const <_Option>[];
  String? collectionQuery;
  int collectionPage = 0;
  bool collectionsMore = false;
  bool collectionsLoading = false;
  bool collectionsFailed = false;

  /// The failed knowledge request was for a later page, not the first.
  bool failedOnMore = false;

  /// The sign-in changed, so nothing further is asked or shown.
  bool ownerChanged = false;

  /// Names the latest knowledge request; an older answer is dropped.
  int generation = 0;

  bool get failed => fixedFailed || collectionsFailed;

  void remember(Iterable<_Option> options) {
    for (final option in options) {
      known[option.id] = option;
    }
  }
}

class _FolderProjectSettingsSheetState
    extends ConsumerState<FolderProjectSettingsSheet> {
  static const _same = DeepCollectionEquality();

  late List<Object?> _baseFiles;
  late List<Object?> _baseModels;
  late String _basePrompt;
  late List<Object?> _files;
  late List<Object?> _models;
  final _prompt = TextEditingController();
  final _search = TextEditingController();
  _Picker? _picker;
  Timer? _searchTimer;
  bool _saving = false;
  String? _failure;

  /// Saved file references the server has said it cannot find. A file is only
  /// listed here on that answer: unreadable or offline stays unknown.
  final Set<String> _missingFiles = <String>{};
  final Set<String> _checkedFiles = <String>{};

  /// How many file lookups are in flight at once.
  static const _fileChecksInFlight = 4;

  @override
  void initState() {
    super.initState();
    _adopt(widget.folder, keepEdits: false);
    unawaited(_checkSavedFiles());
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _prompt.dispose();
    _search.dispose();
    super.dispose();
  }

  /// Takes [folder]'s project fields as the new baseline. A field the person
  /// has already edited keeps their edit; the rest follows the baseline.
  void _adopt(Folder folder, {required bool keepEdits}) {
    final files = folder.projectFileEntries;
    final models = folder.projectModelIdEntries;
    final prompt = folder.projectSystemPrompt;
    if (!keepEdits || _same.equals(_files, _baseFiles)) {
      _files = List<Object?>.of(files);
    }
    if (!keepEdits || _same.equals(_models, _baseModels)) {
      _models = List<Object?>.of(models);
    }
    if (!keepEdits || _prompt.text.trim() == _basePrompt.trim()) {
      _prompt.text = prompt;
    }
    _baseFiles = files;
    _baseModels = models;
    _basePrompt = prompt;
  }

  /// Refreshes the baseline from the server as the account that opened the
  /// sheet. Offline, or with edits here not sent yet, the form keeps this
  /// device's copy.
  Future<void> _refresh() async {
    Folder? latest;
    try {
      latest = await ref
          .read(foldersProvider.notifier)
          .loadProjectDetail(widget.owner, widget.folder.id);
    } catch (_) {
      return;
    }
    if (!mounted || latest == null) return;
    final detail = latest;
    setState(() => _adopt(detail, keepEdits: true));
    unawaited(_checkSavedFiles());
  }

  /// Asks the server, as the account that opened the sheet, whether each saved
  /// individual file still exists. A file is looked up once, a few at a time.
  /// Listing the user's own files cannot answer this: a shared file is valid
  /// without being in it.
  Future<void> _checkSavedFiles() async {
    final pending = <String>[
      for (final entry in _files)
        if (FolderProjectFile.tryParse(entry) case final file?
            when file.type == 'file' && _checkedFiles.add(file.id))
          file.id,
    ];
    final folders = ref.read(foldersProvider.notifier);
    for (var i = 0; i < pending.length; i += _fileChecksInFlight) {
      final batch = pending.skip(i).take(_fileChecksInFlight);
      final answers = await Future.wait([
        for (final id in batch)
          folders
              .projectFileExists(widget.owner, id)
              .then(
                (exists) => (id, exists),
                onError: (Object _) => (id, null),
              ),
      ]);
      if (!mounted) return;
      final gone = [
        for (final (id, exists) in answers)
          if (exists == false) id,
      ];
      if (gone.isNotEmpty) setState(() => _missingFiles.addAll(gone));
    }
  }

  bool get _filesChanged => !_same.equals(_files, _baseFiles);
  bool get _modelsChanged => !_same.equals(_models, _baseModels);
  bool _promptChanged(bool editsPrompt) =>
      editsPrompt && _prompt.text.trim() != _basePrompt.trim();

  void _edit(VoidCallback change) => setState(() {
    _failure = null;
    change();
  });

  Future<void> _save(AppLocalizations l10n, bool editsPrompt) async {
    final promptChanged = _promptChanged(editsPrompt);
    if (!_filesChanged && !_modelsChanged && !promptChanged) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _failure = null;
    });
    try {
      await ref
          .read(foldersProvider.notifier)
          .saveProjectDefaults(
            widget.owner,
            widget.folder.id,
            files: _filesChanged ? _files : null,
            modelIds: _modelsChanged ? _models : null,
            systemPrompt: promptChanged ? _prompt.text.trim() : null,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      UiUtils.showMessage(context, l10n.saved);
    } on FolderProjectWriteException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failure = switch (error.reason) {
          FolderProjectWriteFailure.ownerChanged =>
            l10n.folderProjectOwnerChanged,
          FolderProjectWriteFailure.readOnly => l10n.folderProjectReadOnly,
          FolderProjectWriteFailure.unavailable => l10n.folderProjectGone,
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failure = l10n.errorMessage;
      });
    }
  }

  // ---- pickers --------------------------------------------------------

  /// How long typing pauses before a knowledge search is asked of the server.
  static const _searchDelay = Duration(milliseconds: 300);

  Future<void> _openPicker(_PickerKind kind) async {
    final taken = <String>{};
    if (kind == _PickerKind.models) {
      for (final entry in _models) {
        if (entry is String) taken.add(entry);
      }
    } else {
      for (final entry in _files) {
        final id = FolderProjectFile.tryParse(entry)?.id;
        if (id != null) taken.add(id);
      }
    }
    final picker = _Picker(kind, taken);
    _searchTimer?.cancel();
    _search.clear();
    setState(() {
      _failure = null;
      _picker = picker;
    });
    if (kind == _PickerKind.models) {
      await _loadModels(picker);
    } else {
      await Future.wait([
        _loadCollections(picker, more: false),
        _loadFiles(picker),
      ]);
    }
  }

  bool _pickerIsCurrent(_Picker picker) =>
      mounted && identical(_picker, picker);

  bool get _ownerIsCurrent =>
      ref.read(foldersProvider.notifier).isCurrentProjectOwner(widget.owner);

  /// The sign-in the editor opened under is gone: whatever was asked for it is
  /// dropped unseen, and nothing here can be added or saved any more.
  void _pickerOwnerChanged(_Picker picker) {
    final message = AppLocalizations.of(context)!.folderProjectOwnerChanged;
    setState(() {
      picker.ownerChanged = true;
      picker.fixedLoading = false;
      picker.collectionsLoading = false;
      picker.collectionsFailed = true;
      picker.fixed = null;
      picker.collections = const <_Option>[];
      picker.selected.clear();
      _failure = message;
    });
  }

  Future<void> _loadModels(_Picker picker) async {
    List<_Option>? options;
    try {
      final models = await ref.read(modelsProvider.future);
      options = [
        for (final model in folderDefaultModelCandidates(models))
          _Option(model.id, model.name, 'model'),
      ];
    } catch (_) {}
    if (!_pickerIsCurrent(picker)) return;
    setState(() {
      picker.fixedLoading = false;
      if (options == null) {
        picker.fixedFailed = true;
      } else {
        picker.fixed = options;
        picker.remember(options);
      }
    });
  }

  Future<void> _loadFiles(_Picker picker) async {
    List<_Option>? options;
    try {
      final files = await ref.read(userFilesProvider.future);
      options = [
        for (final file in files) _Option(file.id, file.displayName, 'file'),
      ];
    } catch (_) {}
    if (!_pickerIsCurrent(picker)) return;
    if (!_ownerIsCurrent) {
      _pickerOwnerChanged(picker);
      return;
    }
    setState(() {
      picker.fixedLoading = false;
      if (options == null) {
        picker.fixedFailed = true;
      } else {
        picker.fixed = options;
        picker.remember(options);
      }
    });
  }

  /// Asks the server, as the account that opened the sheet, for a page of the
  /// knowledge bases it may read: the first page of what is typed in the search
  /// field, or with [more] the next page of what is listed. The query and view
  /// are this picker's own; Workspace's list and its filters are not touched.
  /// An answer is shown only while this is still the latest request of the open
  /// picker and the same account is still signed in.
  Future<void> _loadCollections(_Picker picker, {required bool more}) async {
    if (more && picker.collectionsLoading) return;
    final query = more ? picker.collectionQuery ?? '' : picker.query.trim();
    final page = more ? picker.collectionPage + 1 : 1;
    final generation = ++picker.generation;
    setState(() {
      picker.collectionsLoading = true;
      picker.collectionsFailed = false;
    });
    final api = _ownerIsCurrent ? ref.read(apiServiceProvider) : null;
    var asked = false;
    List<_Option> fetched = const <_Option>[];
    var total = 0;
    if (api != null) {
      try {
        final response = await api.getWorkspaceKnowledge(
          query: query,
          page: page,
        );
        fetched = [
          for (final item in response.items)
            _Option(item.id, item.name, 'collection'),
        ];
        total = response.total;
        asked = true;
      } catch (_) {}
    }
    if (!_pickerIsCurrent(picker) || generation != picker.generation) return;
    if (!_ownerIsCurrent) {
      _pickerOwnerChanged(picker);
      return;
    }
    setState(() {
      picker.collectionsLoading = false;
      if (!asked) {
        picker.collectionsFailed = true;
        picker.failedOnMore = more;
        return;
      }
      picker.remember(fetched);
      final seen = <String>{};
      final listed = [
        for (final option in [if (more) ...picker.collections, ...fetched])
          if (seen.add(option.id)) option,
      ];
      picker.collections = listed;
      picker.collectionQuery = query;
      picker.collectionPage = page;
      // An empty page ends the list however many the server says there are.
      picker.collectionsMore = fetched.isNotEmpty && listed.length < total;
    });
  }

  Future<void> _retryPicker(_Picker picker) async {
    if (picker.ownerChanged) return;
    if (picker.fixedFailed && picker.kind == _PickerKind.knowledge) {
      setState(() {
        picker.fixedFailed = false;
        picker.fixedLoading = true;
      });
      ref.invalidate(userFilesProvider);
      unawaited(_loadFiles(picker));
    }
    if (picker.collectionsFailed) {
      await _loadCollections(picker, more: picker.failedOnMore);
    }
  }

  /// Asks the server for knowledge matching the search field, once typing
  /// pauses (or [immediate]ly), unless that is what is already listed.
  void _searchCollections(_Picker picker, {required bool immediate}) {
    _searchTimer?.cancel();
    void run() {
      if (!_pickerIsCurrent(picker) || picker.ownerChanged) return;
      if (picker.query.trim() == picker.collectionQuery) {
        // Back to what is listed: anything asked since is stale.
        setState(() {
          picker.generation++;
          picker.collectionsLoading = false;
        });
        return;
      }
      unawaited(_loadCollections(picker, more: false));
    }

    if (immediate) {
      run();
    } else {
      _searchTimer = Timer(_searchDelay, run);
    }
  }

  void _closePicker() {
    _searchTimer?.cancel();
    _search.clear();
    setState(() => _picker = null);
  }

  void _applyPicker() {
    final picker = _picker;
    if (picker == null) return;
    _searchTimer?.cancel();
    _edit(() {
      if (picker.kind == _PickerKind.models) {
        _models = [..._models, ...picker.selected];
      } else {
        _files = [
          ..._files,
          for (final id in picker.selected)
            if (picker.known[id] case final option?)
              FolderProjectFile.reference(
                type: option.type,
                id: id,
                name: option.label,
              ).raw,
        ];
      }
      _picker = null;
    });
    _search.clear();
  }

  // ---- build ----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final editsPrompt =
        ref
            .watch(openWebUiChatSettingsAccessProvider)
            .asData
            ?.value
            .canEditSystemPrompt ??
        false;
    final picker = _picker;
    final dirty =
        _filesChanged || _modelsChanged || _promptChanged(editsPrompt);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).maybePop(),
            child: const SizedBox.shrink(),
          ),
        ),
        // ThemedSheets.showCustom adds no view inset, so the sheet lifts itself
        // above the software keyboard and the form scrolls in what is left.
        // The system strips the home-indicator inset while the keyboard is up,
        // so the safe area below does not pad twice.
        AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.8,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            builder: (context, scrollController) {
              return Container(
                decoration: BoxDecoration(
                  color: theme.surfaceBackground,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(AppBorderRadius.bottomSheet),
                  ),
                  border: Border.all(
                    color: theme.dividerColor,
                    width: BorderWidth.regular,
                  ),
                  boxShadow: ConduitShadows.modal(context),
                ),
                // The native iOS 26 sheet route supplies Flutter's own
                // Material, which material_ui's icon buttons, checkboxes and
                // list tiles do not see. This one sits inside the decorated
                // surface so their ink stays above it.
                child: Material(
                  type: MaterialType.transparency,
                  child: ModalSheetSafeArea(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Spacing.modalPadding,
                      vertical: Spacing.modalPadding,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SheetHandle(),
                        Text(
                          l10n.folderProjectSettings,
                          style: theme.headingSmall?.copyWith(
                            color: theme.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: Spacing.xs),
                        Text(
                          l10n.folderProjectSettingsDescription,
                          style: theme.bodySmall?.copyWith(
                            color: theme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: Spacing.md),
                        Expanded(
                          child: picker == null
                              ? _buildForm(
                                  l10n,
                                  theme,
                                  scrollController,
                                  editsPrompt,
                                )
                              : _buildPicker(
                                  l10n,
                                  theme,
                                  scrollController,
                                  picker,
                                ),
                        ),
                        if (_failure != null) ...[
                          const SizedBox(height: Spacing.sm),
                          Text(
                            _failure!,
                            key: const ValueKey('folder-project-failure'),
                            style: theme.bodySmall?.copyWith(
                              color: theme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: Spacing.md),
                        if (picker == null)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              ConduitButton(
                                key: const ValueKey('folder-project-cancel'),
                                text: l10n.cancel,
                                isSecondary: true,
                                isCompact: true,
                                onPressed: _saving
                                    ? null
                                    : () => Navigator.of(context).pop(),
                              ),
                              const SizedBox(width: Spacing.sm),
                              ConduitButton(
                                key: const ValueKey('folder-project-save'),
                                text: l10n.save,
                                isCompact: true,
                                isLoading: _saving,
                                onPressed: dirty && !_saving
                                    ? () => _save(l10n, editsPrompt)
                                    : null,
                              ),
                            ],
                          )
                        else
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              ConduitButton(
                                key: const ValueKey(
                                  'folder-project-picker-cancel',
                                ),
                                text: l10n.cancel,
                                isSecondary: true,
                                isCompact: true,
                                onPressed: _closePicker,
                              ),
                              const SizedBox(width: Spacing.sm),
                              ConduitButton(
                                key: const ValueKey(
                                  'folder-project-picker-add',
                                ),
                                text: l10n.folderProjectAddSelected,
                                isCompact: true,
                                onPressed: picker.selected.isEmpty
                                    ? null
                                    : _applyPicker,
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildForm(
    AppLocalizations l10n,
    ConduitThemeExtension theme,
    ScrollController controller,
    bool editsPrompt,
  ) {
    final offered = ref.watch(modelsProvider).asData?.value;
    final available = offered == null
        ? null
        : {
            for (final model in folderDefaultModelCandidates(offered))
              model.id: model,
          };
    // Workspace's list vouches for a saved collection only when it is the
    // whole list: a page of it, or a searched or filtered one, leaves out
    // collections that exist.
    final knowledge = ref.watch(workspaceKnowledgeProvider).asData?.value;
    final knownCollections =
        knowledge == null ||
            knowledge.hasMore ||
            knowledge.query.trim().isNotEmpty ||
            knowledge.source.isNotEmpty ||
            (knowledge.view.isNotEmpty && knowledge.view != 'all')
        ? null
        : {for (final item in knowledge.items) item.id};

    String kindLabel(String type) => switch (type) {
      'collection' => l10n.folderProjectKindCollection,
      'note' => l10n.folderProjectKindNote,
      _ => l10n.folderProjectKindFile,
    };

    return ListView(
      key: const ValueKey('folder-project-form'),
      controller: controller,
      padding: EdgeInsets.zero,
      children: [
        if (editsPrompt) ...[
          _sectionTitle(l10n.systemPrompt, theme),
          ConduitInput(
            key: const ValueKey('folder-project-system-prompt'),
            controller: _prompt,
            enabled: !_saving,
            minLines: 3,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            hint: l10n.enterSystemPrompt,
            onChanged: (_) => _edit(() {}),
          ),
          const SizedBox(height: Spacing.lg),
        ],
        _sectionTitle(l10n.workspaceModelKnowledge, theme),
        if (_files.isEmpty)
          _hint(l10n.folderProjectNoKnowledge, theme)
        else
          for (final (index, entry) in _files.indexed)
            Builder(
              builder: (context) {
                final file = FolderProjectFile.tryParse(entry);
                final missing =
                    file == null ||
                    (file.type == 'collection' &&
                        knownCollections != null &&
                        !knownCollections.contains(file.id)) ||
                    (file.type == 'file' && _missingFiles.contains(file.id));
                return _row(
                  theme,
                  l10n,
                  keyId: 'folder-project-knowledge-$index',
                  title: file?.name ?? '$entry',
                  subtitle: file == null ? null : kindLabel(file.type),
                  unavailable: missing,
                  onRemove: () => _edit(() => _files.removeAt(index)),
                );
              },
            ),
        _addButton(
          'folder-project-add-knowledge',
          l10n.folderProjectAddKnowledge,
          () => _openPicker(_PickerKind.knowledge),
        ),
        const SizedBox(height: Spacing.lg),
        _sectionTitle(l10n.folderProjectModels, theme),
        _hint(l10n.folderProjectModelsHint, theme),
        const SizedBox(height: Spacing.xs),
        if (_models.isEmpty)
          _hint(l10n.folderProjectNoModels, theme)
        else
          for (final (index, entry) in _models.indexed)
            _row(
              theme,
              l10n,
              keyId: 'folder-project-model-$index',
              title: entry is String && available?[entry] != null
                  ? available![entry]!.name
                  : '$entry',
              subtitle: entry is String && available?[entry] != null
                  ? entry
                  : null,
              unavailable:
                  entry is! String ||
                  (available != null && available[entry] == null),
              onUp: index == 0
                  ? null
                  : () => _edit(() {
                      final moved = _models.removeAt(index);
                      _models.insert(index - 1, moved);
                    }),
              onRemove: () => _edit(() => _models.removeAt(index)),
            ),
        _addButton(
          'folder-project-add-model',
          l10n.folderProjectAddModel,
          () => _openPicker(_PickerKind.models),
        ),
      ],
    );
  }

  Widget _buildPicker(
    AppLocalizations l10n,
    ConduitThemeExtension theme,
    ScrollController controller,
    _Picker picker,
  ) {
    final query = picker.query.trim();
    final needle = query.toLowerCase();
    bool matches(_Option option) =>
        needle.isEmpty ||
        option.label.toLowerCase().contains(needle) ||
        option.id.toLowerCase().contains(needle);
    // Knowledge for the text in the field is asked of the server; until that
    // answer arrives, the list for the previous text is narrowed here.
    final answered = picker.collectionQuery == query;
    final visible = [
      for (final option in picker.collections)
        if (!picker.taken.contains(option.id) && (answered || matches(option)))
          option,
      for (final option in picker.fixed ?? const <_Option>[])
        if (!picker.taken.contains(option.id) && matches(option)) option,
    ];
    final loading = picker.collectionsLoading || picker.fixedLoading;
    final knowledgePicker = picker.kind == _PickerKind.knowledge;
    // What follows the options says what is still unknown: a request in
    // flight, a failure to retry, or more pages to ask for. An empty list with
    // none of these is the only time nothing is left to add.
    final footer = <Widget>[
      if (loading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: Spacing.md),
          child: Center(
            child: CircularProgressIndicator(
              key: ValueKey('folder-project-picker-loading'),
            ),
          ),
        ),
      if (!loading && picker.failed)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _hint(l10n.workspaceLoadFailed, theme),
            if (knowledgePicker && !picker.ownerChanged)
              _footerButton(
                'folder-project-picker-retry',
                l10n.workspaceRetry,
                () => _retryPicker(picker),
              ),
          ],
        ),
      if (!loading && !picker.collectionsFailed && picker.collectionsMore)
        _footerButton(
          'folder-project-picker-more',
          l10n.workspaceLoadMore,
          () => _loadCollections(picker, more: true),
        ),
    ];
    String kindLabel(String type) => switch (type) {
      'collection' => l10n.folderProjectKindCollection,
      'file' => l10n.folderProjectKindFile,
      _ => '',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConduitGlassSearchField(
          controller: _search,
          hintText: l10n.workspaceSearchHint,
          query: picker.query,
          onChanged: (value) {
            setState(() => picker.query = value);
            if (knowledgePicker) _searchCollections(picker, immediate: false);
          },
          onClear: () {
            _search.clear();
            setState(() => picker.query = '');
            if (knowledgePicker) _searchCollections(picker, immediate: true);
          },
        ),
        const SizedBox(height: Spacing.sm),
        Expanded(
          child: visible.isEmpty && footer.isEmpty
              ? _hint(l10n.folderProjectNothingToAdd, theme)
              : ListView.builder(
                  key: const ValueKey('folder-project-picker-list'),
                  controller: controller,
                  itemCount: visible.length + footer.length,
                  itemBuilder: (context, index) {
                    if (index >= visible.length) {
                      return footer[index - visible.length];
                    }
                    final option = visible[index];
                    final subtitle = kindLabel(option.type);
                    return CheckboxListTile(
                      key: ValueKey('folder-project-option-${option.id}'),
                      value: picker.selected.contains(option.id),
                      contentPadding: EdgeInsets.zero,
                      title: MiddleEllipsisText(option.label),
                      subtitle: subtitle.isEmpty ? null : Text(subtitle),
                      onChanged: (value) {
                        ConduitHaptics.selectionClick();
                        setState(() {
                          if (value == true) {
                            picker.selected.add(option.id);
                          } else {
                            picker.selected.remove(option.id);
                          }
                        });
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String text, ConduitThemeExtension theme) => Padding(
    padding: const EdgeInsets.only(bottom: Spacing.sm),
    child: Text(
      text,
      style: theme.bodyMedium?.copyWith(
        color: theme.textPrimary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _hint(String text, ConduitThemeExtension theme) => Padding(
    padding: const EdgeInsets.only(bottom: Spacing.sm),
    child: Text(
      text,
      style: theme.bodySmall?.copyWith(color: theme.textSecondary),
    ),
  );

  Widget _addButton(String key, String text, VoidCallback onPressed) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: ConduitButton(
      key: ValueKey(key),
      text: text,
      isSecondary: true,
      isCompact: true,
      onPressed: _saving ? null : onPressed,
    ),
  );

  Widget _footerButton(String key, String text, VoidCallback onPressed) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: ConduitButton(
            key: ValueKey(key),
            text: text,
            isSecondary: true,
            isCompact: true,
            onPressed: onPressed,
          ),
        ),
      );

  Widget _row(
    ConduitThemeExtension theme,
    AppLocalizations l10n, {
    required String keyId,
    required String title,
    String? subtitle,
    required bool unavailable,
    VoidCallback? onUp,
    required VoidCallback onRemove,
  }) {
    return Padding(
      key: ValueKey(keyId),
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MiddleEllipsisText(title),
                if (unavailable)
                  Text(
                    l10n.folderProjectNotAvailable,
                    key: ValueKey('$keyId-unavailable'),
                    style: theme.bodySmall?.copyWith(color: theme.error),
                  )
                else if (subtitle != null)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.bodySmall?.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          if (onUp != null)
            IconButton(
              key: ValueKey('$keyId-up'),
              tooltip: l10n.folderProjectMoveUp(title),
              icon: const Icon(Icons.arrow_upward),
              onPressed: _saving ? null : onUp,
            ),
          IconButton(
            key: ValueKey('$keyId-remove'),
            tooltip: l10n.folderProjectRemove(title),
            icon: const Icon(Icons.close),
            onPressed: _saving ? null : onRemove,
          ),
        ],
      ),
    );
  }
}
