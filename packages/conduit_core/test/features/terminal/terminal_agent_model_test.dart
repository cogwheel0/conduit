import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/terminal/models/terminal_agent_model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// An agent as Open WebUI 0.13.3 lists it (`utils/agents/discovery.py`).
Map<String, dynamic> _agent(
  String terminal,
  String provider,
  String model, {
  String ownedBy = 'terminal',
}) => {
  'id':
      'agent:${Uri.encodeComponent(terminal)}:$provider:'
      '${Uri.encodeComponent(model)}',
  'name': '$provider/$model',
  'owned_by': ownedBy,
  'object': 'model',
  'agent': {'terminal_id': terminal, 'provider': provider, 'model': model},
  'info': {
    'params': {'model_controls': <String, dynamic>{}},
    'meta': {
      'capabilities': {'vision': true, 'file_upload': true},
    },
  },
};

class _Adapter implements HttpClientAdapter {
  _Adapter(this.body);

  final Object body;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    requests.add(options);
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiService _api(_Adapter adapter) {
  final service = ApiService(
    serverConfig: const ServerConfig(
      id: 'test',
      name: 'Test Server',
      url: 'http://localhost:9999',
    ),
    workerManager: WorkerManager(),
  );
  service.dio.httpClientAdapter = adapter;
  service.dio.interceptors.clear();
  return service;
}

void main() {
  group('parseTerminalAgentModelId', () {
    test('reads the terminal, agent and model, URL-decoded', () {
      check(
          parseTerminalAgentModelId('agent:build%3Abox:codex:openai%2Fgpt-5.1'),
        ).isNotNull()
        ..has((a) => a.terminalId, 'terminalId').equals('build:box')
        ..has((a) => a.provider, 'provider').equals('codex')
        ..has((a) => a.model, 'model').equals('openai/gpt-5.1');
    });

    test('is null for ids that are not an agent\'s', () {
      for (final id in [
        null,
        '',
        'gpt-5.1',
        'agent:',
        'agent:term',
        'agent:term:codex',
        'agent:term:codex:',
        'agent::codex:gpt',
        'agent:term::gpt',
        // Other backends' agents keep their own namespace.
        'librechat:agent:abc',
        'hermes:agent:default',
        // Not URL-decodable: a broken escape, and one that is not UTF-8.
        'agent:%E0%A4%A:codex:gpt',
        'agent:%FF:codex:gpt',
        'agent:term:codex:%C3',
      ]) {
        check(because: '$id', parseTerminalAgentModelId(id)).isNull();
      }
    });
  });

  group('terminalAgentModelFromJson', () {
    test('names the agent for the picker and says where it runs', () {
      final model = terminalAgentModelFromJson(
        _agent('t1', 'claude-code', 'sonnet'),
        terminalName: 'Build box',
      )!;
      check(model.name).equals('Claude Code · sonnet');
      check(terminalAgentPickerSubtitle(model)).equals('Build box');
      check(terminalAgentTerminalId(model)).equals('t1');
    });

    test('an agent Conduit has no name for keeps its own', () {
      final model = terminalAgentModelFromJson(_agent('t1', 'newagent', 'm'))!;
      check(model.name).equals('newagent · m');
      check(terminalAgentPickerSubtitle(model)).equals('newagent/m');
    });

    test('is null for an ordinary model', () {
      check(terminalAgentModelFromJson({'id': 'gpt-5.1', 'name': 'GPT-5.1'}))
          .isNull();
    });
  });

  group('getTerminalAgentModels', () {
    test('asks for the terminal and chat, and keeps only that terminal\'s '
        'agents', () async {
      final adapter = _Adapter({
        'data': [
          {'id': 'gpt-5.1', 'name': 'GPT-5.1', 'owned_by': 'openai'},
          _agent('t1', 'codex', 'gpt-5.1'),
          // 0.13.1 and 0.13.2 still said `agent`.
          _agent('t1', 'pi', 'default', ownedBy: 'agent'),
          _agent('t2', 'codex', 'gpt-5.1'),
          _agent('t1', 'codex', 'gpt-5.1'),
        ],
      });
      final agents = await _api(adapter).getTerminalAgentModels(
        terminalId: 't1',
        chatId: 'chat-1',
        terminalName: 'Build box',
      );

      final request = adapter.requests.single;
      check(request.path).equals('/api/models');
      check(request.queryParameters)
          .deepEquals({'terminal_id': 't1', 'chat_id': 'chat-1'});
      check(agents.map((m) => m.name).toList())
          .deepEquals(['Codex · gpt-5.1', 'Pi · default']);
    });

    test('a scheduled task asks the task route with its folder', () async {
      final adapter = _Adapter([_agent('t1', 'codex', 'gpt-5.1')]);
      final agents = await _api(adapter).getTerminalAgentModels(
        terminalId: 't1',
        cwd: ' /work ',
        forAutomation: true,
        automationId: 'task-1',
      );

      final request = adapter.requests.single;
      check(request.path).equals('/api/v1/automations/models');
      check(request.queryParameters).deepEquals({
        'terminal_id': 't1',
        'cwd': '/work',
        'automation_id': 'task-1',
      });
      check(agents).length.equals(1);
    });
  });
}
