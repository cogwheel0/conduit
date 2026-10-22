import 'hermes_run_event.dart';

/// Transient presentation of a server-owned room turn. Never a durable message.
class HermesGroupLiveReply {
  const HermesGroupLiveReply({
    required this.id,
    required this.profile,
    required this.text,
    this.reasoning = '',
    this.tools = const [],
    this.complete = false,
  });

  final String id, profile, text, reasoning;
  final List<HermesToolProgress> tools;
  final bool complete;
}
