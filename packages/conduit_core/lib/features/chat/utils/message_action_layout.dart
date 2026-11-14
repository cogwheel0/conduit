/// How a response's actions are laid out: those drawn inline in the footer,
/// in order, and those in its More menu.
typedef MessageActionLayout = ({List<String> inline, List<String> more});

/// The most actions the automatic layout draws inline.
const int kAutomaticInlineMessageActions = 3;

/// The setting a footer action follows: Retry is Regenerate on a failed
/// answer, and Stop Merging is Merge Responses while a merge runs.
String messageActionPreferenceId(String actionId) => switch (actionId) {
  'retry' => 'regenerate',
  'stop-merge' => 'merge',
  _ => actionId,
};

/// Actions the automatic layout never draws inline: Share, Delete and the
/// Hermes history actions.
bool messageActionIsOverflowOnly(String actionId) =>
    actionId == 'share' ||
    actionId == 'delete' ||
    actionId.startsWith('hermes-');

/// Splits [available] (a response's actions right now, by id, in the order
/// the footer offers them) into inline and More, as Settings › Chats ›
/// Message Actions says: [preferred] null is the automatic layout (the first
/// [kAutomaticInlineMessageActions] that are not overflow-only, the rest in
/// More, overflow-only ones last); otherwise exactly the actions [preferred]
/// names, in its order, inline, and every other one in More, in [available]'s
/// order.
MessageActionLayout messageActionLayout(
  List<String> available,
  List<String>? preferred,
) {
  if (preferred == null) {
    final candidates = [
      for (final id in available)
        if (!messageActionIsOverflowOnly(id)) id,
    ];
    return (
      inline: candidates.take(kAutomaticInlineMessageActions).toList(),
      more: [
        ...candidates.skip(kAutomaticInlineMessageActions),
        for (final id in available)
          if (messageActionIsOverflowOnly(id)) id,
      ],
    );
  }
  final chosen = preferred.toSet();
  return (
    inline: [
      for (final id in chosen)
        ...available.where((action) => messageActionPreferenceId(action) == id),
    ],
    more: [
      for (final id in available)
        if (!chosen.contains(messageActionPreferenceId(id))) id,
    ],
  );
}
