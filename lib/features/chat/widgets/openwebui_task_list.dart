import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';

/// Open WebUI's checklist is chat state, not part of an assistant's answer.
class OpenWebUiTaskList extends ConsumerWidget {
  const OpenWebUiTaskList({super.key, this.keyboardVisible = false});

  final bool keyboardVisible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Leave the resized viewport to the composer while the keyboard is open.
    // The checklist returns when editing is finished.
    if (keyboardVisible) {
      return const SizedBox.shrink();
    }
    final raw = ref.watch(
      activeConversationProvider.select(
        (chat) => chat?.metadata['openwebui_tasks'],
      ),
    );
    final tasks = raw is List
        ? raw
              .whereType<Map>()
              .where((task) => task['content'] is String)
              .toList()
        : const <Map>[];
    if (tasks.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final completed = tasks
        .where((task) => task['status'] == 'completed')
        .length;
    return ExpansionTile(
      key: ValueKey(
        ref.watch(activeConversationProvider.select((chat) => chat?.id)),
      ),
      title: Text(l10n.chatTaskProgress(completed, tasks.length)),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final task in tasks)
                  ListTile(
                    dense: true,
                    leading: Icon(switch (task['status']) {
                      'completed' => Icons.check_circle_outline,
                      'cancelled' => Icons.cancel_outlined,
                      'in_progress' => Icons.timelapse,
                      _ => Icons.radio_button_unchecked,
                    }),
                    title: Text(task['content'] as String),
                    subtitle: Text(switch (task['status']) {
                      'completed' => l10n.chatTaskCompleted,
                      'cancelled' => l10n.chatTaskCancelled,
                      'in_progress' => l10n.chatTaskInProgress,
                      _ => l10n.chatTaskPending,
                    }),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
