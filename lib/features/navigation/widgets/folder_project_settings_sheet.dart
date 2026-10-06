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
  _Picker(this.kind);

  final _PickerKind kind;
  List<_Option>? options;
  bool failed = false;
  String query = '';
  final List<String> selected = <String>[];
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

  Future<void> _openPicker(_PickerKind kind) async {
    final picker = _Picker(kind);
    _search.clear();
    setState(() {
      _failure = null;
      _picker = picker;
    });
    // What the folder already has is not offered again.
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
    final options = <_Option>[];
    var loaded = false;
    try {
      if (kind == _PickerKind.models) {
        final models = await ref.read(modelsProvider.future);
        for (final model in folderDefaultModelCandidates(models)) {
          options.add(_Option(model.id, model.name, 'model'));
        }
        loaded = true;
      } else {
        try {
          final knowledge = await ref.read(workspaceKnowledgeProvider.future);
          for (final item in knowledge.items) {
            options.add(_Option(item.id, item.name, 'collection'));
          }
          loaded = true;
        } catch (_) {}
        try {
          final files = await ref.read(userFilesProvider.future);
          for (final file in files) {
            options.add(_Option(file.id, file.displayName, 'file'));
          }
          loaded = true;
        } catch (_) {}
      }
    } catch (_) {}
    if (!mounted || !identical(_picker, picker)) return;
    setState(() {
      picker.failed = !loaded;
      picker.options = [
        for (final option in options)
          if (!taken.contains(option.id)) option,
      ];
    });
  }

  void _closePicker() {
    _search.clear();
    setState(() => _picker = null);
  }

  void _applyPicker() {
    final picker = _picker;
    if (picker == null) return;
    final byId = {
      for (final option in picker.options ?? const <_Option>[])
        option.id: option,
    };
    _edit(() {
      if (picker.kind == _PickerKind.models) {
        _models = [..._models, ...picker.selected];
      } else {
        _files = [
          ..._files,
          for (final id in picker.selected)
            if (byId[id] case final option?)
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
    final knowledge = ref.watch(workspaceKnowledgeProvider).asData?.value;
    final knownCollections = knowledge == null || knowledge.hasMore
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
    final options = picker.options;
    final query = picker.query.trim().toLowerCase();
    final visible = [
      for (final option in options ?? const <_Option>[])
        if (query.isEmpty ||
            option.label.toLowerCase().contains(query) ||
            option.id.toLowerCase().contains(query))
          option,
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
          onChanged: (value) => setState(() => picker.query = value),
          onClear: () {
            _search.clear();
            setState(() => picker.query = '');
          },
        ),
        const SizedBox(height: Spacing.sm),
        Expanded(
          child: options == null
              ? const Center(child: CircularProgressIndicator())
              : picker.failed
              ? _hint(l10n.workspaceLoadFailed, theme)
              : visible.isEmpty
              ? _hint(l10n.folderProjectNothingToAdd, theme)
              : ListView.builder(
                  key: const ValueKey('folder-project-picker-list'),
                  controller: controller,
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
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
