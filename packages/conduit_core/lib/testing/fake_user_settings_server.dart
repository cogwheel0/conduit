import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class FakeUserSettingsRequest {
  FakeUserSettingsRequest(this.method, this.authorization);

  final String method;
  final String? authorization;
}

/// An Open WebUI user-settings endpoint for tests, as a Dio adapter.
///
/// Models Open WebUI 0.11.4's settings routes: root keys merge shallowly, and
/// `ui` is patched key by key, where a null removes the key.
///
/// Settings belong to the bearer token that asked, so one fixture can stand in
/// for several accounts on the same server. A token with no entry of its own
/// reads and writes the shared [settings].
final class FakeUserSettingsServer implements HttpClientAdapter {
  FakeUserSettingsServer(Map<String, dynamic> initial)
    : _accounts = <String, Map<String, dynamic>>{'*': _clone(initial)};

  final Map<String, Map<String, dynamic>> _accounts;
  final List<FakeUserSettingsRequest> log = <FakeUserSettingsRequest>[];
  final Completer<void> firstGetEntered = Completer<void>();
  final Completer<void> releaseFirstGet = Completer<void>();
  final Completer<void> postEntered = Completer<void>();
  final Completer<void> releasePost = Completer<void>();
  bool stripToolServers = false;
  bool _gateGet = false;
  bool _gatedGet = false;
  bool _gatePost = false;
  int _active = 0;
  int maximumConcurrentRequests = 0;

  Map<String, dynamic> get settings => _accounts['*']!;
  set settings(Map<String, dynamic> value) => _accounts['*'] = value;

  /// Gives [token] its own settings document.
  void addAccount(String token, Map<String, dynamic> initial) =>
      _accounts[token] = _clone(initial);

  Map<String, dynamic> settingsOf(String token) => _accounts[token]!;

  void gateFirstGet() => _gateGet = true;

  /// Holds the response to the first POST until [releasePost] completes.
  void gateFirstPost() => _gatePost = true;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _active++;
    maximumConcurrentRequests = _active > maximumConcurrentRequests
        ? _active
        : maximumConcurrentRequests;
    final authorization = options.headers['Authorization']?.toString();
    log.add(FakeUserSettingsRequest(options.method, authorization));
    final token = (authorization ?? '').replaceFirst('Bearer ', '');
    final key = _accounts.containsKey(token) ? token : '*';
    try {
      if (options.method == 'GET' && _gateGet && !_gatedGet) {
        _gatedGet = true;
        firstGetEntered.complete();
        await releaseFirstGet.future;
      }
      if (options.method == 'POST') {
        final updated = _clone(options.data as Map<String, dynamic>);
        final ui = updated.remove('ui') as Map<String, dynamic>?;
        if (ui != null && stripToolServers) ui.remove('toolServers');
        var current = <String, dynamic>{..._accounts[key]!, ...updated};
        if (ui != null) {
          final currentUi = Map<String, dynamic>.from(
            (current['ui'] as Map?) ?? const <String, dynamic>{},
          );
          ui.forEach((k, value) {
            if (value == null) {
              currentUi.remove(k);
            } else {
              currentUi[k] = value;
            }
          });
          current['ui'] = currentUi;
        }
        _accounts[key] = current;
        if (_gatePost) {
          _gatePost = false;
          postEntered.complete();
          await releasePost.future;
        }
      }
      final body = utf8.encode(jsonEncode(_accounts[key]));
      return ResponseBody(
        Stream<Uint8List>.value(Uint8List.fromList(body)),
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );
    } finally {
      _active--;
    }
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _clone(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
