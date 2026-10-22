import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot_group.dart';

import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../providers/hermes_messages.dart';
import '../providers/hermes_workspace.dart';
import '../widgets/hermes_bot_avatar.dart';
import '../widgets/hermes_file_explorer.dart';
import '../widgets/hermes_message_icon.dart';
import '../widgets/hermes_conversation_actions.dart';
import 'hermes_bot_workspace_page.dart';
import 'hermes_group_setup_page.dart';

class HermesGroupWorkspacePage extends ConsumerStatefulWidget {
  const HermesGroupWorkspacePage({super.key, required this.group});
  final HermesBotGroup group;
  @override
  ConsumerState<HermesGroupWorkspacePage> createState() =>
      _GroupWorkspaceState();
}

class _GroupWorkspaceState extends ConsumerState<HermesGroupWorkspacePage> {
  late HermesBotGroup _group = widget.group;
  bool _files = false, _saving = false;
  late final _service = ref.read(hermesWorkspaceServiceProvider);
  Future<bool> _save(HermesBotGroup group) async {
    if (_saving) return false;
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(hermesBotGroupsProvider.notifier)
          .save(group);
      if (mounted &&
          identical(_service, ref.read(hermesWorkspaceServiceProvider))) {
        setState(() => _group = saved);
        return true;
      }
      return false;
    } catch (_) {
      if (mounted) {
        AdaptiveSnackBar.show(
          context,
          message: 'Could not save the group. Refresh and try again.',
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _identity() async {
    await showCompactConfigurationSheet<Map<String, dynamic>>(
      context,
      (_) => HermesIdentityEditor(
        bot: HermesBot(
          name: 'group',
          title: _group.name,
          icon: _group.icon,
          avatarColor: _group.color,
        ),
        description: _group.purpose,
        onSave: (data) {
          final meta = data['ui_meta']['hermes-bots'] as Map;
          return _save(
            _group.copyWith(
              name: meta['title'],
              purpose: data['description'],
              color: meta['color'],
              icon: meta['conduitIcon'],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bots =
        ref.watch(hermesMessagesBotsProvider).asData?.value ??
        const <HermesBot>[];
    return PopScope(
      canPop: !_saving,
      onPopInvokedWithResult: (didPop, _) {},
      child: AdaptiveScaffold(
        body: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  CompactIconAction(
                    tooltip: 'Back',
                    icon: const Icon(HermesMessageIcons.back),
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(_group),
                  ),
                  const Spacer(),
                  Semantics(
                    label: 'Edit group',
                    button: true,
                    child: InkWell(
                      onTap: _saving ? null : _identity,
                      child: SizedBox(
                        width: 64,
                        height: 64,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            HermesBotAvatar(
                              size: 48,
                              label: _group.name,
                              shape: 'squircle',
                              color: _group.color,
                              icon: _group.icon,
                            ),
                            const Positioned(
                              bottom: 2,
                              right: 2,
                              child: Icon(HermesMessageIcons.edit, size: 16),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(width: 48),
                ],
              ),
              Row(
                children: [
                  for (final files in [false, true])
                    Expanded(
                      child: Semantics(
                        selected: _files == files,
                        child: TextButton(
                          onPressed: () => setState(() => _files = files),
                          child: Text(files ? 'Files' : 'Members'),
                        ),
                      ),
                    ),
                ],
              ),
              Expanded(
                child: _files
                    ? _sharedFiles()
                    : ListView(
                        padding: const EdgeInsets.all(20),
                        children: [
                          for (final profile in _group.memberProfiles)
                            Builder(
                              builder: (context) {
                                final bot = bots
                                    .where((b) => b.name == profile)
                                    .firstOrNull;
                                return CompactContentRow(
                                  leading: HermesBotAvatar(
                                    size: 40,
                                    label: bot?.title ?? profile,
                                    shape: bot?.avatarShape ?? 'squircle',
                                    color: bot?.avatarColor ?? '#8b5cf6',
                                    icon: bot?.icon,
                                  ),
                                  title: Text(bot?.title ?? profile),
                                  subtitle: _group.coordinator == profile
                                      ? const Text('Coordinator')
                                      : null,
                                  trailing: CompactPopupMenu<String>(
                                    tooltip: 'Member actions',
                                    icon: const Icon(HermesMessageIcons.more),
                                    choices: [
                                      if (bot != null)
                                        const CompactMenuChoice(
                                          'open',
                                          'Open bot',
                                        ),
                                      if (_group.coordinator != profile)
                                        const CompactMenuChoice(
                                          'coordinator',
                                          'Make coordinator',
                                        ),
                                      const CompactMenuChoice(
                                        'compress',
                                        'Compress context',
                                      ),
                                      if (_group.memberProfiles.length > 2 &&
                                          _group.coordinator != profile)
                                        const CompactMenuChoice(
                                          'remove',
                                          'Remove',
                                        ),
                                    ],
                                    onSelected: (action) async {
                                      if (action == 'open' && bot != null) {
                                        await openHermesBotWorkspace(
                                          context,
                                          bot,
                                        );
                                      } else if (action == 'coordinator') {
                                        await _save(
                                          _group.copyWith(coordinator: profile),
                                        );
                                      } else if (action == 'remove') {
                                        await _save(
                                          _group.copyWith(
                                            memberProfiles: _group
                                                .memberProfiles
                                                .where((p) => p != profile)
                                                .toList(),
                                            raw: {
                                              ..._group.raw,
                                              'members': [
                                                for (final p
                                                    in _group.memberProfiles)
                                                  if (p != profile)
                                                    {'name': p, 'handle': p},
                                              ],
                                            },
                                          ),
                                        );
                                      } else if (action == 'compress' &&
                                          _group.memberSessions[profile] !=
                                              null &&
                                          _service != null) {
                                        try {
                                          await _service.compressBotSession(
                                            profile,
                                            _group.memberSessions[profile]!,
                                          );
                                        } catch (_) {
                                          if (context.mounted) {
                                            AdaptiveSnackBar.show(
                                              context,
                                              message: 'Could not compress this member’s context.',
                                            );
                                          }
                                        }
                                      }
                                    },
                                  ),
                                  onTap: bot == null
                                      ? () {}
                                      : () => openHermesBotWorkspace(
                                          context,
                                          bot,
                                        ),
                                );
                              },
                            ),
                          if (_group.memberProfiles.length < 6)
                            TextButton.icon(
                              onPressed: _saving
                                  ? null
                                  : () async {
                                      final group = await Navigator.of(context)
                                          .push<HermesBotGroup>(
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  HermesGroupSetupPage(
                                                    group: _group,
                                                  ),
                                            ),
                                          );
                                      if (mounted && group != null) {
                                        setState(() => _group = group);
                                      }
                                    },
                              icon: const Icon(HermesMessageIcons.add),
                              label: const Text('Add members'),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sharedFiles() => Column(
    children: [
      CompactContentRow(
        title: Text(
          _group.sharedFolder == null
              ? 'Choose a shared folder'
              : 'Shared folder',
        ),
        subtitle: _group.sharedFolder == null
            ? null
            : Text(
                _group.sharedFolder!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        trailing: const Icon(HermesMessageIcons.edit, size: 18),
        onTap: _saving
            ? () {}
            : () async {
                final folder = await editHermesName(
                  context,
                  _group.sharedFolder ?? '',
                );
                if (folder == null || !mounted) return;
                if (!folder.startsWith('/')) {
                  AdaptiveSnackBar.show(
                    context,
                    message:
                        'Use an absolute folder path on the Hermes server.',
                  );
                  return;
                }
                await _save(_group.copyWith(sharedFolder: folder));
              },
      ),
      if (_group.sharedFolder != null)
        Expanded(
          child: HermesScopedFilesArea(
            root: _group.sharedFolder!,
            profile: 'group:${_group.identity}',
            readOnly: true,
            composerTarget: 'group:${_group.identity}',
          ),
        )
      else
        const Expanded(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Choose a folder to browse shared files. Each bot keeps its own SOUL and memory.',
              ),
            ),
          ),
        ),
    ],
  );
}
