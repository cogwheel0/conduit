import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot_group.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';

import '../../../l10n/app_localizations.dart';

import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../providers/hermes_workspace.dart';
import '../providers/hermes_messages.dart';
import '../views/hermes_bot_workspace_page.dart';
import '../views/hermes_bot_setup_page.dart';
import '../views/hermes_group_setup_page.dart';
import 'hermes_message_icon.dart';
import 'hermes_session_tile.dart' show openHermesSession;

Future<String?> editHermesName(
  BuildContext context,
  String name, {
  String label = 'Name',
  int maxLength = 64,
  Future<String> Function()? suggestName,
  bool Function()? isCurrent,
}) => showCompactConfigurationSheet<String>(
  context,
  (_) => _NameEditor(
    name: name,
    label: label,
    maxLength: maxLength,
    suggestName: suggestName,
    isCurrent: isCurrent,
  ),
);
Future<bool> confirmHermesRemoval(
  BuildContext context,
  String title,
  String consequence, {
  String confirmText = 'Delete',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(consequence),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmText),
          ),
        ],
      ),
    ) ??
    false;

class HermesChatActions extends ConsumerWidget {
  const HermesChatActions({super.key, required this.session, this.menuKey});
  final HermesSessionSummary session;
  final GlobalKey<PopupMenuButtonState<String>>? menuKey;
  @override
  Widget build(BuildContext context, WidgetRef ref) => CompactPopupMenu<String>(
    menuKey: menuKey,
    tooltip: 'Conversation actions',
    icon: const Icon(HermesMessageIcons.more),
    choices: [
      const CompactMenuChoice('rename', 'Rename'),
      const CompactMenuChoice('branch', 'Branch'),
      CompactMenuChoice('archive', session.archived ? 'Unarchive' : 'Archive'),
      const CompactMenuChoice('delete', 'Delete'),
    ],
    onSelected: (action) async {
      final service = ref.read(hermesApiServiceProvider),
          workspace = ref.read(hermesWorkspaceServiceProvider);
      if (service == null) return;
      try {
        switch (action) {
          case 'rename':
            final config = ref.read(hermesConfigProvider.notifier);
            final admission = config.captureSessionActionAdmission();
            if (admission == null) return;
            bool current() =>
                context.mounted &&
                config.sessionActionAdmissionIsCurrent(admission) &&
                identical(service, ref.read(hermesApiServiceProvider));
            final title = await editHermesName(
              context,
              session.title,
              maxLength: 120,
              suggestName: service is HermesDesktopApiService
                  ? () => service.suggestSessionTitle(session.id)
                  : null,
              isCurrent: current,
            );
            if (title == null || !current()) return;
            await ref
                .read(hermesSessionsProvider.notifier)
                .rename(session.id, title);
          case 'branch':
            final id = await service.forkSession(session.id);
            if (context.mounted &&
                identical(service, ref.read(hermesApiServiceProvider))) {
              await openHermesSession(
                context,
                ref,
                HermesSessionSummary(
                  id: id,
                  title: '${session.title} · Branch',
                ),
              );
            }
          case 'archive':
            if (workspace == null) {
              throw UnsupportedError('Archive unavailable');
            }
            await workspace.archiveChat(session.id, !session.archived);
          case 'delete':
            if (!await confirmHermesRemoval(
                  context,
                  'Delete chat?',
                  'This permanently removes “${session.title}” and its messages.',
                ) ||
                !context.mounted ||
                !identical(service, ref.read(hermesApiServiceProvider))) {
              return;
            }
            await service.deleteSession(session.id);
        }
        if (context.mounted) {
          ref.invalidate(hermesSessionsProvider);
          ref.invalidate(hermesArchivedChatsProvider);
        }
      } catch (_) {
        if (context.mounted) {
          AdaptiveSnackBar.show(
            context,
            message: 'Could not update the conversation.',
          );
        }
      }
    },
  );
}

class HermesBotActions extends ConsumerWidget {
  const HermesBotActions({super.key, required this.row});
  final HermesBotConversation row;
  @override
  Widget build(BuildContext context, WidgetRef ref) => CompactPopupMenu<String>(
    tooltip: 'Bot actions',
    icon: const Icon(HermesMessageIcons.more),
    choices: [
      const CompactMenuChoice('settings', 'Open bot'),
      const CompactMenuChoice('compress', 'Compress context'),
      const CompactMenuChoice('duplicate', 'Duplicate'),
      CompactMenuChoice('hide', row.bot.hidden ? 'Unhide' : 'Hide'),
      if (row.bot.name != 'default')
        const CompactMenuChoice('delete', 'Delete'),
    ],
    onSelected: (action) async {
      final service = ref.read(hermesWorkspaceServiceProvider);
      if (service == null) return;
      try {
        switch (action) {
          case 'settings':
            await openHermesBotWorkspace(context, row.bot);
          case 'compress':
            final id = row.session?.id ?? row.bot.chatSessionId;
            if (id == null) return;
            await service.compressBotSession(row.bot.name, id);
            if (context.mounted) {
              AdaptiveSnackBar.show(
                context,
                message: 'Working context compressed. Your bot’s memory is preserved.',
              );
            }
          case 'duplicate':
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => HermesBotSetupPage(cloneFrom: row.bot.name),
              ),
            );
          case 'hide':
            await service.setBotHidden(row.bot, !row.bot.hidden);
          case 'delete':
            final groups = await ref.read(hermesBotGroupsProvider.future);
            if (!context.mounted ||
                !identical(service, ref.read(hermesWorkspaceServiceProvider))) {
              return;
            }
            if (groups.any((g) => g.memberProfiles.contains(row.bot.name))) {
              AdaptiveSnackBar.show(
                context,
                message: 'Remove this bot from its groups before deleting it.',
              );
              return;
            }
            if (!await confirmHermesRemoval(
                  context,
                  'Delete ${row.bot.title}?',
                  'This removes the bot’s profile, SOUL, memory, and conversations.',
                ) ||
                !context.mounted ||
                !identical(service, ref.read(hermesWorkspaceServiceProvider))) {
              return;
            }
            await service.deleteBot(row.bot.name);
        }
        if (context.mounted) refreshHermesBot(ref, row.bot.name);
      } catch (_) {
        if (context.mounted) {
          AdaptiveSnackBar.show(context, message: 'Could not update this bot.');
        }
      }
    },
  );
}

class HermesGroupActions extends ConsumerWidget {
  const HermesGroupActions({super.key, required this.group});
  final HermesBotGroup group;
  @override
  Widget build(BuildContext context, WidgetRef ref) => CompactPopupMenu<String>(
    tooltip: 'Group actions',
    icon: const Icon(HermesMessageIcons.more),
    choices: const [
      CompactMenuChoice('settings', 'Members'),
      CompactMenuChoice('rename', 'Rename'),
      CompactMenuChoice('delete', 'Disband group'),
    ],
    onSelected: (action) async {
      if (action == 'settings') {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => HermesGroupSetupPage(group: group)),
        );
        return;
      }
      final service = ref.read(hermesWorkspaceServiceProvider);
      if (action == 'rename') {
        final name = await editHermesName(context, group.name);
        if (name == null || !context.mounted) return;
        try {
          await ref
              .read(hermesBotGroupsProvider.notifier)
              .save(group.copyWith(name: name));
        } catch (_) {
          if (context.mounted) {
            AdaptiveSnackBar.show(
              context,
              message: 'Could not rename the group.',
            );
          }
        }
      } else if (service != null &&
          await confirmHermesRemoval(
            context,
            'Disband group?',
            'The group will be removed. Its bots and their direct conversations remain.',
          ) &&
          context.mounted &&
          identical(service, ref.read(hermesWorkspaceServiceProvider))) {
        try {
          await ref.read(hermesBotGroupsProvider.notifier).remove(group);
          if (context.mounted) ref.invalidate(hermesBotGroupsProvider);
        } catch (_) {
          if (context.mounted) {
            AdaptiveSnackBar.show(
              context,
              message: 'Could not disband this group.',
            );
          }
        }
      }
    },
  );
}

class _NameEditor extends StatefulWidget {
  const _NameEditor({
    required this.name,
    required this.label,
    required this.maxLength,
    this.suggestName,
    this.isCurrent,
  });
  final String name, label;
  final int maxLength;
  final Future<String> Function()? suggestName;
  final bool Function()? isCurrent;
  @override
  State<_NameEditor> createState() => _NameEditorState();
}

class _NameEditorState extends State<_NameEditor> {
  late final _name = TextEditingController(text: widget.name);
  bool _suggesting = false;
  int _draftRevision = 0;
  String? _error;

  Future<void> _suggest() async {
    if (_suggesting || widget.isCurrent?.call() == false) return;
    final revision = _draftRevision;
    setState(() {
      _suggesting = true;
      _error = null;
    });
    try {
      final title = await widget.suggestName!();
      if (!mounted || widget.isCurrent?.call() == false) return;
      if (revision == _draftRevision) {
        _name.value = TextEditingValue(
          text: title,
          selection: TextSelection.collapsed(offset: title.length),
        );
      }
    } catch (_) {
      if (mounted && widget.isCurrent?.call() != false) {
        setState(
          () =>
              _error = AppLocalizations.of(context)!.hermesSessionRenameFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _suggesting = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        8,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: widget.maxLength,
            onChanged: (_) => setState(() {
              _draftRevision++;
              _error = null;
            }),
            decoration: InputDecoration(
              labelText: widget.label,
              counterText: '',
              errorText: _error,
            ),
          ),
          const SizedBox(height: 16),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            overflowAlignment: OverflowBarAlignment.end,
            spacing: 8,
            overflowSpacing: 4,
            children: [
              if (widget.suggestName != null)
                TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _suggesting ? null : _suggest,
                  icon: _suggesting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_fix_high_outlined, size: 20),
                  label: Text(AppLocalizations.of(context)!.mobileAutoRename),
                ),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _name.text.trim().isEmpty
                    ? null
                    : () => Navigator.of(context).pop(_name.text.trim()),
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
