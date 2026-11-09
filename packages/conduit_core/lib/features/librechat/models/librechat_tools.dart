import 'package:meta/meta.dart';

/// The tools a turn on an endpoint model asks for: LibreChat runs such a
/// turn as an ad-hoc agent with these (`ephemeralAgent`). A saved agent or
/// a model spec brings its own tools instead.
@immutable
final class LibreChatToolSelection {
  const LibreChatToolSelection({
    this.webSearch = false,
    this.codeInterpreter = false,
    this.fileSearch = false,
    this.mcpServers = const <String>[],
  });

  final bool webSearch;
  final bool codeInterpreter;
  final bool fileSearch;

  /// The names of the MCP servers whose tools the turn may call.
  final List<String> mcpServers;

  bool get isEmpty =>
      !webSearch && !codeInterpreter && !fileSearch && mcpServers.isEmpty;

  /// The `ephemeralAgent` body field, or null when no tool is on.
  Map<String, dynamic>? toEphemeralAgent() => isEmpty
      ? null
      : <String, dynamic>{
          'web_search': webSearch,
          'execute_code': codeInterpreter,
          'file_search': fileSearch,
          'mcp': mcpServers,
        };
}

/// What the user decided about one tool call a run paused on.
enum LibreChatToolDecision { approve, reject, edit, respond }

/// A run paused for the user (`PendingAction`): tools awaiting approval, or
/// questions the agent asked.
@immutable
final class LibreChatPendingAction {
  const LibreChatPendingAction(this.raw);

  final Map<String, dynamic> raw;

  String? get actionId => _text(raw['actionId']);
  String? get conversationId => _text(raw['conversationId']);

  static String? _text(Object? value) => value is String ? value : null;

  Map<String, dynamic> get _payload => raw['payload'] is Map
      ? Map<String, dynamic>.from(raw['payload'] as Map)
      : const {};

  bool get isToolApproval => _payload['type'] == 'tool_approval';
  bool get isQuestion => _payload['type'] == 'ask_user_question';

  /// The tool calls awaiting a decision, with the decisions each allows.
  List<LibreChatToolRequest> get toolRequests {
    final requests = _payload['action_requests'];
    final configs = _payload['review_configs'];
    final allowed = <String, List<LibreChatToolDecision>>{
      if (configs is List)
        for (final config in configs)
          // One without a list of decisions offers the default ones.
          if (config is Map &&
              config['tool_call_id'] is String &&
              config['allowed_decisions'] is List)
            config['tool_call_id'] as String: [
              for (final name in config['allowed_decisions'] as List)
                ?LibreChatToolDecision.values
                    .where((decision) => decision.name == name)
                    .firstOrNull,
            ],
    };
    return [
      if (requests is List)
        for (final request in requests)
          if (request is Map && request['tool_call_id'] is String)
            LibreChatToolRequest(
              toolCallId: request['tool_call_id'] as String,
              name: request['name'] is String ? request['name'] as String : '',
              arguments: request['arguments'],
              description: _text(request['description']),
              allowed:
                  allowed[request['tool_call_id']] ??
                  const [
                    LibreChatToolDecision.approve,
                    LibreChatToolDecision.reject,
                  ],
            ),
    ];
  }

  /// The questions asked, each `{id, question, description?, options?,
  /// multiSelect?}`. A single question without an id answers under the
  /// tool call's id.
  List<Map<String, dynamic>> get questions {
    final batch = _payload['questions'];
    if (batch is List && batch.isNotEmpty) {
      return [
        for (final question in batch)
          if (question is Map) Map<String, dynamic>.from(question),
      ];
    }
    final single = _payload['question'];
    if (single is Map) {
      return [
        {
          ...Map<String, dynamic>.from(single),
          'id': _payload['tool_call_id'] ?? 'question',
        },
      ];
    }
    return const [];
  }

  /// The body of `POST /api/agents/chat/resume` with [decisions] for every
  /// paused tool call.
  ///
  /// [turn] is the body the paused turn was sent with: LibreChat resumes
  /// only with the same endpoint, agent and tool settings, which it checks
  /// against a fingerprint of the original request.
  Map<String, dynamic> resumeWithDecisions({
    required Map<String, LibreChatToolDecisionInput> decisions,
    required Map<String, dynamic> turn,
    int? generationCreatedAt,
  }) => <String, dynamic>{
    ..._turnSettings(turn),
    'decisions': [
      for (final entry in decisions.entries)
        <String, dynamic>{
          'tool_call_id': entry.key,
          'decision': entry.value.decision.name,
          'editedArguments': ?entry.value.editedArguments,
          'responseText': ?entry.value.responseText,
        },
    ],
    ..._identity(generationCreatedAt),
  };

  /// The body of `POST /api/agents/chat/resume` answering the questions,
  /// [answers] keyed by question id. A single question is answered as
  /// `answer`, a batch as `answers`, as LibreChat reads them.
  Map<String, dynamic> resumeWithAnswers({
    required Map<String, String> answers,
    required Map<String, dynamic> turn,
    int? generationCreatedAt,
  }) {
    final batch = _payload['questions'];
    return <String, dynamic>{
      ..._turnSettings(turn),
      if (batch is List && batch.isNotEmpty)
        'answers': answers
      else
        'answer': _singleAnswer(answers),
      ..._identity(generationCreatedAt),
    };
  }

  /// The answer to the one question asked, under its id; a lone answer
  /// under another key is taken as it. None at all is the caller's error,
  /// not a blank answer to resume the run with.
  String _singleAnswer(Map<String, String> answers) {
    final answer =
        answers[questions.firstOrNull?['id']] ??
        (answers.length == 1 ? answers.values.single : null);
    if (answer == null) {
      throw ArgumentError.value(
        answers,
        'answers',
        'No answer to the question',
      );
    }
    return answer;
  }

  static Map<String, dynamic> _turnSettings(Map<String, dynamic> turn) =>
      Map<String, dynamic>.from(turn)
        ..remove('text')
        ..remove('clientRequestId')
        ..remove('isRegenerate')
        ..remove('overrideParentMessageId');

  Map<String, dynamic> _identity(int? generationCreatedAt) => {
    'conversationId': ?conversationId,
    'actionId': ?actionId,
    // The generation's own start, which the server checks; the action's
    // `createdAt` is when it paused and would read as a replaced run.
    'generationCreatedAt': ?generationCreatedAt,
  };
}

/// One tool call awaiting the user's decision.
@immutable
final class LibreChatToolRequest {
  const LibreChatToolRequest({
    required this.toolCallId,
    required this.name,
    required this.allowed,
    this.arguments,
    this.description,
  });

  final String toolCallId;
  final String name;
  final Object? arguments;
  final String? description;
  final List<LibreChatToolDecision> allowed;
}

/// One decision, with what an edit or a response carries.
@immutable
final class LibreChatToolDecisionInput {
  const LibreChatToolDecisionInput(
    this.decision, {
    this.editedArguments,
    this.responseText,
  });

  final LibreChatToolDecision decision;

  /// The arguments to run with instead, for [LibreChatToolDecision.edit].
  final Map<String, dynamic>? editedArguments;

  /// What the tool "returns" instead of running, for
  /// [LibreChatToolDecision.respond].
  final String? responseText;
}
