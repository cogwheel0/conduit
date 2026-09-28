import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/chat_providers.dart';

/// Every branch of a conversation, as a tree.
///
/// A run of single replies is drawn as one flat list; only where a message
/// has several replies -- an edit, a regeneration -- does it indent, one
/// branch per reply. So a long conversation with one fork reads as a list
/// with one fork, not a staircase. The path the transcript shows is
/// highlighted, and choosing any message makes its branch the one shown.
class ConversationMap extends StatelessComponent {
  const ConversationMap({required this.tree, super.key});

  final ChatTree tree;

  @override
  Component build(BuildContext context) {
    final byParent = <String?, List<ChatTreeNode>>{};
    final ids = {for (final node in tree.nodes) node.id};
    for (final node in tree.nodes) {
      // An orphan -- its parent pruned -- starts a tree of its own.
      final parent = ids.contains(node.parentId) ? node.parentId : null;
      (byParent[parent] ??= <ChatTreeNode>[]).add(node);
    }
    for (final siblings in byParent.values) {
      siblings.sort((x, y) => x.timestampMs.compareTo(y.timestampMs));
    }

    final onPath = <String>{};
    final byId = {for (final node in tree.nodes) node.id: node};
    String? id = tree.currentId;
    while (id != null && onPath.add(id)) {
      id = byId[id]?.parentId;
    }

    Component row(ChatTreeNode node) {
      final current = node.id == tree.currentId;
      return li([
        button(
          [
            span(
              classes: 'w-4 shrink-0 font-mono text-[10px] opacity-60',
              attributes: const <String, String>{'aria-hidden': 'true'},
              [Component.text(node.role == 'user' ? 'Q' : 'A')],
            ),
            span(classes: 'min-w-0 flex-1 truncate', [
              Component.text(node.preview.isEmpty ? '…' : node.preview),
            ]),
          ],
          classes:
              'flex w-full items-center gap-1.5 rounded-lg px-1.5 py-1 '
              'text-left text-ui-sm '
              '${onPath.contains(node.id) ? 'bg-selected text-foreground' : 'text-foreground-subtle hover:bg-hover'}',
          type: ButtonType.button,
          attributes: <String, String>{
            if (current) 'aria-current': 'true',
            'title': node.preview,
          },
          onClick: () => unawaited(
            context.read(chatActionsProvider).setCurrent(tree.chatId, node.id),
          ),
        ),
      ]);
    }

    List<Component> chain(ChatTreeNode start) {
      final rows = <Component>[];
      ChatTreeNode node = start;
      while (true) {
        rows.add(row(node));
        final replies = byParent[node.id] ?? const <ChatTreeNode>[];
        if (replies.length == 1) {
          node = replies.single;
          continue;
        }
        if (replies.length > 1) {
          rows.add(
            li([
              ul(classes: 'ml-2 space-y-2 border-l border-border pl-2', [
                for (final reply in replies)
                  li([ul(classes: 'space-y-0.5', chain(reply))]),
              ]),
            ]),
          );
        }
        return rows;
      }
    }

    return section(
      attributes: <String, String>{'aria-label': t.desktop.desktopOverview},
      [
        h3(classes: 'text-ui-base font-semibold', [
          Component.text(t.desktop.desktopOverview),
        ]),
        p(classes: 'mb-2 text-ui-sm text-foreground-subtle', [
          Component.text(t.desktop.desktopOverviewHint),
        ]),
        ul(classes: 'space-y-0.5', [
          for (final root in byParent[null] ?? const <ChatTreeNode>[])
            ...chain(root),
        ]),
      ],
    );
  }
}
