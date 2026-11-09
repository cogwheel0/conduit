import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter/widgets.dart';

// Synthetic retained-heap comparison. Only connects to this process's VM service.
List<ChatMessage> _messages = [];
var _cache = MarkdownPrewarmEligibilityCache();
var _retained = Expando<String>();

void _create(bool padded) {
  _cache = MarkdownPrewarmEligibilityCache();
  _retained = Expando<String>();
  final body = List.filled(65536, 'Synthetic text. ').join();
  final pad = padded ? '  ' : '';
  _messages = List.generate(
    64,
    (i) => ChatMessage(
      id: 'synthetic-$i',
      role: 'assistant',
      content: '$pad$i $body End.$pad',
      timestamp: DateTime(2026),
    ),
  );
}

int _warm(bool retainStrings) {
  var characters = 0;
  for (final message in _messages) {
    // Reproduce the earlier cache's retention rule with identical eligibility.
    final content = retainStrings
        ? (_retained[message] ??= (_cache.isEligible(message)
              ? message.content.trim()
              : ''))
        : (_cache.isEligible(message) ? message.content.trim() : '');
    characters += content.length;
  }
  return characters;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  final uri = (await Service.getInfo()).serverUri;
  if (uri == null) throw StateError('Run in profile mode with the VM service.');
  final socket = await WebSocket.connect(
    uri.replace(scheme: 'ws', path: '${uri.path}ws').toString(),
  );
  final pending = <String, Completer<Map<String, dynamic>>>{};
  var serial = 0;
  socket.listen((raw) {
    final reply = jsonDecode(raw as String) as Map<String, dynamic>;
    final waiter = pending.remove(reply['id']);
    if (waiter == null) return;
    if (reply.containsKey('error')) {
      waiter.completeError(StateError('VM request failed: ${reply['error']}'));
    } else {
      waiter.complete(reply['result'] as Map<String, dynamic>);
    }
  });
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) {
    final id = '${serial++}';
    final waiter = Completer<Map<String, dynamic>>();
    pending[id] = waiter;
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return waiter.future.timeout(const Duration(seconds: 10));
  }

  try {
    final vm = await request('getVM');
    final isolate = (vm['isolates'] as List).firstWhere(
      (i) => i['name'] == 'main',
    );
    for (final retainStrings in [true, false]) {
      for (final padded in [false, true]) {
        for (var run = 0; run < 3; run++) {
          final phases = <String, int>{};
          var characters = 0;
          for (final stage in ['create', 'warm', 'release']) {
            if (stage == 'create') _create(padded);
            if (stage == 'warm') characters = _warm(retainStrings);
            if (stage == 'release') _messages = [];
            final params = {'isolateId': isolate['id'], 'gc': true};
            await request('getAllocationProfile', params);
            final profile = await request('getAllocationProfile', params);
            phases[stage] = profile['memoryUsage']['heapUsage'] as int;
          }
          debugPrint(
            'PREWARM_MEMORY_RESULT ${jsonEncode({'retainStrings': retainStrings, 'padded': padded, 'run': run, 'characters': characters, 'heapBytes': phases})}',
          );
        }
      }
    }
    debugPrint('PREWARM_MEMORY_DONE');
  } finally {
    await socket.close();
  }
}
