import 'dart:async';
import 'dart:io';

import 'package:conduit/core/network/conduit_user_agent.dart';
import 'package:conduit/features/terminal/models/terminal_models.dart';
import 'package:conduit/features/terminal/providers/terminal_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('terminal connector brands only system-server handshakes', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final container = ProviderContainer();
      try {
        final systemUserAgents = await _captureHandshakeUserAgents(
          container,
          TerminalServerKind.system,
        );
        final directUserAgents = await _captureHandshakeUserAgents(
          container,
          TerminalServerKind.direct,
        );

        expect(systemUserAgents, [ConduitUserAgent.value]);
        expect(
          directUserAgents.where((value) => value.contains('Conduit')),
          isEmpty,
        );
      } finally {
        container.dispose();
      }
    }, _RealHttpOverrides());
  });
}

Future<List<String>> _captureHandshakeUserAgents(
  ProviderContainer container,
  TerminalServerKind kind,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final captured = Completer<List<String>>();
  server.listen((request) async {
    if (!captured.isCompleted) {
      captured.complete(
        request.headers[HttpHeaders.userAgentHeader] ?? const <String>[],
      );
    }
    request.response.statusCode = HttpStatus.badRequest;
    await request.response.close();
  });

  try {
    final channel = container.read(terminalChannelConnectorProvider)(
      Uri.parse('ws://${server.address.address}:${server.port}/terminal'),
      kind: kind,
    );
    final readyFinished = _ignoreFailure(channel.ready);
    final streamFinished = _ignoreFailure(channel.stream.drain<void>());

    final userAgents = await captured.future.timeout(
      const Duration(seconds: 5),
    );
    await Future.wait([
      readyFinished,
      streamFinished,
    ]).timeout(const Duration(seconds: 5));
    return userAgents;
  } finally {
    await server.close(force: true);
  }
}

Future<void> _ignoreFailure(Future<void> future) async {
  try {
    await future;
  } catch (_) {}
}

class _RealHttpOverrides extends HttpOverrides {}
