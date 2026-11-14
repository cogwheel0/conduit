import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/models/channel.dart';

export 'package:conduit_core/features/channels/utils/channel_presentation.dart';

/// Leading glyph that distinguishes DMs, groups, and private channels.
IconData channelIcon(Channel channel) {
  if (channel.isDm) return Icons.person_outline;
  if (channel.isGroup) return Icons.group_outlined;
  return channel.isPrivate ? Icons.lock_outlined : Icons.tag;
}
