import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot_group.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../providers/hermes_messages.dart';
import '../providers/hermes_workspace.dart';
import '../widgets/hermes_bot_avatar.dart';
import '../widgets/hermes_message_icon.dart';
import 'hermes_bot_setup_page.dart';

class HermesGroupSetupPage extends ConsumerStatefulWidget {
  const HermesGroupSetupPage({super.key, this.group});
  final HermesBotGroup? group;
  @override
  ConsumerState<HermesGroupSetupPage> createState() =>
      _HermesGroupSetupPageState();
}

class _HermesGroupSetupPageState extends ConsumerState<HermesGroupSetupPage> {
  final _name = TextEditingController(), _purpose = TextEditingController();
  final _members = <String>{};
  String? _coordinator;
  bool _saving = false, _failed = false;
  late final Object? _service;
  late final String _roomId;
  final String _seedId = const Uuid().v4();
  final DateTime _createdAt = DateTime.now();
  @override
  void initState() {
    super.initState();
    _service = ref.read(hermesApiServiceProvider);
    _roomId = widget.group?.roomId ?? const Uuid().v4();
    _name.text = widget.group?.name ?? '';
    _purpose.text = widget.group?.purpose ?? '';
    _members.addAll(widget.group?.memberProfiles ?? []);
    _coordinator = widget.group?.coordinator ?? _members.firstOrNull;
  }

  @override
  void dispose() {
    _name.dispose();
    _purpose.dispose();
    super.dispose();
  }

  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      _members.length >= 2 &&
      _members.length <= 6 &&
      _members.contains(_coordinator);

  Future<void> _createBot() async {
    if (_saving || !identical(_service, ref.read(hermesApiServiceProvider))) {
      return;
    }
    final bot = await Navigator.of(context).push<HermesBot>(
      MaterialPageRoute(builder: (_) => const HermesBotSetupPage()),
    );
    if (!mounted ||
        bot == null ||
        !identical(_service, ref.read(hermesApiServiceProvider))) {
      return;
    }
    setState(() {
      if (_members.length < 6) _members.add(bot.name);
      _coordinator ??= _members.firstOrNull;
    });
  }

  Future<void> _save() async {
    if (_saving || !_valid) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    final l10n = AppLocalizations.of(context)!;
    final initial = HermesBotGroup(
      key: 'id:$_roomId',
      roomId: _roomId,
      name: _name.text.trim(),
      memberProfiles: _members.toList(),
      coordinator: _coordinator,
      purpose: _purpose.text.trim(),
      messages: [
        HermesGroupMessage(
          id: _seedId,
          text: _purpose.text.trim().isEmpty
              ? l10n.messagesGroupCreated
              : _purpose.text.trim(),
          at: _createdAt,
        ),
      ],
    );
    final previous = widget.group;
    final group = previous == null
        ? initial
        : previous.copyWith(
            name: _name.text.trim(),
            memberProfiles: _members.toList(),
            coordinator: _coordinator,
            clearCoordinator: _coordinator == null,
            purpose: _purpose.text.trim(),
            raw: {
              ...previous.raw,
              'members': [
                for (final profile in _members)
                  {'name': profile, 'handle': profile},
              ],
            },
          );
    try {
      final workspace = ref.read(hermesWorkspaceServiceProvider);
      if (workspace != null) {
        final unready = <String>[];
        for (final profile in _members) {
          if (await workspace.botProviderReady(profile) == false) {
            unready.add(profile);
          }
        }
        if (!mounted ||
            !identical(_service, ref.read(hermesApiServiceProvider))) {
          return;
        }
        if (unready.isNotEmpty) {
          AdaptiveSnackBar.show(
            context,
            message:
                'Sign in to ${unready.join(', ')} in Hermes before starting the group.',
          );
          return;
        }
      }
      final saved = await ref
          .read(hermesBotGroupsProvider.notifier)
          .save(group);
      if (mounted && identical(_service, ref.read(hermesApiServiceProvider))) {
        Navigator.of(context).pop(saved);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!,
        roster = ref.watch(hermesMessagesBotsProvider);
    final bots = roster.asData?.value ?? <HermesBot>[];
    final coordinator =
        bots.any(
          (bot) => bot.name == _coordinator && _members.contains(bot.name),
        )
        ? _coordinator
        : null;
    final same = identical(_service, ref.watch(hermesApiServiceProvider));
    return PopScope(
      canPop: !_saving,
      child: AdaptiveScaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
                child: Row(
                  children: [
                    CompactIconAction(
                      tooltip: l10n.back,
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(),
                      icon: const Icon(HermesMessageIcons.back),
                    ),
                    Expanded(
                      child: Text(
                        widget.group == null
                            ? l10n.messagesNewGroup
                            : l10n.messagesGroupSettings,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  children: [
                    TextField(
                      key: const ValueKey('group-setup-name'),
                      controller: _name,
                      maxLength: 64,
                      enabled: !_saving,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: l10n.messagesGroupName,
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      l10n.messagesParticipants,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (roster.isLoading)
                      const Center(child: AdaptiveProgressIndicator()),
                    if (roster.hasError)
                      TextButton(
                        onPressed: () =>
                            ref.invalidate(hermesMessagesBotsProvider),
                        child: Text(l10n.retry),
                      ),
                    for (final bot in bots)
                      CheckboxListTile(
                        key: ValueKey('group-member-${bot.name}'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        secondary: HermesBotAvatar(
                          size: 32,
                          label: bot.title,
                          shape: bot.avatarShape,
                          color: bot.avatarColor,
                        ),
                        value: _members.contains(bot.name),
                        title: Text(bot.title),
                        subtitle: bot.description == null
                            ? null
                            : Text(
                                bot.description!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        onChanged:
                            _saving ||
                                (!_members.contains(bot.name) &&
                                    _members.length >= 6)
                            ? null
                            : (selected) => setState(() {
                                if (selected == true) {
                                  _members.add(bot.name);
                                } else {
                                  _members.remove(bot.name);
                                }
                                _coordinator ??= _members.firstOrNull;
                                if (!_members.contains(_coordinator)) {
                                  _coordinator = _members.firstOrNull;
                                }
                              }),
                      ),
                    if (!_saving && same)
                      CompactContentRow(
                        key: const ValueKey('group-setup-create-bot'),
                        leading: const Icon(HermesMessageIcons.add, size: 22),
                        title: Text(l10n.messagesCreateBot),
                        onTap: _createBot,
                      ),
                    Text(
                      l10n.messagesChooseMembers,
                      style: TextStyle(
                        color: context.conduitTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 20),
                    DropdownButtonFormField<String>(
                      key: ValueKey(coordinator),
                      initialValue: coordinator,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: l10n.messagesCoordinator,
                      ),
                      items: [
                        for (final bot in bots.where(
                          (b) => _members.contains(b.name),
                        ))
                          DropdownMenuItem(
                            value: bot.name,
                            child: Text(
                              bot.title,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) => setState(() => _coordinator = value),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 20),
                      child: Text(
                        l10n.messagesCoordinatorHelp,
                        style: TextStyle(
                          color: context.conduitTheme.textSecondary,
                        ),
                      ),
                    ),
                    TextField(
                      key: const ValueKey('group-setup-purpose'),
                      controller: _purpose,
                      enabled: !_saving,
                      minLines: 1,
                      maxLines: 6,
                      maxLength: 5000,
                      decoration: InputDecoration(
                        labelText: l10n.messagesGroupPurpose,
                        counterText: '',
                      ),
                    ),
                    if (_failed || !same)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          l10n.messagesSaveFailed,
                          style: TextStyle(color: context.conduitTheme.error),
                        ),
                      ),
                    const SizedBox(height: 24),
                    FilledButton(
                      key: const ValueKey('group-setup-create'),
                      onPressed:
                          _valid &&
                              same &&
                              !_saving &&
                              !roster.isLoading &&
                              !roster.hasError &&
                              _members.every(
                                (name) => bots.any((b) => b.name == name),
                              )
                          ? _save
                          : null,
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: AdaptiveProgressIndicator(),
                            )
                          : Text(
                              widget.group == null
                                  ? l10n.messagesStartGroup
                                  : l10n.save,
                            ),
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
}
