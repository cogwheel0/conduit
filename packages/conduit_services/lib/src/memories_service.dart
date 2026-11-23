import 'package:conduit_core/models/server_memory.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'settled.dart';

/// `memories.*`: the account's memories on its Open WebUI server and its
/// "Memory" setting, through core's `UserMemories` and
/// `PersonalizationSettings`, as the phone's Personalization page uses them.
///
/// Each change is fenced to the account it was asked for (core's
/// `MemoryOwner`): a switch in between refuses it before anything is sent.
final class MemoriesService {
  MemoriesService(this._container);

  final ProviderContainer _container;

  UserMemories get _memories => _container.read(userMemoriesProvider.notifier);

  /// Whether this account may use memories: signed in to Open WebUI, and not
  /// refused by the server's permissions (admins always may).
  Future<bool> _available() async {
    if (_container.read(apiServiceProvider) == null) return false;
    try {
      return await readSettled(_container, memoriesPermittedProvider.future);
    } on Object {
      // The phone hides the section only on an explicit no.
      return true;
    }
  }

  Future<MemoryList> list() async {
    if (!await _available()) return const MemoryList();
    final settings = await readSettled(
      _container,
      personalizationSettingsProvider.future,
    );
    final items = await readSettled(_container, userMemoriesProvider.future);
    return MemoryList(
      available: true,
      enabled: settings.memoryEnabled,
      items: _sorted(items),
    );
  }

  /// Newest change first, as the phone lists them. A server may give the
  /// time in seconds or milliseconds; [ServerMemory.updatedAt] reads both,
  /// and the window gets seconds.
  static List<MemoryDto> _sorted(List<ServerMemory> items) {
    final sorted = List<ServerMemory>.of(items)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return <MemoryDto>[
      for (final m in sorted)
        MemoryDto(
          id: m.id,
          content: m.content,
          type: m.type,
          path: m.path,
          updatedAt: m.updatedAt.millisecondsSinceEpoch ~/ 1000,
        ),
    ];
  }

  MemoryOwner _owner() =>
      _memories.captureOwner() ??
      (throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'no Open WebUI account can hold memories now',
      ));

  static String _content(MemoryEdit edit) {
    final content = edit.content.trim();
    if (content.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a memory needs words',
      );
    }
    return content;
  }

  static void _checkType(String? type) {
    if (type != null &&
        type != ServerMemory.userType &&
        type != ServerMemory.contextType) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'no memory type "$type"',
      );
    }
  }

  Future<MemoryList> add(MemoryEdit edit) async {
    final content = _content(edit);
    _checkType(edit.type);
    await _memories.add(
      content,
      type: edit.type ?? ServerMemory.userType,
      path: edit.path,
      owner: _owner(),
    );
    return list();
  }

  Future<MemoryList> update(MemoryEdit edit) async {
    final id = edit.id;
    if (id == null || id.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'which memory',
      );
    }
    final content = _content(edit);
    _checkType(edit.type);
    await _memories.updateItem(
      id,
      content,
      type: edit.type,
      path: edit.path,
      owner: _owner(),
    );
    return list();
  }

  Future<MemoryList> delete(MemoryRef ref) async {
    await _memories.deleteItem(ref.id, owner: _owner());
    return list();
  }

  Future<MemoryList> clear() async {
    await _memories.clearAll(owner: _owner());
    return list();
  }

  Future<MemoryList> setEnabled(MemoryToggle toggle) async {
    if (_container.read(apiServiceProvider) == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'no Open WebUI account is in use',
      );
    }
    await _container
        .read(personalizationSettingsProvider.notifier)
        .setMemoryEnabled(toggle.enabled);
    return list();
  }
}
