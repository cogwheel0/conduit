import 'dart:async';

import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        OpenWebUiChatSettingsException,
        OpenWebUiChatSettingsFailure,
        OpenWebUiChatSettingsMenuEntry,
        openWebUiChatSettingsAccessProvider,
        openWebUiChatSettingsMenuEntryFor,
        recordChatSettingsReasoningPick,
        saveOpenWebUiChatSettings;
import 'package:conduit_core/features/chat/providers/reasoning_effort_provider.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart' as core;
import 'package:conduit_core/models/openwebui_chat_settings.dart';
import 'package:conduit_core/models/openwebui_chat_settings_form.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart'
    show appSettingsProvider;
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'models_service.dart' show currentModel;
import 'settled.dart';

/// The container a chat with a live turn scope runs in, else null.
typedef ChatScopeLookup = ProviderContainer? Function(String chatId);

/// Implements `chatSettings.*` and `chats.setSystemPrompt`: a chat's own
/// system prompt and parameters (Open WebUI's `chat.params`), as mobile's
/// Chat Settings sheet edits them.
///
/// The form is the core's [ChatSettingsForm], built afresh from what is
/// saved on every call, with the window's fields applied: the window only
/// draws what this answers, and every rule (what may be edited, how a value
/// parses, what a save writes) is the core's. A new chat's settings are not
/// kept here: the window holds them (the `params` of the last answer) and
/// sends them with its first message, so two windows' new chats never share
/// a draft.
final class ChatSettingsService {
  ChatSettingsService(this._container, {ChatScopeLookup? scopeOf})
    : _scopeOf = scopeOf;

  final ProviderContainer _container;
  final ChatScopeLookup? _scopeOf;

  Future<ChatSettingsState> get(ChatSettingsQuery query) async {
    final open = await _open(query.chatId, query.modelId, query.draft);
    return _state(open, open.form());
  }

  /// The form with [edit] applied, its errors marked. Writes nothing.
  Future<ChatSettingsState> check(ChatSettingsEdit edit) async {
    final open = await _open(edit.chatId, edit.modelId, edit.draft);
    final form = open.form();
    _apply(form, edit.fields);
    return _state(open, form);
  }

  /// Saves [edit]: only what changed is written, as the core's patch. A
  /// form with errors writes nothing and answers with them marked.
  Future<ChatSettingsState> save(ChatSettingsEdit edit) async {
    final open = await _open(edit.chatId, edit.modelId, edit.draft);
    final form = open.form();
    _apply(form, edit.fields);
    if (form.hasErrors) return _state(open, form);
    final patch = form.toPatch();
    if (patch.isEmpty) return _state(open, form, saved: true);
    final model = open.model;
    // Read before the save awaits: the key names the model on the server
    // the form was opened on.
    final pickKey = model == null
        ? null
        : localReasoningEffortKeyForModel(open.ref.read, model);
    final Map<String, dynamic> saved;
    if (open.conversation == null) {
      _requireAccess(open.access, patch);
      saved = <String, dynamic>{...open.saved, ...patch.set};
      for (final key in patch.remove) {
        saved.remove(key);
      }
    } else {
      saved = await _write(open, set: patch.set, remove: patch.remove);
    }
    await recordChatSettingsReasoningPick(
      open.ref.read,
      model: model,
      patch: patch,
      pickKey: pickKey,
    );
    final fresh = open.withSaved(saved);
    return _state(fresh, fresh.form(), saved: true);
  }

  /// `chats.setSystemPrompt`: the chat's own prompt (`params.system`), or
  /// with an empty [prompt] the user's default again.
  ///
  /// Returns whether the legacy `chat.system` was cleared on the server too:
  /// left there, it would be the chat's prompt again once `params.system`
  /// is gone.
  Future<bool> setSystemPrompt(String chatId, String prompt) async {
    final session = _container.read(openWebUiAuthSessionEpochProvider);
    final api = _container.read(apiServiceProvider);
    final open = await _open(chatId, null, const <String, dynamic>{});
    final trimmed = prompt.trim();
    await _write(
      open,
      set: trimmed.isEmpty
          ? const <String, dynamic>{}
          : <String, dynamic>{kChatParamSystem: trimmed},
      remove: trimmed.isEmpty ? const <String>[kChatParamSystem] : const [],
    );
    final legacy = open.conversation?.systemPrompt?.trim() ?? '';
    if (trimmed.isNotEmpty || legacy.isEmpty || api == null) return false;
    // Written by the account that read the chat, or not at all.
    if (!identical(api, _container.read(apiServiceProvider)) ||
        !identical(
          session,
          _container.read(openWebUiAuthSessionEpochProvider),
        )) {
      return false;
    }
    await api.updateConversation(chatId, systemPrompt: '');
    return true;
  }

  Future<Map<String, dynamic>> _write(
    _Open open, {
    required Map<String, dynamic> set,
    required List<String> remove,
  }) async {
    try {
      return await saveOpenWebUiChatSettings(
        open.ref,
        conversation: open.conversation,
        set: set,
        remove: remove,
      );
    } on OpenWebUiChatSettingsException catch (error) {
      throw _failure(error.reason);
    }
  }

  static void _requireAccess(
    OpenWebUiChatSettingsAccess access,
    ChatParamsPatch patch,
  ) {
    for (final key in <String>{...patch.set.keys, ...patch.remove}) {
      final allowed = key == kChatParamSystem
          ? access.canEditSystemPrompt
          : access.canEditParameters;
      if (!allowed) {
        throw _failure(OpenWebUiChatSettingsFailure.permissionDenied);
      }
    }
  }

  static RpcError _failure(OpenWebUiChatSettingsFailure reason) => RpcError(
    code: switch (reason) {
      OpenWebUiChatSettingsFailure.permissionDenied =>
        ConduitErrorCodes.unauthorized,
      OpenWebUiChatSettingsFailure.unavailable => ConduitErrorCodes.notFound,
      OpenWebUiChatSettingsFailure.ownerChanged => ConduitErrorCodes.conflict,
      OpenWebUiChatSettingsFailure.notEditable => ConduitErrorCodes.unsupported,
    },
    args: <String, String>{'reason': reason.name},
    debugMessage: 'chat settings not saved: ${reason.name}',
  );

  /// What the form is built from: the chat (or a new chat's draft), its
  /// model, the account's rights and what is saved.
  Future<_Open> _open(
    String? chatId,
    String? modelId,
    Map<String, dynamic> draft,
  ) async {
    // Read for the account in use now: once another one is, nothing read
    // is shown to it, and no write starts from it.
    final session = _container.read(openWebUiAuthSessionEpochProvider);
    void sameAccount() {
      if (!identical(
        session,
        _container.read(openWebUiAuthSessionEpochProvider),
      )) {
        throw const RpcError(
          code: ConduitErrorCodes.sessionExpired,
          debugMessage: 'the account changed',
        );
      }
    }

    final scope = chatId == null ? null : _scopeOf?.call(chatId);
    final ref = scope ?? _container;
    Conversation? conversation;
    Map<String, dynamic> saved;
    if (chatId == null) {
      saved = openWebUiChatParamsFrom(draft);
    } else {
      conversation = await _conversation(chatId, scope);
      sameAccount();
      if (conversation == null) {
        throw RpcError(
          code: ConduitErrorCodes.notFound,
          args: <String, String>{'id': chatId},
          debugMessage: 'no chat $chatId',
        );
      }
      Map<String, dynamic>? stored;
      try {
        stored = await _container
            .read(appDatabaseProvider)
            ?.chatsDao
            .getChatParams(chatId);
      } on Object {
        // An unreadable row falls back to the copy in memory.
      }
      sameAccount();
      saved = stored ?? conversation.chatParams;
    }
    final model = await _model(modelId);
    sameAccount();
    OpenWebUiChatSettingsAccess access;
    try {
      access = await readSettled(
        _container,
        openWebUiChatSettingsAccessProvider.future,
      );
    } on Object {
      access = OpenWebUiChatSettingsAccess.denied;
    }
    sameAccount();
    return _Open(
      ref: ref,
      read: _container.read,
      conversation: conversation,
      model: model,
      access: access,
      saved: saved,
    );
  }

  Future<Conversation?> _conversation(
    String chatId,
    ProviderContainer? scope,
  ) async {
    final active = scope?.read(activeConversationProvider);
    if (active != null && active.id == chatId) return active;
    try {
      return await readSettled(
        _container,
        loadConversationProvider(chatId).future,
      );
    } on Object catch (error) {
      DebugLogger.warning(
        'chat-settings-chat-unread',
        scope: 'daemon/chat-settings',
        data: <String, Object?>{'error': error.runtimeType.toString()},
      );
      return null;
    }
  }

  Future<core.Model?> _model(String? modelId) async {
    if (modelId == null) return currentModel(_container);
    try {
      final models = await readSettled(_container, modelsProvider.future);
      return models.where((m) => m.id == modelId).firstOrNull ??
          await currentModel(_container);
    } on Object {
      return _container
          .read(modelsProvider)
          .value
          ?.where((m) => m.id == modelId)
          .firstOrNull;
    }
  }

  static void _apply(ChatSettingsForm form, List<ChatSettingFieldEdit> edits) {
    final offered = <String>{kChatParamSystem, ...form.parameterKeys};
    for (final edit in edits) {
      if (!offered.contains(edit.key)) continue;
      switch (edit.mode) {
        case ChatSettingMode.custom:
          form.setText(edit.key, edit.text);
        case ChatSettingMode.inherit:
          form.setMode(edit.key, ChatParamMode.inherit);
        case ChatSettingMode.modelDefault:
          form.setMode(edit.key, ChatParamMode.modelDefault);
      }
    }
  }

  ChatSettingsState _state(
    _Open open,
    ChatSettingsForm form, {
    bool saved = false,
  }) {
    final read = open.read;
    final entry = openWebUiChatSettingsMenuEntryFor(
      read,
      model: open.model,
      conversation: open.conversation,
      draftParams: open.conversation == null
          ? open.saved
          : const <String, dynamic>{},
    );
    final keys = form.parameterKeys;
    final otherKept = open.saved.keys.any(
      (key) =>
          key != kChatParamSystem &&
          !keys.contains(key) &&
          chatParamSpecFor(key) == null,
    );
    return ChatSettingsState(
      chatId: open.conversation?.id,
      entry: switch (entry) {
        OpenWebUiChatSettingsMenuEntry.none => ChatSettingsEntry.none,
        OpenWebUiChatSettingsMenuEntry.editor => ChatSettingsEntry.editor,
        OpenWebUiChatSettingsMenuEntry.applied => ChatSettingsEntry.applied,
      },
      advanced: read(appSettingsProvider).advancedFeaturesEnabled,
      canEditSystemPrompt: open.access.canEditSystemPrompt,
      canEditParameters: open.access.canEditParameters,
      systemPrompt: _field(form, kChatParamSystem, open),
      parameters: <ChatSettingField>[
        for (final key in keys) _field(form, key, open),
      ],
      otherKept: otherKept,
      applied: <ChatSettingApplied>[
        if (open.saved.containsKey(kChatParamSystem))
          ChatSettingApplied(
            key: kChatParamSystem,
            value: '${open.saved[kChatParamSystem]}',
          ),
        for (final entry in open.saved.entries)
          if (entry.key != kChatParamSystem)
            ChatSettingApplied(
              key: entry.key,
              value: entry.value == null
                  ? null
                  : chatParamToText(chatParamSpecFor(entry.key), entry.value),
            ),
      ],
      params: open.saved,
      dirty: form.isDirty,
      hasErrors: form.hasErrors,
      saved: saved,
    );
  }

  static ChatSettingField _field(
    ChatSettingsForm form,
    String key,
    _Open open,
  ) {
    final mode = switch (form.modeOf(key)) {
      ChatParamMode.inherit => ChatSettingMode.inherit,
      ChatParamMode.modelDefault => ChatSettingMode.modelDefault,
      ChatParamMode.custom => ChatSettingMode.custom,
    };
    if (key == kChatParamSystem) {
      return ChatSettingField(
        key: key,
        kind: ChatSettingKind.text,
        mode: mode,
        text: mode == ChatSettingMode.custom ? form.textOf(key) : '',
      );
    }
    final spec = chatParamSpecFor(key)!;
    final reasoning = key == kChatParamReasoningEffort;
    return ChatSettingField(
      key: key,
      kind: switch (spec.kind) {
        ChatParamKind.text => ChatSettingKind.text,
        ChatParamKind.decimal => ChatSettingKind.decimal,
        ChatParamKind.integer => ChatSettingKind.integer,
        ChatParamKind.stopList => ChatSettingKind.stopList,
        ChatParamKind.responseFormat => ChatSettingKind.responseFormat,
        ChatParamKind.choice => ChatSettingKind.choice,
      },
      mode: mode,
      text: mode == ChatSettingMode.custom ? form.textOf(key) : '',
      choices: reasoning
          ? (form.reasoningChoices ?? const <String>[])
          : key == kChatParamFunctionCalling
          ? kChatFunctionCallingChoices
          : const <String>[],
      allowsCustom: reasoning && form.reasoningAllowsCustom,
      min: spec.min?.toDouble(),
      max: spec.max?.toDouble(),
      error: switch (form.errorOf(key)) {
        null => null,
        ChatParamInputError.required => ChatSettingError.required,
        ChatParamInputError.notANumber => ChatSettingError.notANumber,
        ChatParamInputError.notAWholeNumber => ChatSettingError.notAWholeNumber,
        ChatParamInputError.outOfRange => ChatSettingError.outOfRange,
        ChatParamInputError.notJson => ChatSettingError.notJson,
        ChatParamInputError.notAChoice => ChatSettingError.notAChoice,
      },
    );
  }
}

/// One call's view of a chat's settings.
final class _Open {
  _Open({
    required this.ref,
    required this.read,
    required this.conversation,
    required this.model,
    required this.access,
    required this.saved,
  });

  /// Where a save runs: the chat's live scope when it has one, so its open
  /// conversation takes the new settings too; else the root.
  final ProviderContainer ref;
  final ReasoningEffortReader read;
  final Conversation? conversation;
  final core.Model? model;
  final OpenWebUiChatSettingsAccess access;
  final Map<String, dynamic> saved;

  ChatSettingsForm form() {
    // As mobile's sheet: the presets only (a saved odd value still shows);
    // a custom effort is typed in the model picker.
    final policy = reasoningEffortPolicyForModel(read, model);
    return ChatSettingsForm(
      saved: saved,
      reasoningChoices: policy.visible
          ? policy.options
                .where((option) => option != kAutomaticReasoningEffort)
                .toList(growable: false)
          : null,
      offersResponseFormat:
          model?.metadata?['owned_by']?.toString() == 'ollama',
    );
  }

  _Open withSaved(Map<String, dynamic> next) => _Open(
    ref: ref,
    read: read,
    conversation: conversation?.copyWith(chatParams: next),
    model: model,
    access: access,
    saved: next,
  );
}
