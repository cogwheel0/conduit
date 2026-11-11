import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/librechat/models/librechat_capabilities.dart';
import 'package:conduit_core/features/librechat/models/librechat_prompts.dart';
import 'package:conduit_core/features/librechat/providers/librechat_memories_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../settings_page_module.dart';
import '../settings_pages.dart';

/// Id of the page with the LibreChat account's memories, which the root's
/// Personalization row opens while LibreChat is in charge.
const libreChatMemoriesPageId = nativeLibreChatPersonalizationActionId;

/// Id of the page adding a memory.
const libreChatMemoryNewPageId = 'librechat-memory-new';

/// Prefix of the page of one memory; its key follows, URI-encoded.
const libreChatMemoryPagePrefix = 'librechat-memory:';

/// Row ids of a memory page: `librechat.<field>:<page id>`.
String libreChatMemoryRowId(String field, String pageId) =>
    'librechat.$field:$pageId';

/// The memory switch of the memories page.
const libreChatMemoriesEnabledId = 'librechat.enabled';

/// What the memories page shows: the switch, the budget, the memories.
@visibleForTesting
NativeSheetDetailConfig buildLibreChatMemoriesPage(
  AppLocalizations l10n, {
  required LibreChatMemoryState? state,
  required LibreChatCapabilities capabilities,
  String? notice,
}) {
  final memories = state?.memories;
  final limit = memories?.tokenLimit;
  return NativeSheetDetailConfig(
    id: libreChatMemoriesPageId,
    title: l10n.personalization,
    sections: [
      if (notice != null)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: '$libreChatMemoriesPageId-notice',
              title: notice,
              sfSymbol: 'exclamationmark.triangle',
              kind: NativeSheetItemKind.info,
            ),
          ],
        ),
      if (state == null)
        NativeSheetSectionConfig(items: [buildNativeLoadingItem(l10n)])
      // This server's interface keeps no memories, or not for this role.
      else if (!capabilities.memories)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: '$libreChatMemoriesPageId-unavailable',
              title: l10n.nativeSheetOptionUnavailable,
              sfSymbol: 'exclamationmark.triangle',
              kind: NativeSheetItemKind.info,
            ),
          ],
        )
      else ...[
        NativeSheetSectionConfig(
          footer: state.enabled
              ? l10n.memoryEnabledDescription
              : l10n.memoryDisabledDescription,
          items: [
            NativeSheetItemConfig(
              id: libreChatMemoriesEnabledId,
              title: l10n.memoryTitle,
              subtitle: capabilities.optOutMemories
                  ? null
                  : state.enabled
                  ? l10n.enabled
                  : l10n.disabled,
              sfSymbol: 'bookmark',
              // The server decides whether this account may switch it.
              kind: capabilities.optOutMemories
                  ? NativeSheetItemKind.toggle
                  : NativeSheetItemKind.info,
              value: state.enabled,
            ),
          ],
        ),
        NativeSheetSectionConfig(
          title: l10n.manageMemories,
          footer: limit == null
              ? l10n.savedMemoriesCount(memories!.memories.length)
              : l10n.libreChatMemoryUsage(memories!.totalTokens, limit),
          items: [
            if (capabilities.createMemories)
              NativeSheetItemConfig(
                id: libreChatMemoryNewPageId,
                title: l10n.addMemory,
                subtitle: l10n.manageMemoriesDescription,
                sfSymbol: 'plus.circle',
                accent: true,
              ),
            if (memories.memories.isEmpty)
              NativeSheetItemConfig(
                id: '$libreChatMemoriesPageId-empty',
                title: l10n.noMemoriesSaved,
                sfSymbol: 'note.text',
                kind: NativeSheetItemKind.info,
              )
            else
              for (final memory in memories.memories)
                NativeSheetItemConfig(
                  id: _memoryPageId(memory.key),
                  title: memory.key,
                  subtitle: truncateNativeSheetMemory(memory.value),
                  sfSymbol: 'quote.bubble',
                  // Without leave to change memories, a row only reads.
                  kind: capabilities.updateMemories
                      ? NativeSheetItemKind.navigation
                      : NativeSheetItemKind.info,
                ),
          ],
        ),
      ],
    ],
  );
}

String _memoryPageId(String key) =>
    '$libreChatMemoryPagePrefix${Uri.encodeComponent(key)}';

/// A memory's page, or the page adding one when [memory] is null: its key
/// and text wait as a draft until Done.
@visibleForTesting
NativeSheetDetailConfig buildLibreChatMemoryPage(
  AppLocalizations l10n, {
  required String pageId,
  required LibreChatMemory? memory,
  required ({String key, String value}) draft,
  required bool canDelete,
  String? notice,
}) {
  String row(String field) => libreChatMemoryRowId(field, pageId);
  return NativeSheetDetailConfig(
    id: pageId,
    title: memory == null ? l10n.addMemory : l10n.editMemory,
    confirmActionId: row('save'),
    confirmActionLabel: l10n.save,
    sections: [
      if (notice != null)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: row('notice'),
              title: notice,
              sfSymbol: 'exclamationmark.triangle',
              kind: NativeSheetItemKind.info,
            ),
          ],
        ),
      NativeSheetSectionConfig(
        footer: l10n.libreChatMemoryKeyHint,
        items: [
          NativeSheetItemConfig(
            id: row('key'),
            title: l10n.libreChatMemoryKeyLabel,
            sfSymbol: 'tag',
            kind: NativeSheetItemKind.textField,
            value: draft.key,
            placeholder: l10n.libreChatMemoryKeyLabel,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        footer: l10n.memoryEditorDescription,
        items: [
          NativeSheetItemConfig(
            id: row('value'),
            title: memory == null ? l10n.addMemory : l10n.editMemory,
            sfSymbol: 'quote.bubble',
            kind: NativeSheetItemKind.multilineTextField,
            value: draft.value,
            placeholder: l10n.memoryHint,
          ),
        ],
      ),
      if (memory != null && canDelete)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: row('delete'),
              title: l10n.deleteMemory,
              sfSymbol: 'trash',
              destructive: true,
              confirmMessage: l10n.deleteMemoryConfirm,
            ),
          ],
        ),
    ],
  );
}

/// The LibreChat account's memories: the page listing them, each memory's
/// page, and the page adding one. Every change goes to the account the list
/// was opened for, and is read back from its server.
class LibreChatMemorySettingsPages implements SettingsPageModule {
  LibreChatMemorySettingsPages(this._ref);

  final Ref _ref;

  /// The account the list was read for.
  String? _accountId;
  LibreChatCapabilities _capabilities = LibreChatCapabilities.minimal;
  final Map<String, ({String key, String value})> _drafts = {};
  final Map<String, String> _notices = {};
  String? _listNotice;

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);
  LibreChatMemoriesController get _memories =>
      _ref.read(libreChatMemoriesProvider.notifier);

  LibreChatMemoryState? get _state =>
      _ref.read(libreChatMemoriesProvider).asData?.value;

  LibreChatMemory? _memory(String pageId) {
    if (!pageId.startsWith(libreChatMemoryPagePrefix)) return null;
    final key = Uri.decodeComponent(
      pageId.substring(libreChatMemoryPagePrefix.length),
    );
    return _state?.memories.memories
        .where((memory) => memory.key == key)
        .firstOrNull;
  }

  bool get _sameAccount =>
      _accountId != null &&
      _ref.read(activeLibreChatAccountProvider)?.id == _accountId;

  @override
  bool ownsPage(String detailId) =>
      detailId == libreChatMemoriesPageId ||
      detailId == libreChatMemoryNewPageId ||
      detailId.startsWith(libreChatMemoryPagePrefix);

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    if (detailId == libreChatMemoriesPageId) {
      await _hydrateList(l10n);
      return;
    }
    final memory = _memory(detailId);
    final draft = _drafts.putIfAbsent(
      detailId,
      () => (key: memory?.key ?? '', value: memory?.value ?? ''),
    );
    await _applyPage(l10n, detailId, memory, draft);
  }

  Future<void> _hydrateList(AppLocalizations l10n) async {
    _drafts.clear();
    _notices.clear();
    _accountId = _ref.read(activeLibreChatAccountProvider)?.id;
    await _applyList(l10n);
    LibreChatMemoryState? state;
    // Listened to while they load, so they rebuild as what they watch
    // arrives rather than leave a read waiting on a replaced build.
    final capabilities = _ref.listen(libreChatCapabilitiesProvider, (_, _) {});
    final memories = _ref.listen(libreChatMemoriesProvider, (_, _) {});
    try {
      const patience = Duration(seconds: 15);
      _capabilities = await _ref
          .read(libreChatCapabilitiesProvider.future)
          .timeout(patience);
      state = await _ref
          .read(libreChatMemoriesProvider.future)
          .timeout(patience);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'librechat-memories-load-failed',
        scope: 'settings/librechat',
        error: error,
        stackTrace: stackTrace,
      );
      _listNotice = l10n.errorMessage;
    } finally {
      capabilities.close();
      memories.close();
    }
    await _surface.applyDetail(
      buildLibreChatMemoriesPage(
        l10n,
        state: state,
        capabilities: _capabilities,
        notice: _listNotice,
      ),
      detailSheets: [
        buildNativeLoadingDetail(
          l10n: l10n,
          id: libreChatMemoryNewPageId,
          title: l10n.addMemory,
        ),
        for (final memory in state?.memories.memories ?? const [])
          buildNativeLoadingDetail(
            l10n: l10n,
            id: _memoryPageId(memory.key),
            title: l10n.editMemory,
          ),
      ],
    );
    _listNotice = null;
  }

  Future<void> _applyList(AppLocalizations l10n) => _surface.applyDetail(
    buildLibreChatMemoriesPage(
      l10n,
      state: _state,
      capabilities: _capabilities,
      notice: _listNotice,
    ),
  );

  Future<void> _applyPage(
    AppLocalizations l10n,
    String pageId,
    LibreChatMemory? memory,
    ({String key, String value}) draft,
  ) => _surface.applyDetail(
    buildLibreChatMemoryPage(
      l10n,
      pageId: pageId,
      memory: memory,
      draft: draft,
      canDelete: _capabilities.updateMemories,
      notice: _notices[pageId],
    ),
  );

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    if (id == libreChatMemoriesEnabledId) {
      if (value is bool) await _setEnabled(l10n, value);
      return true;
    }
    if (!id.startsWith('librechat.')) return false;
    final separator = id.indexOf(':');
    if (separator < 0) return true;
    final field = id.substring('librechat.'.length, separator);
    final pageId = id.substring(separator + 1);
    // A row of a page already closed (a second Done on its way) does
    // nothing.
    final draft = _drafts[pageId];
    if (draft == null) return true;
    final memory = _memory(pageId);
    switch (field) {
      case 'key' when value is String:
        _drafts[pageId] = (key: value, value: draft.value);
      case 'value' when value is String:
        _drafts[pageId] = (key: draft.key, value: value);
      case 'save':
        await _save(l10n, pageId, memory, draft);
      case 'delete' when memory != null:
        await _act(l10n, pageId, memory, draft, () async {
          await _memories.delete(memory.key);
        });
    }
    return true;
  }

  Future<void> _setEnabled(AppLocalizations l10n, bool enabled) async {
    if (!_sameAccount) {
      _listNotice = l10n.personalizationMemoryAccountChanged;
    } else {
      try {
        await _memories.setEnabled(enabled);
      } catch (error) {
        _listNotice = error is LibreChatApiException
            ? error.message
            : l10n.errorMessage;
      }
    }
    await _applyList(l10n);
    _listNotice = null;
  }

  Future<void> _save(
    AppLocalizations l10n,
    String pageId,
    LibreChatMemory? memory,
    ({String key, String value}) draft,
  ) async {
    final key = draft.key.trim();
    if (key.isEmpty) {
      _notices[pageId] = l10n.libreChatMemoryKeyRequired;
      await _applyPage(l10n, pageId, memory, draft);
      return;
    }
    if (draft.value.trim().isEmpty) return;
    await _act(l10n, pageId, memory, draft, () async {
      await _memories.save(
        originalKey: memory?.key,
        key: key,
        value: draft.value.trim(),
      );
    });
  }

  /// Runs [action] for the account the list was read for, then goes back
  /// to the list. A refusal stays on the page, with the server's reason.
  Future<void> _act(
    AppLocalizations l10n,
    String pageId,
    LibreChatMemory? memory,
    ({String key, String value}) draft,
    Future<void> Function() action,
  ) async {
    if (!_sameAccount) {
      _notices[pageId] = l10n.personalizationMemoryAccountChanged;
      await _applyPage(l10n, pageId, memory, draft);
      return;
    }
    try {
      await action();
    } catch (error) {
      _notices[pageId] = error is LibreChatApiException
          ? error.message
          : l10n.errorMessage;
      await _applyPage(l10n, pageId, memory, draft);
      return;
    }
    _drafts.remove(pageId);
    _notices.remove(pageId);
    await _surface.closeDetail(pageId);
    await _hydrateList(l10n);
  }
}
