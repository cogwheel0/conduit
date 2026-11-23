import 'dart:async';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart'
    show currentUserProvider2;
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        folderDefaultModelCandidates,
        openWebUiChatSettingsAccessProvider,
        resolveFolderDefaultModels;
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/folder_icons.dart';
import 'package:conduit_core/models/model.dart' as core;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'settled.dart';

/// How many saved files are asked about at once.
const _fileChecks = 4;

/// Implements `folders.get`, `folders.update` and `folders.draftModel`: a
/// folder's settings, as mobile's folder page and project settings edit
/// them.
///
/// The name and icon go to the server at once (mobile's Edit Folder does
/// the same); the project defaults (system prompt, models, knowledge) go
/// through the core's [Folders.saveProjectDefaults], local and durable
/// first, then pushed. The server applies a folder's system prompt and
/// knowledge to every chat in it; the models are the client's, and
/// [resolveFolderDefaultModels] picks the one a new chat starts on.
final class FolderSettingsService {
  FolderSettingsService(this._container, {EventBus? events}) : _events = events;

  final ProviderContainer _container;
  final EventBus? _events;

  Future<FolderSettings> get(String folderId) async {
    final notifier = _container.read(foldersProvider.notifier);
    final owner = _owner();
    final listed = await _listed(folderId);
    var folder = listed;
    try {
      // The server's project data, kept on the stored row, which also holds
      // this device's edits not sent yet: the list carries no project data.
      final detail = await notifier.refreshProjectData(owner, folderId);
      if (detail != null) {
        folder = detail.copyWith(
          shared: listed.shared,
          ownerName: listed.ownerName,
          permission: listed.permission,
        );
      }
    } on FolderProjectWriteException catch (error) {
      throw _failure(error.reason);
    } on Object catch (error) {
      // Offline or refused: this device's copy stands.
      DebugLogger.warning(
        'folder-detail-unread',
        scope: 'daemon/folders',
        data: <String, Object?>{'error': error.runtimeType.toString()},
      );
    }
    final settings = await _settings(
      folder,
      missing: await _missingFiles(owner, folder),
    );
    // Put together for the account that asked: once another is in use, its
    // prompt and knowledge are not shown to it.
    if (!notifier.isCurrentProjectOwner(owner)) {
      throw _failure(FolderProjectWriteFailure.ownerChanged);
    }
    return settings;
  }

  Future<FolderSettings> update(FolderUpdate request) async {
    final notifier = _container.read(foldersProvider.notifier);
    // The account the edit is for, before any await: the name and icon go
    // out through its client, and only while it is still the one in use.
    final owner = _owner();
    final api = _container.read(apiServiceProvider);
    void ensureOwner() {
      if (!notifier.isCurrentProjectOwner(owner) ||
          !identical(api, _container.read(apiServiceProvider))) {
        throw _failure(FolderProjectWriteFailure.ownerChanged);
      }
    }

    final folder = await _listed(request.id);
    // A prompt sent as the folder has it is no change: it is not written,
    // so a newer one another writer saved stands, and it asks no right.
    final prompt = request.systemPrompt?.trim();
    final promptChanged =
        prompt != null && prompt != folder.projectSystemPrompt.trim();
    if (promptChanged) {
      // As a chat's own prompt: the account's right to edit system prompts.
      await _requirePromptAccess();
    }
    final name = request.name?.trim();
    final icon = request.icon == null
        ? null
        : normalizeFolderIconAlias(request.icon) ?? '';
    if ((name != null && name != folder.name) ||
        (icon != null && icon != (_icon(folder) ?? ''))) {
      if (folder.shared) {
        throw const RpcError(
          code: ConduitErrorCodes.unsupported,
          debugMessage: "only a folder's owner may rename it",
        );
      }
      if (name != null && name.isEmpty) {
        throw const RpcError(
          code: ConduitErrorCodes.invalidParams,
          debugMessage: 'a folder name must not be empty',
        );
      }
      if (name != null) await _refuseTakenName(folder, name);
      final meta = <String, dynamic>{...?folder.meta, 'icon': ?icon};
      if (api == null) {
        throw const RpcError(
          code: ConduitErrorCodes.unauthenticated,
          debugMessage: 'no Open WebUI account is signed in',
        );
      }
      ensureOwner();
      // An icon-only change sends no name: one read before a rename still
      // on its way would put the old name back on the server.
      await api.updateFolder(
        folder.id,
        name: name,
        meta: icon == null ? null : meta,
      );
      // Answered after a switch: the next account's folders keep theirs.
      ensureOwner();
      notifier.updateFolderFromRemote(
        folder.id,
        (current) => current.copyWith(
          name: name ?? current.name,
          meta: icon == null ? current.meta : meta,
          updatedAt: DateTime.now(),
        ),
      );
    }
    final edits =
        promptChanged ||
        request.modelIds != null ||
        request.knowledge != null;
    if (edits) {
      if (!folder.canWrite) {
        throw _failure(FolderProjectWriteFailure.readOnly);
      }
      try {
        await notifier.saveProjectDefaults(
          owner,
          folder.id,
          files: request.knowledge == null
              ? null
              : _files(folder, request.knowledge!),
          modelIds: request.modelIds == null
              ? null
              : <Object?>[
                  for (final id in request.modelIds!)
                    if (id.trim().isNotEmpty) id,
                ],
          systemPrompt: promptChanged ? prompt : null,
        );
      } on FolderProjectWriteException catch (error) {
        throw _failure(error.reason);
      }
      // Pushed now, so the next chat in the folder already gets it; a
      // failure leaves it queued for the next drain.
      try {
        await _container.read(syncEngineProvider.notifier).drainNow();
      } on Object {
        // Queued.
      }
    }
    refreshConversationsCache(_container, includeFolders: true);
    _events?.emit(ConduitEventSpecs.chatsChanged, const ChatsChanged());
    return get(folder.id);
  }

  /// What a new chat in the folder starts on: the core's own resolution, so
  /// the window shows the model the first turn will run on.
  Future<FolderDraftModel> draftModel(String folderId) async {
    final resolved = await resolveFolderDefaultModels(_container, folderId);
    return FolderDraftModel(
      folderId: folderId,
      modelIds: <String>[for (final model in resolved.usable) model.id],
      missing: resolved.missing,
    );
  }

  /// The project's `files`, as the window lists them: each saved entry kept
  /// exactly as stored (keys this client does not know survive), new ones as
  /// references, and entries the window cannot show carried along.
  static List<Object?> _files(
    Folder folder,
    List<FolderKnowledgeItem> knowledge,
  ) {
    final stored = folder.projectFileEntries;
    final byKey = <String, Object?>{
      for (final entry in stored)
        if (FolderProjectFile.tryParse(entry) case final file?)
          '${file.type}:${file.id}': entry,
    };
    return <Object?>[
      for (final item in knowledge)
        byKey['${item.type}:${item.id}'] ??
            FolderProjectFile.reference(
              type: item.type,
              id: item.id,
              name: item.name,
            ).raw,
      for (final entry in stored)
        if (FolderProjectFile.tryParse(entry) == null) entry,
    ];
  }

  Future<Set<String>> _missingFiles(
    FolderProjectOwner owner,
    Folder folder,
  ) async {
    final notifier = _container.read(foldersProvider.notifier);
    final ids = <String>[
      for (final file in folder.projectFiles)
        if (file.type == 'file') file.id,
    ];
    final missing = <String>{};
    for (var i = 0; i < ids.length; i += _fileChecks) {
      final answers = await Future.wait([
        for (final id in ids.skip(i).take(_fileChecks))
          notifier
              .projectFileExists(owner, id)
              .then(
                (exists) => (id, exists),
                onError: (Object _) => (id, null),
              ),
      ]);
      for (final (id, exists) in answers) {
        if (exists == false) missing.add(id);
      }
    }
    return missing;
  }

  Future<FolderSettings> _settings(
    Folder folder, {
    Set<String> missing = const <String>{},
  }) async {
    var canEditPrompt = false;
    try {
      final access = await readSettled(
        _container,
        openWebUiChatSettingsAccessProvider.future,
      );
      canEditPrompt = access.canEditSystemPrompt;
    } on Object {
      canEditPrompt = false;
    }
    var canShare = false;
    // As mobile's folder page: a shared folder's access is its owner's to
    // change, or an admin's.
    if (!folder.shared ||
        _container.read(currentUserProvider2)?.role == 'admin') {
      try {
        final caps = await readSettled(
          _container,
          workspaceCapabilitiesProvider.future,
        );
        canShare = caps.folders.section.share;
      } on Object {
        canShare = false;
      }
    }
    var models = const <core.Model>[];
    try {
      models = await readSettled(_container, modelsProvider.future);
    } on Object {
      models = _container.read(modelsProvider).value ?? const <core.Model>[];
    }
    return FolderSettings(
      id: folder.id,
      name: folder.name,
      icon: _icon(folder),
      systemPrompt: folder.projectSystemPrompt,
      modelIds: folder.projectModelIds,
      knowledge: <FolderKnowledgeItem>[
        for (final file in folder.projectFiles)
          FolderKnowledgeItem(
            type: file.type,
            id: file.id,
            name: file.name,
            missing: missing.contains(file.id),
          ),
      ],
      shared: folder.shared,
      ownerName: folder.shared ? folder.ownerName : null,
      canRename: !folder.shared,
      canWrite: folder.canWrite,
      canEditSystemPrompt: folder.canWrite && canEditPrompt,
      canShare: canShare,
      iconChoices: <FolderIconChoice>[
        // An icon chosen on the web stays the folder's choice.
        if (customFolderIconAlias(folder.meta?['icon']?.toString())
            case final custom?)
          FolderIconChoice(alias: custom, emoji: folderIconEmoji(custom)!),
        for (final option in folderIconOptions)
          FolderIconChoice(alias: option.alias, emoji: option.emoji),
      ],
      modelChoices: <FolderModelChoice>[
        for (final model in folderDefaultModelCandidates(models))
          FolderModelChoice(id: model.id, name: model.name),
      ],
    );
  }

  static String? _icon(Folder folder) =>
      normalizeFolderIconAlias(folder.meta?['icon']?.toString());

  Future<Folder> _listed(String folderId) async {
    final folders = await readSettled(_container, foldersProvider.future);
    final folder = folders.where((f) => f.id == folderId).firstOrNull;
    if (folder == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'id': folderId},
        debugMessage: 'no folder $folderId',
      );
    }
    return folder;
  }

  /// Open WebUI keeps one folder of a name (in any case) per parent.
  Future<void> _refuseTakenName(Folder folder, String name) async {
    final folders = await readSettled(_container, foldersProvider.future);
    final lower = name.toLowerCase();
    final taken = folders.any(
      (f) =>
          f.id != folder.id &&
          !f.shared &&
          f.parentId == folder.parentId &&
          f.name.toLowerCase() == lower,
    );
    if (taken) {
      throw RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'a folder named "$name" is already there',
      );
    }
  }

  Future<void> _requirePromptAccess() async {
    var allowed = false;
    try {
      final access = await readSettled(
        _container,
        openWebUiChatSettingsAccessProvider.future,
      );
      allowed = access.canEditSystemPrompt;
    } on Object {
      allowed = false;
    }
    if (!allowed) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthorized,
        args: <String, String>{'reason': 'permissionDenied'},
        debugMessage: 'this account may not change system prompts',
      );
    }
  }

  FolderProjectOwner _owner() {
    final owner = _container
        .read(foldersProvider.notifier)
        .captureProjectOwner();
    if (owner == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'no Open WebUI account is signed in',
      );
    }
    return owner;
  }

  static RpcError _failure(FolderProjectWriteFailure reason) => RpcError(
    code: switch (reason) {
      FolderProjectWriteFailure.ownerChanged => ConduitErrorCodes.conflict,
      FolderProjectWriteFailure.unavailable => ConduitErrorCodes.notFound,
      FolderProjectWriteFailure.readOnly => ConduitErrorCodes.unsupported,
    },
    args: <String, String>{'reason': reason.name},
    debugMessage: 'folder settings: ${reason.name}',
  );
}
