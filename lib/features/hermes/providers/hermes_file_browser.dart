import 'dart:convert';

import 'package:conduit_core/features/hermes/models/hermes_file_entry.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_file_browser_service.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final hermesFileBrowserAccessProvider = Provider<HermesFileBrowserService?>((
  ref,
) {
  final service = ref.watch(hermesApiServiceProvider);
  return service is HermesFileBrowserService
      ? service as HermesFileBrowserService
      : null;
});

final hermesDirectoryProvider = FutureProvider.autoDispose
    .family<HermesDirectory, String?>((ref, path) async {
      final service = ref.watch(hermesFileBrowserAccessProvider);
      if (service == null) {
        throw UnsupportedError('File browsing is unavailable');
      }
      final cancel = CancelToken();
      ref.onDispose(() => cancel.cancel());
      return service.browseFiles(path: path, cancelToken: cancel);
    });

/// Bookmarks belong to a server, account, and profile. They contain references,
/// never copied file contents or credentials, and survive app restarts.
final hermesFilePinStorageKeyProvider = Provider<String?>((ref) {
  final service = ref.watch(hermesApiServiceProvider);
  if (service == null) return null;
  final principal = ref
      .read(hermesConfigProvider.notifier)
      .documentTrustPrincipalId();
  final identity = jsonEncode([
    HermesConfigController.connectionEndpoint(service.config.baseUrl),
    principal,
    service.config.desktopProfile,
  ]);
  return 'hermes.file-pins.v1.${sha256.convert(utf8.encode(identity))}';
});

/// Lets Android Back move up the explorer's visited folders before the shell
/// switches work areas. A disposed explorer cannot retain the callback.
class HermesFileBrowserBack {
  Object? _owner;
  bool Function()? _back;
  void Function()? _home;
  void register(Object owner, bool Function() back, {void Function()? home}) {
    _owner = owner;
    _back = back;
    _home = home;
  }

  void clear(Object owner) {
    if (!identical(owner, _owner)) return;
    _owner = null;
    _back = null;
    _home = null;
  }

  bool back() => _back?.call() ?? false;
  void home() => _home?.call();
}

final hermesFileBrowserBackProvider = Provider<HermesFileBrowserBack>((ref) {
  ref.watch(hermesFileBrowserAccessProvider);
  return HermesFileBrowserBack();
});

class HermesFilePins extends AsyncNotifier<List<HermesFileEntry>> {
  bool _saving = false;

  @override
  Future<List<HermesFileEntry>> build() async {
    final key = ref.watch(hermesFilePinStorageKeyProvider);
    if (key == null) return const [];
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(key);
    if (raw == null) return const [];
    try {
      final data = jsonDecode(raw);
      if (data is! List) return const [];
      return List.unmodifiable([
        for (final entry in data.take(100))
          if (entry is Map)
            HermesFileEntry.fromJson(Map<String, dynamic>.from(entry)),
      ]);
    } on FormatException {
      return const [];
    }
  }

  Future<void> toggle(HermesFileEntry entry) async {
    if (_saving) return;
    _saving = true;
    final key = ref.read(hermesFilePinStorageKeyProvider);
    try {
      final previous = await future;
      final exists = previous.any((pin) => pin.path == entry.path);
      if (!exists && previous.length >= 100) {
        throw StateError('Pin limit reached');
      }
      final next = List<HermesFileEntry>.unmodifiable([
        for (final pin in previous)
          if (pin.path != entry.path) pin,
        if (!exists) entry,
      ]);
      if (key == null) return;
      final preferences = await SharedPreferences.getInstance();
      if (!ref.mounted || ref.read(hermesFilePinStorageKeyProvider) != key) {
        return;
      }
      final saved = await preferences.setString(
        key,
        jsonEncode(next.map((pin) => pin.toJson()).toList()),
      );
      if (!saved) throw StateError('Could not save pins');
      if (ref.mounted && ref.read(hermesFilePinStorageKeyProvider) == key) {
        state = AsyncData(next);
      }
    } finally {
      _saving = false;
    }
  }
}

final hermesFilePinsProvider =
    AsyncNotifierProvider<HermesFilePins, List<HermesFileEntry>>(
      HermesFilePins.new,
    );
