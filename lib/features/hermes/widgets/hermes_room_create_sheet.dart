import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_room.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_room_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_room_projection.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/themed_sheets.dart';
import 'hermes_room_avatars.dart';
import 'hermes_rooms_section.dart';

/// Asks for a name and two to six bots, creates the room, and opens it.
Future<void> showHermesRoomCreateSheet(BuildContext context) async {
  final roomId = await ThemedSheets.showSurface<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.85,
    ),
    padding: EdgeInsets.zero,
    // The sheet draws its own handle so its list scrolls within its height.
    showHandle: false,
    builder: (_) => const HermesRoomCreateSheet(),
  );
  if (roomId != null && context.mounted) openHermesRoom(context, roomId);
}

/// The new-room form. Pops with the new room's id.
class HermesRoomCreateSheet extends ConsumerStatefulWidget {
  const HermesRoomCreateSheet({super.key});

  @override
  ConsumerState<HermesRoomCreateSheet> createState() =>
      _HermesRoomCreateSheetState();
}

class _HermesRoomCreateSheetState extends ConsumerState<HermesRoomCreateSheet> {
  final _name = TextEditingController();
  final _picked = <String>[];
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _ready =>
      !_creating &&
      _name.text.trim().isNotEmpty &&
      _picked.length >= kMinHermesRoomSeats &&
      _picked.length <= kMaxHermesRoomSeats;

  Future<void> _create(List<HermesBot> bots) async {
    final service = ref.read(hermesApiServiceProvider);
    if (!_ready || service is! HermesDesktopApiService) return;
    final l10n = AppLocalizations.of(context)!;
    // The sheet can be dismissed while Hermes creates the room; the list
    // still learns of it.
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final room = await service.createRoom(
        name: _name.text.trim(),
        members: [
          for (final name in _picked)
            if (hermesRoomMemberBot(bots, name) case final bot?)
              HermesRoomMember.forBot(bot),
        ],
      );
      container.invalidate(hermesRoomsProvider);
      if (mounted) Navigator.of(context).pop(room.id);
    } catch (error) {
      if (!mounted) return;
      final detail = hermesRoomRefusalDetail(error);
      setState(() {
        _creating = false;
        _error = detail == null
            ? l10n.hermesRoomCreateFailed
            : l10n.hermesRoomRefused(detail);
      });
    }
  }

  void _toggle(String name, bool picked) => setState(() {
    _error = null;
    if (picked) {
      if (!_picked.contains(name)) _picked.add(name);
    } else {
      _picked.remove(name);
    }
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final capabilities = ref.watch(hermesRoomCapabilitiesProvider).value;
    final roster = ref.watch(hermesBotsProvider).value ?? const [];
    final bots = capabilities == null
        ? roster
        : hermesSeatableBots(roster, capabilities);
    final full = _picked.length >= kMaxHermesRoomSeats;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHandle(),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.xs,
            Spacing.lg,
            Spacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.hermesRoomNew,
                style: AppTypography.titleMediumStyle.copyWith(
                  color: theme.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: Spacing.xxs),
              Text(
                bots.length < kMinHermesRoomSeats
                    ? l10n.hermesRoomNeedsBots
                    : l10n.hermesRoomCreateHint,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
              const SizedBox(height: Spacing.md),
              AdaptiveTextField(
                key: const ValueKey<String>('hermes-room-create-name'),
                controller: _name,
                placeholder: l10n.hermesRoomNameHint,
                maxLength: kMaxHermesRoomNameInput,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.done,
                enabled: !_creating,
                autofocus: true,
              ),
            ],
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
            children: [
              for (final bot in bots)
                _BotRow(
                  key: ValueKey<String>('hermes-room-create-bot-${bot.name}'),
                  bot: bot,
                  picked: _picked.contains(bot.name),
                  onChanged:
                      _creating || (full && !_picked.contains(bot.name))
                      ? null
                      : (picked) => _toggle(bot.name, picked),
                ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.sm,
              Spacing.lg,
              0,
            ),
            child: Text(
              _error!,
              style: AppTypography.bodySmallStyle.copyWith(color: theme.error),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: ConduitButton(
            key: const ValueKey<String>('hermes-room-create-submit'),
            text: l10n.create,
            isFullWidth: true,
            isLoading: _creating,
            onPressed: _ready ? () => _create(bots) : null,
          ),
        ),
      ],
    );
  }
}

class _BotRow extends StatelessWidget {
  const _BotRow({
    super.key,
    required this.bot,
    required this.picked,
    required this.onChanged,
  });

  final HermesBot bot;
  final bool picked;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final callback = onChanged;
    return MergeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: callback == null ? null : () => callback(!picked),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
          child: Row(
            children: [
              AdaptiveCheckbox(
                value: picked,
                onChanged: callback == null
                    ? null
                    : (next) => callback(next ?? !picked),
              ),
              const SizedBox(width: Spacing.xs),
              HermesRoomMemberAvatar(
                member: HermesRoomMember.forBot(bot),
                size: 28,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  bot.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.standard.copyWith(
                    color: callback != null || picked
                        ? theme.textPrimary
                        : theme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
