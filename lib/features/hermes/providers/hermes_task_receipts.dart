import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_bot_chat.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class HermesTaskReceipt {
  const HermesTaskReceipt({
    required this.session,
    required this.outcome,
    this.bot,
    this.botAvatar,
  });
  final HermesSessionSummary session;
  final HermesChatOutcome outcome;
  final HermesBot? bot;
  final String? botAvatar;
}

/// In-memory outcomes for this connection only. A disappearing remote active
/// session is never interpreted as success; only a terminal transport event is.
class HermesTaskReceipts extends Notifier<List<HermesTaskReceipt>> {
  @override
  List<HermesTaskReceipt> build() {
    ref.watch(hermesApiServiceProvider);
    return const [];
  }

  void record(
    Conversation conversation,
    ChatMessage message,
    HermesChatOutcome outcome,
  ) {
    if (!isNativeHermesConversation(conversation)) return;
    final id =
        message.metadata?['hermesSessionId'] ??
        conversation.metadata['hermesSessionId'];
    if (id is! String || id.isEmpty) return;
    final profile = conversation.metadata['hermesBotProfile'];
    final presentation = chatHermesBotPresentation(conversation);
    final bot = profile is String && profile.isNotEmpty && presentation != null
        ? HermesBot(
            name: profile,
            title: presentation.title,
            hasAvatar: presentation.avatar != null,
            avatarShape: presentation.shape,
            avatarColor: presentation.color,
            avatarImageKind: presentation.imageKind,
          )
        : null;
    final receipt = HermesTaskReceipt(
      session: HermesSessionSummary(
        id: id,
        title: conversation.title,
        updatedAt: DateTime.now(),
      ),
      outcome: outcome,
      bot: bot,
      botAvatar: bot == null ? null : presentation?.avatar,
    );
    state = [
      receipt,
      ...state.where((row) => row.session.id != id),
    ].take(12).toList(growable: false);
  }
}

final hermesTaskReceiptsProvider =
    NotifierProvider<HermesTaskReceipts, List<HermesTaskReceipt>>(
      HermesTaskReceipts.new,
    );

/// The shell keeps the connection-scoped ledger alive across work areas.
final hermesMobileWorkObserverProvider = Provider<void>((ref) {
  ref.watch(hermesTaskReceiptsProvider);
});
