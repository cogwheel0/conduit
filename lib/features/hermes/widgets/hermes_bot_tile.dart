import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/debug_logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/model_avatar.dart';
import '../../navigation/widgets/conversation_tile.dart';
import '../models/hermes_bot.dart';
import '../models/hermes_session.dart';
import '../providers/hermes_providers.dart';
import '../services/hermes_desktop_api_service.dart';
import 'hermes_session_tile.dart';

/// One Bot Mode agent in the sidebar roster. Tapping opens the bot's canonical
/// "Bot Chat" — the same forever-chat the Hermes desktop app opens.
class HermesBotTile extends ConsumerStatefulWidget {
  const HermesBotTile({required this.bot, super.key});

  final HermesBot bot;

  @override
  ConsumerState<HermesBotTile> createState() => _HermesBotTileState();
}

class _HermesBotTileState extends ConsumerState<HermesBotTile> {
  bool _opening = false;

  @override
  Widget build(BuildContext context) {
    final bot = widget.bot;
    final avatar = bot.hasAvatar
        ? ref.watch(hermesBotAvatarProvider(bot.name)).asData?.value
        : null;
    final activeSessionId = ref.watch(hermesActiveSessionProvider);
    final selected =
        bot.chatSessionId != null && activeSessionId == bot.chatSessionId;
    final subtitle = bot.preview ?? bot.description;

    return ChatStyleSidebarTile(
      selected: selected,
      enabled: !_opening,
      semanticLabel: bot.title,
      onTap: _open,
      tintKey: const ValueKey<String>('conversation-tile-active-tint'),
      pressedKey: const ValueKey<String>('conversation-tile-pressed-tint'),
      child: SidebarListTileContent(
        title: bot.title,
        selected: selected,
        subtitle: subtitle,
        leading: ModelAvatar(size: 32, imageUrl: avatar, label: bot.title),
        trailing: _opening
            ? const SizedBox(
                width: IconSize.sm,
                height: IconSize.sm,
                child: CircularProgressIndicator(
                  strokeWidth: BorderWidth.medium,
                ),
              )
            : null,
      ),
    );
  }

  Future<void> _open() async {
    final bot = widget.bot;
    final service = ref.read(hermesApiServiceProvider);
    if (service is! HermesDesktopApiService || _opening) return;
    setState(() => _opening = true);
    String storedId;
    try {
      storedId = await service.openBotChat(bot);
    } catch (error) {
      DebugLogger.error(
        'open-bot-chat-failed',
        scope: 'hermes/bots',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (mounted) {
        UiUtils.showMessage(
          context,
          AppLocalizations.of(context)!.hermesSessionLoadFailed,
          isError: true,
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _opening = false);
    }
    // A connection edit during the resolve invalidates the id we just bound.
    if (!mounted || !identical(ref.read(hermesApiServiceProvider), service)) {
      return;
    }
    await openHermesSession(
      context,
      ref,
      HermesSessionSummary(
        id: storedId,
        title: bot.title,
        updatedAt: bot.lastActive,
      ),
    );
  }
}
