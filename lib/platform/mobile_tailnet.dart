import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';
import 'package:url_launcher/url_launcher.dart';

import 'flutter_secure_key_value_store.dart';
import 'tailnet_native.dart';

bool get supportsMobileTailnet =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

enum TailnetState {
  signedOut,
  idle,
  connecting,
  authorizing,
  needsApproval,
  connected,
  unavailable,
}

class MobileTailnet extends ChangeNotifier {
  MobileTailnet({
    required this.storage,
    required this.directory,
    required this.call,
    required this.openLogin,
  });
  static final instance = MobileTailnet(
    storage: FlutterSecureKeyValueStore(
      const FlutterSecureStorage(
        aOptions: AndroidOptions(
          storageNamespace: 'conduit_tailnet',
          resetOnError: false,
        ),
        iOptions: IOSOptions(
          accountName: 'conduit_tailnet',
          synchronizable: false,
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      ),
    ),
    directory: () async => Directory(
      '${(await getApplicationSupportDirectory()).path}/conduit-tailnet',
    ),
    call: callTailnet,
    openLogin: (url) => launchUrl(url, mode: LaunchMode.externalApplication),
  );
  final SecureKeyValueStore storage;
  final Future<Directory> Function() directory;
  final Future<Map<String, dynamic>> Function(Map<String, Object>) call;
  final Future<bool> Function(Uri) openLogin;
  static const _key = 'mobile_tailnet_identity_key_v1';
  static const _enrolled = 'mobile_tailnet_enrolled';
  final _lock = Lock();
  TailnetState state = TailnetState.signedOut;
  bool _started = false;
  bool _inBackground = false;
  bool _loggingIn = false;
  Uri? _loginUrl;
  Timer? _poll;
  Timer? _browserGracePeriod;
  int _epoch = 0;

  void _set(TailnetState next) {
    if (next == state) return;
    state = next;
    notifyListeners();
  }

  Future<void> refresh() => _lock.synchronized(() async {
    if (!_started) {
      _set(
        await storage.read(key: _key) == null
            ? TailnetState.signedOut
            : await storage.read(key: _enrolled) == '1'
            ? TailnetState.idle
            : TailnetState.authorizing,
      );
      return;
    }
    await _apply(await call({'op': 'status'}));
  });

  Future<void> _apply(Map<String, dynamic> result) async {
    final raw = result['loginURL'];
    final uri = raw is String ? Uri.tryParse(raw) : null;
    _loginUrl =
        uri != null &&
            uri.scheme == 'https' &&
            uri.host == 'login.tailscale.com' &&
            uri.userInfo.isEmpty &&
            uri.port == 443
        ? uri
        : null;
    switch (result['state']) {
      case 'Running':
        if (state != TailnetState.connected &&
            await storage.read(key: _enrolled) != '1') {
          await storage.write(key: _enrolled, value: '1');
        }
        _set(TailnetState.connected);
        _loggingIn = false;
        _poll?.cancel();
      case 'NeedsLogin':
        _set(TailnetState.authorizing);
      case 'NeedsMachineAuth':
        _set(TailnetState.needsApproval);
      default:
        _set(TailnetState.connecting);
    }
  }

  Future<void> _start({required bool enroll}) async {
    if (_started) {
      await _apply(await call({'op': 'status'}));
      return;
    }
    var key = await storage.read(key: _key);
    if (key == null) {
      if (!enroll) {
        throw const SocketException('Sign in to Tailscale in Settings.');
      }
      final random = Random.secure();
      key = base64Encode(List.generate(32, (_) => random.nextInt(256)));
      await storage.write(key: _key, value: key);
    }
    final dir = await directory();
    try {
      final response = await call({'op': 'start', 'dir': dir.path, 'key': key});
      _started = true;
      await _apply(response);
    } catch (_) {
      // Native startup can create a node before its first status read fails.
      try {
        await call({'op': 'stop'});
      } finally {
        _started = false;
      }
      rethrow;
    }
  }

  Future<void> signIn() async {
    final epoch = ++_epoch;
    _poll?.cancel();
    _loggingIn = true;
    _set(TailnetState.connecting);
    try {
      await _lock.synchronized(() => _start(enroll: true));
      // Startup may report Starting before the control plane supplies its URL.
      for (var i = 0; i < 60 && epoch == _epoch; i++) {
        if (state == TailnetState.connected) return;
        if (_loginUrl != null || state == TailnetState.needsApproval) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (epoch != _epoch) return;
        await refresh();
      }
      if (epoch != _epoch) return;
      if (state != TailnetState.needsApproval &&
          (_loginUrl == null || !await openLogin(_loginUrl!))) {
        throw StateError('Sign-in is unavailable');
      }
      if (epoch != _epoch) return;
      _pollStatus(epoch, 120);
    } catch (_) {
      if (epoch == _epoch) {
        _loggingIn = false;
        _set(TailnetState.unavailable);
      }
    }
  }

  void _pollStatus(int epoch, int remaining) {
    _poll?.cancel();
    if (!_loggingIn || epoch != _epoch) return;
    if (remaining == 0) {
      _loggingIn = false;
      _set(TailnetState.unavailable);
      return;
    }
    _poll = Timer(const Duration(seconds: 2), () async {
      try {
        await refresh();
        if (epoch == _epoch && !_inBackground) {
          _pollStatus(epoch, remaining - 1);
        }
      } catch (_) {
        if (epoch == _epoch) _set(TailnetState.unavailable);
      }
    });
  }

  Future<void> signOut() async {
    _browserGracePeriod?.cancel();
    _epoch++;
    _loggingIn = false;
    _poll?.cancel();
    await _lock.synchronized(() async {
      if (_started) {
        try {
          await call({'op': 'logout'});
        } catch (_) {
          // Logout stops the native node even if remote revocation fails.
        }
      }
      _started = false;
      // Forget locally even when the control plane or the peer is offline.
      await storage.delete(key: _key);
      await storage.delete(key: _enrolled);
      final dir = await directory();
      if (await dir.exists()) await dir.delete(recursive: true);
      _loginUrl = null;
      _set(TailnetState.signedOut);
    });
  }

  Future<void> lifecycle(bool background) async {
    _inBackground = background;
    _browserGracePeriod?.cancel();
    if (background) {
      _poll?.cancel();
      if (_loggingIn) {
        // The external browser needs a short window to authorize this node.
        // Stop it if the user leaves the login screen and never returns.
        _browserGracePeriod = Timer(const Duration(minutes: 2), () {
          if (!_inBackground) return;
          _epoch++;
          _loggingIn = false;
          unawaited(lifecycle(true));
        });
      } else {
        await _lock.synchronized(() async {
          if (!_inBackground || !_started || _loggingIn) return;
          try {
            await call({'op': 'stop'});
            _set(
              await storage.read(key: _enrolled) == '1'
                  ? TailnetState.idle
                  : TailnetState.authorizing,
            );
          } catch (_) {
            _set(TailnetState.unavailable);
          } finally {
            _started = false;
          }
        });
      }
    } else if (_loggingIn) {
      _pollStatus(_epoch, 120);
    }
  }

  Future<ConnectionTask<Socket>> connect(
    Uri uri,
    SecurityContext? context,
    bool Function(X509Certificate, String, int)? trust,
  ) async {
    final epoch = _epoch;
    await _lock.synchronized(() async {
      if (_inBackground || epoch != _epoch) {
        throw const SocketException('Tailscale is offline');
      }
      await _start(enroll: false);
    });
    if (state == TailnetState.authorizing ||
        state == TailnetState.needsApproval) {
      throw const SocketException(
        'Tailscale sign-in or device approval is required.',
      );
    }
    Socket? socket;
    var cancelled = false;
    Future<Socket> dial() async {
      final response = await call({
        'op': 'dial',
        'host': uri.host,
        'port': uri.port,
      });
      if (cancelled || epoch != _epoch) {
        throw const SocketException('Connection cancelled');
      }
      final local = await Socket.connect(
        InternetAddress.loopbackIPv4,
        response['port'] as int,
        timeout: const Duration(seconds: 5),
      );
      socket = local;
      try {
        if (cancelled || epoch != _epoch) {
          throw const SocketException('Connection cancelled');
        }
        local.add(ascii.encode(response['ticket'] as String));
        await local.flush();
        if (uri.scheme != 'https' && uri.scheme != 'wss') return local;
        final secure = await SecureSocket.secure(
          local,
          host: uri.host,
          context: context,
          onBadCertificate: trust == null
              ? null
              : (cert) => trust(cert, uri.host, uri.port),
        );
        socket = secure;
        if (cancelled || epoch != _epoch) {
          secure.destroy();
          throw const SocketException('Connection cancelled');
        }
        return secure;
      } catch (_) {
        local.destroy();
        rethrow;
      }
    }

    return ConnectionTask.fromSocket(dial(), () {
      cancelled = true;
      socket?.destroy();
    });
  }
}
