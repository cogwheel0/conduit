import 'dart:async';
import 'dart:typed_data';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

/// Implements `POST /upload`: attachments on their way to the server (WP-3.3).
///
/// An HTTP route rather than an RPC method because of what it carries. A
/// JSON-RPC frame is a string, so a 200 MB attachment would have to become
/// base64 inside one -- a third larger, held whole in memory on both sides,
/// and blocking the socket every other call shares. Raw bytes on their own
/// request cost none of that.
///
/// The renderer never holds the server's credential, so it cannot upload
/// directly: the bytes come here with the daemon's own session token and
/// leave with the Open WebUI session attached.
final class FilesService {
  FilesService(this._container);

  final ProviderContainer _container;

  /// What was uploaded through this daemon, by id.
  ///
  /// Open WebUI wants a file's name alongside its id when a turn refers to
  /// it, and the renderer would otherwise have to send the name back for
  /// the daemon to pass on -- a value the daemon already had and threw
  /// away. Bounded because it is only this process's own uploads.
  final Map<String, UploadedFile> _uploaded = <String, UploadedFile>{};

  /// The file entry for [id], if this daemon uploaded it.
  UploadedFile? describe(String id) => _uploaded[id];

  Future<UploadedFile> upload({
    required String name,
    required Uint8List bytes,
    String? contentType,
  }) async {
    final api = _container.read(apiServiceProvider);
    final session = _container.read(authStateManagerProvider).value;
    if (api == null || session == null || !session.isAuthenticated) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'sign in before uploading',
      );
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'an upload needs a file name',
      );
    }
    if (bytes.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'an upload needs a body',
      );
    }

    final id = await api.uploadFileBytes(trimmed, bytes);
    final file = UploadedFile(
      id: id,
      name: trimmed,
      size: bytes.length,
      contentType: contentType,
    );
    _uploaded[id] = file;
    return file;
  }

  /// The `files` entries a completion request carries for [ids].
  ///
  /// Shaped the way Open WebUI's own frontend shapes them, including the
  /// `url` field that repeats the id -- the server stores the id there now,
  /// not a path, and omitting it makes the attachment invisible to the
  /// model.
  List<Map<String, dynamic>> attachmentsFor(List<String> ids) {
    return <Map<String, dynamic>>[
      for (final id in ids)
        <String, dynamic>{
          'type': 'file',
          'id': id,
          'url': id,
          if (_uploaded[id] case final file?) ...<String, dynamic>{
            'name': file.name,
            'size': file.size,
          },
        },
    ];
  }
}
