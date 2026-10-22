import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/hermes/models/hermes_media.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_media_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// A lease owns one transfer and private directory. Closing a viewer cancels
/// its network work; switching servers disposes every lease immediately.
class HermesMediaLease {
  HermesMediaLease(this.service, this.root, {this.onClosed});
  final void Function(HermesMediaLease)? onClosed;
  final HermesMediaService service;
  final Future<Directory> root;
  final CancelToken cancel = CancelToken();
  Future<File>? _pending;
  bool _closed = false;
  Future<void>? _closing;
  int _exports = 0;
  Completer<void>? _exportsFinished;

  /// A native save/share already requested by the user must finish reading its
  /// private source even if the sheet closes or the connection changes.
  void retainForExport() {
    if (_closed) throw StateError('This file is no longer open.');
    if (_exports++ == 0) _exportsFinished = Completer<void>();
  }

  void releaseExport() {
    if (_exports > 0 && --_exports == 0) _exportsFinished?.complete();
  }

  Future<File> load(
    HermesMediaReference media, {
    String? sessionId,
    String? profile,
    void Function(int, int)? onProgress,
  }) {
    if (_closed) {
      return Future.error(StateError('This file is no longer open.'));
    }
    return _pending ??= _load(media, sessionId, profile, onProgress).catchError(
      (Object error) {
        _pending = null;
        throw error;
      },
    );
  }

  Future<File> _load(
    HermesMediaReference media,
    String? session,
    String? profile,
    void Function(int, int)? onProgress,
  ) async {
    final directory = await root;
    if (cancel.isCancelled) throw cancel.cancelError!;
    final key = sha256.convert(
      utf8.encode(jsonEncode([profile, session, media.path])),
    );
    final extension = RegExp(r'^[a-zA-Z0-9]{1,12}$').hasMatch(media.extension)
        ? media.extension
        : 'bin';
    final file = File('${directory.path}/$key.$extension');
    await service.downloadMedia(
      media,
      file.path,
      sessionId: session,
      profile: profile,
      cancelToken: cancel,
      onProgress: onProgress,
    );
    if (cancel.isCancelled) throw cancel.cancelError!;
    return file;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    onClosed?.call(this);
    cancel.cancel('File closed');
    try {
      await _pending;
    } catch (_) {
      /* Failed transfers are already removed. */
    }
    await _exportsFinished?.future;
    try {
      final directory = await root;
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (_) {
      /* OS cache eviction is also allowed. */
    }
  }
}

typedef HermesMediaLeaseFactory = HermesMediaLease Function();

final hermesMediaConnectionIdentityProvider = Provider<String?>((ref) {
  final service = ref.watch(hermesApiServiceProvider);
  if (service == null) return null;
  final endpoint = HermesConfigController.connectionEndpoint(
    service.config.baseUrl,
  );
  if (endpoint == null) return null;
  return HermesLocalDocumentTrustStore.connectionIdentity(
    endpointIdentity: endpoint,
    principalId: ref
        .read(hermesConfigProvider.notifier)
        .documentTrustPrincipalId(),
  );
});

final hermesMediaLeaseFactoryProvider = Provider<HermesMediaLeaseFactory?>((
  ref,
) {
  final service = ref.watch(hermesApiServiceProvider);
  if (service is! HermesMediaService) return null;
  final leases = <HermesMediaLease>[];
  ref.onDispose(() {
    for (final lease in leases.toList()) {
      unawaited(lease.close());
    }
  });
  return () {
    final root = getTemporaryDirectory().then((temp) async {
      final base = await Directory('${temp.path}/hermes-media')
          .create(recursive: true);
      return base.createTemp('attachment-');
    });
    final lease = HermesMediaLease(
      service as HermesMediaService,
      root,
      onClosed: leases.remove,
    );
    leases.add(lease);
    return lease;
  };
});
