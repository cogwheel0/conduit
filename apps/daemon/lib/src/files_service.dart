import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/workspace/models/workspace_model_draft.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_session.dart'
    show WorkspaceSessionChanged;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/attachment_upload_retry.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'account_scope.dart';
import 'settled.dart';

/// Implements `POST /upload`: attachments on their way to the server.
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
  /// away. It keeps a name and a size for each upload this process made,
  /// and goes when the process does.
  final Map<String, UploadedFile> _uploaded = <String, UploadedFile>{};

  /// The file entry for [id], if this daemon uploaded it.
  UploadedFile? describe(String id) => _uploaded[id];

  /// The signed-in session, read when an upload's request begins: its
  /// body can take a while to arrive, and [upload] goes only to the account
  /// that was signed in then.
  Object session() => _container.read(openWebUiAuthSessionEpochProvider);

  Future<UploadedFile> upload({
    required String name,
    required Uint8List bytes,
    required Object session,
    String? contentType,

    /// Files the upload under this channel, for its members to read.
    String? channelId,
  }) async {
    // Another account signed in since the request began: the file is
    // refused rather than sent to that account's server. No await between
    // this check and the upload's client read below.
    if (!identical(session, this.session())) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        debugMessage: 'the account changed during the upload',
      );
    }
    final api = _container.read(apiServiceProvider);
    final auth = _container.read(authStateManagerProvider).value;
    if (api == null || auth == null || !auth.isAuthenticated) {
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

    final id = await api.uploadFileBytes(
      trimmed,
      bytes,
      metadata: channelId == null || channelId.isEmpty
          ? null
          : <String, dynamic>{'channel_id': channelId},
    );
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
            // So a question with a picture on it shows a picture later,
            // not a file name.
            'content_type': ?file.contentType,
          },
        },
    ];
  }

  /// A file on the active server, for `GET /files/{server}/{file}`.
  ///
  /// Through the core's authenticated client, so an `<img>` in the window
  /// shows an attachment without the window ever holding the server's
  /// credential. Refused for any server but the active one: the id in the
  /// path is a guard against showing one account's file under another's.
  Future<({Uint8List bytes, String contentType})> download(
    String serverId,
    String fileId,
  ) async {
    // The id is put into the server's path, with the account's credential,
    // so it must be one plain segment: no `..`, query, fragment or slash,
    // and no `%`, which the server would decode into one of them.
    if (fileId.isEmpty ||
        fileId == '.' ||
        fileId == '..' ||
        fileId.contains(RegExp(r'[/\\?#%]'))) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'not a file id',
      );
    }
    final server = await readSettled(_container, activeServerProvider.future);
    if (server == null || server.id != serverId) {
      throw const RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'not the active server',
      );
    }
    final api = _container.read(apiServiceProvider);
    if (api == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'sign in before loading files',
      );
    }
    // The account can change while the check above awaits: the client read
    // after it must still be the requested server's.
    if (api.serverConfig.id != serverId) {
      throw const RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'not the active server',
      );
    }
    // The core answers an image as a data URL and anything else as bare
    // base64 -- the shape its Flutter widgets want. Undone here, once.
    final content = await api.getFileContent(fileId, maxBytes: maxFileBytes);
    if (content.startsWith('data:')) {
      final comma = content.indexOf(',');
      final type = content.substring(5, comma).split(';').first;
      return (
        bytes: base64Decode(content.substring(comma + 1)),
        contentType: type.isEmpty ? 'application/octet-stream' : type,
      );
    }
    final bytes = base64Decode(content);
    return (bytes: bytes, contentType: _typeOf(bytes));
  }

  /// A model's profile image, for `GET /files/{server}/models/{model}`:
  /// the image the model keeps, or a picture at an address on the server
  /// itself, fetched with the account's credential (core's
  /// `getWorkspaceModelAvatar`); never one on another site. Refused for any
  /// server but the active one, as [download] is; not found when the model
  /// has no picture of its own. Bound to the account it was asked under:
  /// another account signing in meanwhile gets no bytes of the earlier one's.
  Future<({Uint8List bytes, String contentType})> modelImage(
    String serverId,
    String modelId,
  ) async {
    final account = AccountScope.capture(_container);
    final server = await readSettled(_container, activeServerProvider.future);
    account.require('the server was read');
    if (server == null || server.id != serverId) {
      throw const RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'not the active server',
      );
    }
    final api = _container.read(apiServiceProvider);
    if (api == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'sign in before loading images',
      );
    }
    String? imageUrl;
    try {
      final model = await readSettled(
        _container,
        workspaceModelDetailProvider(modelId).future,
      );
      if (model != null) {
        imageUrl = WorkspaceModelDraft.fromSummary(model).profileImageUrl;
      }
    } on WorkspaceSessionChanged {
      // The session it was asked under ended: so does the request.
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        args: <String, String>{'reason': 'account'},
        debugMessage: 'the session changed before the model was read',
      );
    } on Object {
      // Unreadable here (no access, offline): the endpoint still answers.
    }
    account.require('the model was read');
    // The credential it fetches with is still the session's own.
    if (!identical(_container.read(apiServiceProvider), api)) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        args: <String, String>{'reason': 'account'},
        debugMessage: 'the session changed before the picture was fetched',
      );
    }
    final bytes = await api.getWorkspaceModelAvatar(
      modelId,
      imageUrl: imageUrl,
    );
    account.require('the picture arrived');
    if (bytes == null) {
      throw const RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'the model has no picture',
      );
    }
    final data = Uint8List.fromList(bytes);
    return (bytes: data, contentType: _imageTypeOf(data));
  }

  /// A picture's type by its signature (the window decodes it by type,
  /// then by its bytes); never a type a browser would run.
  static String _imageTypeOf(Uint8List b) {
    bool starts(List<int> sig, [int at = 0]) {
      if (b.length < at + sig.length) return false;
      for (var i = 0; i < sig.length; i++) {
        if (b[at + i] != sig[i]) return false;
      }
      return true;
    }

    if (starts(const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
    if (starts(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (starts(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
    if (starts(const [0x52, 0x49, 0x46, 0x46]) &&
        starts(const [0x57, 0x45, 0x42, 0x50], 8)) {
      return 'image/webp';
    }
    return 'application/octet-stream';
  }

  /// A PDF by its signature, since the core hands non-images over without
  /// a type -- and a PDF has to arrive as one for the viewer to open it.
  /// Anything else stays opaque bytes: never a type a browser would run.
  static String _typeOf(Uint8List bytes) {
    const pdf = <int>[0x25, 0x50, 0x44, 0x46, 0x2D]; // %PDF-
    if (bytes.length >= pdf.length) {
      var matches = true;
      for (var i = 0; i < pdf.length; i++) {
        if (bytes[i] != pdf[i]) {
          matches = false;
          break;
        }
      }
      if (matches) return 'application/pdf';
    }
    return 'application/octet-stream';
  }

  /// Larger than any image a chat shows; a download of something bigger
  /// is not what this route is for.
  static const int maxFileBytes = 50 * 1024 * 1024;
}

/// What a failed upload's answer says about trying again, by the core's
/// rules ([classifyUploadFailure], [uploadRetryDelay]): `retry` is
/// `offline` (wait for the network), `indeterminate` (the server may hold
/// the file: only the user retries), `retryable` (try again after
/// `retryAfterMs`) or `exhausted` (try [attempt] was the last).
Map<String, String> uploadRetryArgs(Object error, int attempt) {
  final kind = classifyUploadFailure(error);
  final exhausted =
      kind == UploadFailureKind.retryable && attempt >= kUploadMaxRetries;
  return <String, String>{
    'retry': exhausted ? 'exhausted' : kind.name,
    'retryAfterMs': '${uploadRetryDelay(attempt).inMilliseconds}',
  };
}
