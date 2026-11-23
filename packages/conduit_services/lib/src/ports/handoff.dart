import 'package:conduit_core/features/chat/providers/chat_handoff_providers.dart';
import 'package:conduit_core/models/chat_handoff.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:riverpod/riverpod.dart';

/// Who answers a server's `chat:handoff` for the daemon: the windows, once
/// the server attaches its handoff service.
abstract interface class HandoffBroker {
  /// Whether [chatId] is a chat the user is in: answering in a scope, or
  /// shown in a window.
  bool claims(String chatId);

  /// Asks the windows whether to carry on in a new chat with the model
  /// [modelName] ([modelId]), [prompt] in its message field; false when
  /// declined or nobody answers in time.
  Future<bool> confirm({
    required String chatId,
    required String modelId,
    required String modelName,
    required String prompt,
  });

  /// The user agreed and the coordinator lets the new chat open: the window
  /// that agreed opens it.
  void opened(String modelId, String prompt);

  /// The handoff is over, however it ended.
  void ended();
}

/// The core's handoff seam, bound before there is anyone to ask.
///
/// The core container is made before the daemon server attaches its
/// handoff service, and overrides are fixed when it is made, so the core
/// gets a coordinator that asks through this. Until a broker attaches, no
/// chat is claimed and every handoff is refused as the core's own rules say
/// (not the active chat).
final class DaemonHandoffPort {
  HandoffBroker? _target;

  void attach(HandoffBroker target) => _target = target;

  void detach() => _target = null;

  /// The handoffs being decided, newest last: [confirm] asks for the newest.
  final List<({String? chatId, String modelId, String prompt})> _contexts =
      <({String? chatId, String modelId, String prompt})>[];

  bool claims(String chatId) => _target?.claims(chatId) ?? false;

  Future<bool> confirm(String modelName) async {
    final target = _target;
    if (target == null || _contexts.isEmpty) return false;
    final context = _contexts.last;
    final chatId = context.chatId;
    if (chatId == null) return false;
    return target.confirm(
      chatId: chatId,
      modelId: context.modelId,
      modelName: modelName,
      prompt: context.prompt,
    );
  }

  void opened(Model model, String prompt) => _target?.opened(model.id, prompt);

  /// The coordinator the daemon's core uses.
  ChatHandoffCoordinator coordinator(Ref ref) =>
      _DaemonChatHandoffCoordinator(ref, this);
}

/// The core's [ChatHandoffCoordinator] with the daemon's answers: a chat is
/// the user's while a scope or a window has it, the windows are asked, and
/// the window that agreed opens the new chat.
final class _DaemonChatHandoffCoordinator extends ChatHandoffCoordinator {
  _DaemonChatHandoffCoordinator(Ref ref, this._port)
    : super(
        // A chat is claimed for the account in use when it was: after a
        // switch, a window still showing its id claims nothing.
        claimActiveChat: (chatId) {
          if (!_port.claims(chatId)) return null;
          final account = ref.read(openWebUiAuthSessionEpochProvider);
          return () =>
              identical(account, ref.read(openWebUiAuthSessionEpochProvider)) &&
              _port.claims(chatId);
        },
        findModel: (modelId) async {
          final listed = ref.read(modelsProvider).value ?? const <Model>[];
          final model = openWebUiHandoffModel(listed, modelId);
          final api = ref.read(apiServiceProvider);
          if (model != null || api == null) return model;
          // The picker's list leaves hidden models out, though a chat may
          // still use one, as the web client's `/?models=` link may.
          final all = await api.getModels(
            includeHidden: true,
            authSnapshot: api.captureAuthSnapshot(),
          );
          return openWebUiHandoffModel(all, modelId);
        },
        confirm: _port.confirm,
        open: _port.opened,
      );

  final DaemonHandoffPort _port;

  @override
  Future<Map<String, dynamic>> handle({
    required String? chatId,
    required String? messageId,
    required Object? data,
  }) async {
    final request = ChatHandoffRequest.tryParse(data);
    final context = (
      chatId: chatId,
      modelId: request?.modelId ?? '',
      prompt: request?.prompt ?? '',
    );
    _port._contexts.add(context);
    try {
      return await super.handle(
        chatId: chatId,
        messageId: messageId,
        data: data,
      );
    } finally {
      _port._contexts.remove(context);
      _port._target?.ended();
    }
  }
}
