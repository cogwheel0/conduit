import 'package:drift/drift.dart';

import '../../core/database/app_database.dart';

final class ChatGptThreadBinding {
  const ChatGptThreadBinding({
    required this.localChatId,
    required this.profileId,
    required this.codexThreadId,
    required this.modelId,
    required this.accountFingerprint,
    required this.headMessageId,
    this.webSearchEnabled = false,
    this.imageGenerationEnabled = false,
    this.lastCodexTurnId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String localChatId;
  final String profileId;
  final String codexThreadId;
  final String modelId;
  final String accountFingerprint;
  final String headMessageId;
  final bool webSearchEnabled;
  final bool imageGenerationEnabled;
  final String? lastCodexTurnId;
  final int createdAt;
  final int updatedAt;
}

abstract interface class ChatGptThreadBindingStore {
  Future<ChatGptThreadBinding?> get(
    String localChatId,
    String profileId,
    String headMessageId,
  );
  Future<ChatGptThreadBinding?> latest(String localChatId, String profileId);
  Future<void> put(ChatGptThreadBinding binding);
  Future<void> delete(
    String localChatId,
    String profileId,
    String headMessageId,
  );
  Future<int> deleteAccountChats(String accountFingerprint);
  Future<int> deleteAllChats();
}

final class DriftChatGptThreadBindingStore
    implements ChatGptThreadBindingStore {
  DriftChatGptThreadBindingStore(this._database);

  final AppDatabase _database;

  @override
  Future<ChatGptThreadBinding?> get(
    String localChatId,
    String profileId,
    String headMessageId,
  ) async {
    final row = await _database.directThreadBindingsDao.getBinding(
      localChatId: localChatId,
      profileId: profileId,
      headMessageId: headMessageId,
    );
    return row == null ? null : _fromRow(row);
  }

  @override
  Future<ChatGptThreadBinding?> latest(
    String localChatId,
    String profileId,
  ) async {
    final row = await _database.directThreadBindingsDao.getLatestBinding(
      localChatId: localChatId,
      profileId: profileId,
    );
    return row == null ? null : _fromRow(row);
  }

  @override
  Future<void> put(ChatGptThreadBinding binding) =>
      _database.directThreadBindingsDao.putBinding(
        DirectThreadBindingsCompanion.insert(
          localChatId: binding.localChatId,
          profileId: binding.profileId,
          codexThreadId: binding.codexThreadId,
          modelId: binding.modelId,
          accountFingerprint: binding.accountFingerprint,
          webSearchEnabled: Value(binding.webSearchEnabled),
          imageGenerationEnabled: Value(binding.imageGenerationEnabled),
          headMessageId: binding.headMessageId,
          lastCodexTurnId: Value(binding.lastCodexTurnId),
          createdAt: binding.createdAt,
          updatedAt: binding.updatedAt,
        ),
      );

  @override
  Future<void> delete(
    String localChatId,
    String profileId,
    String headMessageId,
  ) => _database.directThreadBindingsDao.deleteBinding(
    localChatId: localChatId,
    profileId: profileId,
    headMessageId: headMessageId,
  );

  @override
  Future<int> deleteAccountChats(String accountFingerprint) =>
      _database.directThreadBindingsDao.deleteAccountChats(accountFingerprint);

  @override
  Future<int> deleteAllChats() =>
      _database.directThreadBindingsDao.deleteAllBoundChats();

  static ChatGptThreadBinding _fromRow(DirectThreadBindingRow row) =>
      ChatGptThreadBinding(
        localChatId: row.localChatId,
        profileId: row.profileId,
        codexThreadId: row.codexThreadId,
        modelId: row.modelId,
        accountFingerprint: row.accountFingerprint,
        webSearchEnabled: row.webSearchEnabled,
        imageGenerationEnabled: row.imageGenerationEnabled,
        headMessageId: row.headMessageId,
        lastCodexTurnId: row.lastCodexTurnId,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
      );
}

final class MemoryChatGptThreadBindingStore
    implements ChatGptThreadBindingStore {
  final Map<String, ChatGptThreadBinding> _bindings = {};

  String _key(String chatId, String profileId, String headMessageId) =>
      '$profileId\u0000$chatId\u0000$headMessageId';

  @override
  Future<ChatGptThreadBinding?> get(
    String localChatId,
    String profileId,
    String headMessageId,
  ) async => _bindings[_key(localChatId, profileId, headMessageId)];

  @override
  Future<ChatGptThreadBinding?> latest(
    String localChatId,
    String profileId,
  ) async {
    final matches =
        _bindings.values
            .where(
              (binding) =>
                  binding.localChatId == localChatId &&
                  binding.profileId == profileId,
            )
            .toList(growable: false)
          ..sort((a, b) {
            final updated = b.updatedAt.compareTo(a.updatedAt);
            if (updated != 0) return updated;
            final created = b.createdAt.compareTo(a.createdAt);
            if (created != 0) return created;
            return b.headMessageId.compareTo(a.headMessageId);
          });
    return matches.isEmpty ? null : matches.first;
  }

  @override
  Future<void> put(ChatGptThreadBinding binding) async {
    _bindings[_key(
          binding.localChatId,
          binding.profileId,
          binding.headMessageId,
        )] =
        binding;
  }

  @override
  Future<void> delete(
    String localChatId,
    String profileId,
    String headMessageId,
  ) async {
    _bindings.remove(_key(localChatId, profileId, headMessageId));
  }

  @override
  Future<int> deleteAccountChats(String accountFingerprint) async {
    final matches = _bindings.entries
        .where((entry) => entry.value.accountFingerprint == accountFingerprint)
        .toList(growable: false);
    final chatIds = matches.map((entry) => entry.value.localChatId).toSet();
    for (final entry in matches) {
      _bindings.remove(entry.key);
    }
    chatIds.removeWhere(
      (chatId) =>
          _bindings.values.any((binding) => binding.localChatId == chatId),
    );
    return chatIds.length;
  }

  @override
  Future<int> deleteAllChats() async {
    final chatIds = _bindings.values
        .map((binding) => binding.localChatId)
        .toSet();
    _bindings.clear();
    return chatIds.length;
  }
}
