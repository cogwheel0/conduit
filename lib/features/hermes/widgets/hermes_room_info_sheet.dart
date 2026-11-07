import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/features/hermes/models/hermes_room.dart';
import 'package:conduit_core/features/hermes/providers/hermes_room_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_room_projection.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/themed_sheets.dart';
import 'hermes_room_avatars.dart';

/// What the info sheet asks the room page to do once it closes.
enum HermesRoomInfoAction { stop, disband }

/// The room's settings and bots. Saves purpose, notes and who answers in
/// place; Stop and Disband close the sheet and run on the room page.
Future<HermesRoomInfoAction?> showHermesRoomInfoSheet(
  BuildContext context, {
  required String roomId,
}) => ThemedSheets.showSurface<HermesRoomInfoAction>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  constraints: BoxConstraints(
    maxHeight: MediaQuery.sizeOf(context).height * 0.9,
  ),
  padding: EdgeInsets.zero,
  // The sheet draws its own handle so its list scrolls within its height.
  showHandle: false,
  builder: (_) => HermesRoomInfoSheet(roomId: roomId),
);

class HermesRoomInfoSheet extends ConsumerStatefulWidget {
  const HermesRoomInfoSheet({super.key, required this.roomId});

  final String roomId;

  @override
  ConsumerState<HermesRoomInfoSheet> createState() =>
      _HermesRoomInfoSheetState();
}

class _HermesRoomInfoSheetState extends ConsumerState<HermesRoomInfoSheet> {
  final _purpose = TextEditingController();
  final _notes = TextEditingController();
  HermesRoomContext? _saved;
  HermesRoomRouting? _routing;
  String? _lead;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _adopt(ref.read(hermesRoomProvider(widget.roomId)).context);
    _purpose.addListener(_changed);
    _notes.addListener(_changed);
    // Settings that arrive after the sheet opened fill it once.
    ref.listenManual(hermesRoomProvider(widget.roomId), (_, next) {
      if (_saved == null && next.context != null) {
        _adopt(next.context);
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _purpose.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _changed() => setState(() => _error = null);

  /// Shows [context] as saved; edits made since are replaced.
  void _adopt(HermesRoomContext? context) {
    _saved = context;
    _purpose.text = context?.purpose ?? '';
    _notes.text = context?.notes ?? '';
    _routing = context?.routing;
    _lead = context?.leadMemberId;
  }

  HermesRoomContext get _draft => HermesRoomContext(
    purpose: _purpose.text.trim(),
    notes: _notes.text.trim(),
    routing: _routing,
    leadMemberId: _routing == HermesRoomRouting.lead ? _lead : null,
  );

  bool get _dirty {
    final saved = _saved;
    final draft = _draft;
    return saved != null &&
        (draft.purpose != saved.purpose.trim() ||
            draft.notes != saved.notes.trim() ||
            draft.routing != saved.routing ||
            draft.leadMemberId != saved.leadMemberId);
  }

  bool get _notesTooLong =>
      hermesRoomNotesBytes(_notes.text) > kMaxHermesRoomNotesBytes;

  bool get _valid =>
      !_notesTooLong &&
      (_routing != HermesRoomRouting.lead || _lead != null);

  Future<void> _save() async {
    if (!_dirty || !_valid || _saving) return;
    final l10n = AppLocalizations.of(context)!;
    final draft = _draft;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(hermesRoomProvider(widget.roomId).notifier)
          .saveContext(draft);
      if (!mounted) return;
      _adopt(ref.read(hermesRoomProvider(widget.roomId)).context ?? draft);
      setState(() => _saving = false);
    } catch (error) {
      if (!mounted) return;
      final detail = hermesRoomRefusalDetail(error);
      setState(() {
        _saving = false;
        _error = detail == null
            ? l10n.hermesRoomActionFailed
            : l10n.hermesRoomRefused(detail);
      });
    }
  }

  Future<void> _rename(HermesRoom room) async {
    final l10n = AppLocalizations.of(context)!;
    final name = await ThemedDialogs.promptTextInput(
      context,
      title: l10n.hermesRoomRenameTitle,
      hintText: l10n.hermesRoomNameHint,
      initialValue: room.name,
      confirmText: l10n.rename,
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      await ref
          .read(hermesRoomProvider(widget.roomId).notifier)
          .rename(name.trim());
    } catch (error) {
      if (!mounted) return;
      final detail = hermesRoomRefusalDetail(error);
      setState(
        () => _error = detail == null
            ? l10n.hermesRoomActionFailed
            : l10n.hermesRoomRefused(detail),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final view = ref.watch(hermesRoomProvider(widget.roomId));
    final room = view.room;
    if (room == null) {
      return const Padding(
        padding: EdgeInsets.all(Spacing.xl),
        child: Center(child: AdaptiveProgressIndicator()),
      );
    }
    final statuses = hermesRoomMemberStatuses(
      view.events,
      room.members,
      view.driver?.memberActivity ?? const [],
      DateTime.now(),
    );
    final modes = view.driver?.routingModes;
    final routing = _routing;
    final offersAuto =
        routing == HermesRoomRouting.auto ||
        (modes?.contains(HermesRoomRouting.auto) ?? false);
    final label = AppTypography.bodySmallStyle.copyWith(
      color: theme.textSecondary,
      fontWeight: FontWeight.w600,
    );
    final hint = AppTypography.bodySmallStyle.copyWith(
      color: theme.textSecondary,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHandle(),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.xs,
              Spacing.lg,
              Spacing.lg,
            ),
            children: [
              Row(
                children: [
                  HermesRoomAvatarStack(members: room.members, size: 44),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          room.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.titleMediumStyle.copyWith(
                            color: theme.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          l10n.hermesRoomBotCount(room.members.length),
                          style: hint,
                        ),
                      ],
                    ),
                  ),
                  ConduitIconButton(
                    key: const ValueKey<String>('hermes-room-rename'),
                    icon: Icons.edit_outlined,
                    tooltip: l10n.rename,
                    isCompact: true,
                    onPressed: view.gone ? null : () => _rename(room),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.lg),
              Text(l10n.hermesRoomPurpose, style: label),
              const SizedBox(height: Spacing.xs),
              AdaptiveTextField(
                key: const ValueKey<String>('hermes-room-purpose'),
                controller: _purpose,
                placeholder: l10n.hermesRoomPurposeHint,
                maxLength: kMaxHermesRoomPurposeCharacters,
                enabled: !_saving && _saved != null,
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: Spacing.md),
              Text(l10n.hermesRoomNotes, style: label),
              const SizedBox(height: Spacing.xs),
              AdaptiveTextField(
                key: const ValueKey<String>('hermes-room-notes'),
                controller: _notes,
                placeholder: l10n.hermesRoomNotesHint,
                minLines: 3,
                maxLines: 8,
                keyboardType: TextInputType.multiline,
                enabled: !_saving && _saved != null,
                textCapitalization: TextCapitalization.sentences,
              ),
              if (_notesTooLong) ...[
                const SizedBox(height: Spacing.xxs),
                Text(
                  l10n.hermesRoomNotesTooLong,
                  style: hint.copyWith(color: theme.error),
                ),
              ],
              if (routing != null) ...[
                const SizedBox(height: Spacing.md),
                Text(l10n.hermesRoomWhoAnswers, style: label),
                const SizedBox(height: Spacing.xs),
                AdaptiveSegmentedControl(
                  key: const ValueKey<String>('hermes-room-routing'),
                  labels: [
                    l10n.hermesRoomEveryone,
                    l10n.hermesRoomRoutingLead,
                    if (offersAuto) l10n.hermesRoomRoutingAuto,
                  ],
                  selectedIndex: switch (routing) {
                    HermesRoomRouting.everyone => 0,
                    HermesRoomRouting.lead => 1,
                    HermesRoomRouting.auto => 2,
                  },
                  enabled: !_saving,
                  onValueChanged: (index) => setState(() {
                    _routing = HermesRoomRouting.values[index];
                    _lead ??= room.members.firstOrNull?.memberId;
                  }),
                ),
                const SizedBox(height: Spacing.xs),
                Text(switch (routing) {
                  HermesRoomRouting.everyone =>
                    l10n.hermesRoomRoutingEveryoneHint,
                  HermesRoomRouting.lead => l10n.hermesRoomRoutingLeadHint,
                  HermesRoomRouting.auto => l10n.hermesRoomRoutingAutoHint,
                }, style: hint),
              ],
              if (_error != null) ...[
                const SizedBox(height: Spacing.sm),
                Text(_error!, style: hint.copyWith(color: theme.error)),
              ],
              const SizedBox(height: Spacing.md),
              ConduitButton(
                key: const ValueKey<String>('hermes-room-save'),
                text: l10n.save,
                isFullWidth: true,
                isLoading: _saving,
                onPressed: _dirty && _valid && !view.gone ? _save : null,
              ),
              const SizedBox(height: Spacing.lg),
              Text(l10n.hermesRoomMembers, style: label),
              for (final member in room.members)
                _MemberRow(
                  member: member,
                  status: statuses[member.memberId],
                  lead:
                      routing == HermesRoomRouting.lead &&
                      _lead == member.memberId,
                  onPickLead: routing == HermesRoomRouting.lead && !_saving
                      ? () => setState(() => _lead = member.memberId)
                      : null,
                ),
              Text(l10n.hermesRoomMembersFixed, style: hint),
              const SizedBox(height: Spacing.lg),
              if (view.driver != null && !view.gone) ...[
                ConduitButton(
                  key: const ValueKey<String>('hermes-room-info-stop'),
                  text: l10n.hermesRoomStopWork,
                  isSecondary: true,
                  isFullWidth: true,
                  onPressed: () =>
                      Navigator.of(context).pop(HermesRoomInfoAction.stop),
                ),
                const SizedBox(height: Spacing.sm),
              ],
              if (!view.gone)
                ConduitButton(
                  key: const ValueKey<String>('hermes-room-disband'),
                  text: l10n.hermesRoomDisband,
                  isDestructive: true,
                  isFullWidth: true,
                  onPressed: () => _confirmDisband(room),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDisband(HermesRoom room) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.hermesRoomDisbandTitle(room.name),
      message: l10n.hermesRoomDisbandMessage,
      confirmText: l10n.hermesRoomDisband,
      isDestructive: true,
    );
    if (confirmed && mounted) {
      Navigator.of(context).pop(HermesRoomInfoAction.disband);
    }
  }
}

/// A member's status in a few words, or null when it has none to show.
String? hermesRoomMemberStatusLabel(
  AppLocalizations l10n,
  HermesRoomMemberStatus? status,
) {
  if (status == null) return null;
  final elapsed = status.elapsed;
  return switch (status.kind) {
    HermesRoomMemberStatusKind.working => [
      l10n.hermesRoomWorking,
      ?status.tool,
      if (elapsed != null) formatHermesRoomElapsed(elapsed),
    ].join(' · '),
    HermesRoomMemberStatusKind.stalled => l10n.hermesRoomQuiet(
      formatHermesRoomElapsed(elapsed ?? Duration.zero),
    ),
    HermesRoomMemberStatusKind.queued => l10n.hermesRoomWaiting,
    HermesRoomMemberStatusKind.failed => [
      l10n.hermesRoomTurnFailed,
      ?status.reason,
    ].join(': '),
    HermesRoomMemberStatusKind.unavailable => l10n.hermesRoomMemberUnavailable,
    _ => null,
  };
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.status,
    required this.lead,
    this.onPickLead,
  });

  final HermesRoomMember member;
  final HermesRoomMemberStatus? status;
  final bool lead;

  /// Makes this member the lead; null when routing is not by lead.
  final VoidCallback? onPickLead;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final detail = hermesRoomMemberStatusLabel(l10n, status);
    final pick = onPickLead;
    return Semantics(
      selected: pick == null ? null : lead,
      button: pick != null,
      child: GestureDetector(
        key: ValueKey<String>('hermes-room-member-${member.memberId}'),
        behavior: HitTestBehavior.opaque,
        onTap: pick,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
          child: Row(
            children: [
              HermesRoomMemberAvatar(
                member: member,
                size: 28,
                active: status?.busy ?? false,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: member.name),
                          TextSpan(
                            text: '  @${member.handle}',
                            style: AppTypography.bodySmallStyle.copyWith(
                              color: theme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.standard.copyWith(
                        color: theme.textPrimary,
                      ),
                    ),
                    if (detail != null)
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodySmallStyle.copyWith(
                          color:
                              status?.kind == HermesRoomMemberStatusKind.failed
                              ? theme.error
                              : theme.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              if (lead)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.hermesRoomLead,
                      style: AppTypography.labelSmallStyle.copyWith(
                        color: theme.buttonPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: Spacing.xxs),
                    Icon(
                      Icons.check_rounded,
                      size: IconSize.small,
                      color: theme.buttonPrimary,
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
