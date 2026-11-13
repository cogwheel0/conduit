import 'package:flutter/widgets.dart';

import '../../../shared/widgets/platform_ui/vocabulary.dart';

/// The Material icon the Flutter Settings pages draw for a row's SF Symbol.
///
/// Page definitions name their glyphs as SF Symbols, which the native sheet
/// draws as they are. Android has no SF Symbols, so each one maps to the
/// outlined Material icon that carries the same meaning. A symbol missing
/// here draws a neutral dot rather than an unrelated picture.
IconData settingsMaterialIcon(String sfSymbol) =>
    _icons[sfSymbol] ??
    _icons[_withoutVariant(sfSymbol)] ??
    Icons.circle_outlined;

/// `bell.fill` → `bell`, `person.crop.circle.badge.checkmark` stays.
String _withoutVariant(String symbol) {
  for (final suffix in const ['.fill', '.circle', '.square']) {
    if (symbol.endsWith(suffix)) {
      return symbol.substring(0, symbol.length - suffix.length);
    }
  }
  return symbol;
}

const Map<String, IconData> _icons = {
  // Accounts and people.
  'person': Icons.person_outline,
  'person.crop.circle': Icons.account_circle_outlined,
  'person.crop.circle.badge.checkmark': Icons.manage_accounts_outlined,
  'person.2': Icons.people_outline,
  'person.wave.2': Icons.record_voice_over_outlined,
  'rectangle.portrait.and.arrow.right': Icons.logout,
  'key': Icons.key_outlined,
  'lock': Icons.lock_outline,
  'lock.slash': Icons.no_encryption_outlined,
  'lock.shield': Icons.security_outlined,
  'checkmark.shield': Icons.verified_user_outlined,
  'camera': Icons.photo_camera_outlined,
  'text.quote': Icons.format_quote_outlined,
  'tag': Icons.sell_outlined,
  // Settings root.
  'bell': Icons.notifications_outlined,
  'bell.badge': Icons.notifications_active_outlined,
  'bell.and.waves.left.and.right': Icons.notifications_active_outlined,
  'app.badge': Icons.mark_email_unread_outlined,
  'brain.head.profile': Icons.psychology_outlined,
  'antenna.radiowaves.left.and.right': Icons.sync_alt,
  'paintbrush': Icons.palette_outlined,
  'paintpalette': Icons.color_lens_outlined,
  'circle.lefthalf.filled': Icons.contrast,
  'globe': Icons.language,
  'bubble.left': Icons.chat_bubble_outline,
  'bubble.left.and.bubble.right': Icons.forum_outlined,
  'quote.bubble': Icons.format_quote_outlined,
  'text.bubble': Icons.chat_outlined,
  'waveform': Icons.graphic_eq,
  'waveform.path': Icons.graphic_eq,
  'waveform.path.ecg': Icons.monitor_heart_outlined,
  'calendar': Icons.calendar_month_outlined,
  'square.grid.2x2': Icons.dashboard_customize_outlined,
  'clock.arrow.circlepath': Icons.schedule_outlined,
  'server.rack': Icons.dns_outlined,
  'externaldrive': Icons.storage_outlined,
  'info.circle': Icons.info_outline,
  'heart': Icons.favorite_border,
  'gift': Icons.card_giftcard_outlined,
  // Chats and models.
  'sparkles': Icons.auto_awesome_outlined,
  'wand.and.stars': Icons.auto_fix_high_outlined,
  'cube.box': Icons.view_in_ar_outlined,
  'cpu': Icons.memory_outlined,
  'photo': Icons.image_outlined,
  'photo.on.rectangle': Icons.collections_outlined,
  'bookmark': Icons.bookmark_border,
  'note.text': Icons.sticky_note_2_outlined,
  'note.text.badge.plus': Icons.note_add_outlined,
  'doc.text': Icons.description_outlined,
  'text.alignleft': Icons.notes_outlined,
  'textformat': Icons.text_fields,
  // The model's name in the message box, as the Flutter page drew it.
  'text.cursor': Icons.short_text,
  'number': Icons.numbers,
  'puzzlepiece.extension': Icons.extension_outlined,
  'rectangle.stack': Icons.layers_outlined,
  'rectangle.topthird.inset.filled': Icons.web_asset_outlined,
  'sidebar.left': Icons.view_sidebar_outlined,
  'display': Icons.desktop_windows_outlined,
  'iphone': Icons.smartphone,
  'paperplane': Icons.send_outlined,
  'chevron.left.forwardslash.chevron.right': Icons.code,
  'link': Icons.link,
  'link.circle': Icons.link,
  'magnifyingglass': Icons.search,
  'gearshape.2': Icons.settings_outlined,
  'gauge.with.dots.needle.67percent': Icons.speed_outlined,
  'timer': Icons.timer_outlined,
  'bolt': Icons.bolt_outlined,
  'network': Icons.lan_outlined,
  'cloud': Icons.cloud_outlined,
  // Voice.
  'mic': Icons.mic_none_outlined,
  'speaker.wave.2': Icons.volume_up_outlined,
  'speaker.wave.3': Icons.volume_up_outlined,
  'phone.badge.waveform': Icons.phone_in_talk_outlined,
  'play.circle': Icons.play_circle_outline,
  // States and actions.
  'ellipsis.circle': Icons.more_horiz,
  'exclamationmark.triangle': Icons.warning_amber_outlined,
  'xmark.circle': Icons.cancel_outlined,
  'checkmark': Icons.check,
  'checkmark.circle': Icons.check_circle_outline,
  'plus': Icons.add,
  'plus.circle': Icons.add_circle_outline,
  'trash': Icons.delete_outline,
  'clear': Icons.backspace_outlined,
  'arrow.clockwise': Icons.refresh,
  'arrow.counterclockwise': Icons.restart_alt,
  'pencil': Icons.edit_outlined,
  'square.and.pencil': Icons.edit_note_outlined,
  // Message actions.
  'square.on.square': Icons.copy_outlined,
  'slash.circle': Icons.block,
  'arrow.triangle.merge': Icons.merge_type,
  'arrow.triangle.branch': Icons.call_split,
  'square.and.arrow.up': Icons.ios_share,
  'wand.and.rays': Icons.auto_fix_high_outlined,
  // Connections.
  'desktopcomputer': Icons.computer_outlined,
  'power': Icons.power_settings_new,
  'wifi': Icons.wifi,
  'wifi.slash': Icons.wifi_off,
  'antenna.radiowaves.left.and.right.slash': Icons.sync_disabled,
  // Files, backups and chats in bulk.
  'square.and.arrow.down': Icons.file_download_outlined,
  'archivebox': Icons.archive_outlined,
  'tray.and.arrow.up': Icons.unarchive_outlined,
  'arrow.triangle.2.circlepath': Icons.sync,
  'arrow.up.circle': Icons.cloud_upload_outlined,
  'doc': Icons.description_outlined,
  'doc.badge.plus': Icons.note_add_outlined,
  // Connection settings.
  'gearshape': Icons.settings_outlined,
  'lock.open': Icons.lock_open_outlined,
  'doc.badge.gearshape': Icons.workspace_premium_outlined,
  'list.bullet.rectangle': Icons.list_alt_outlined,
  'slider.horizontal.3': Icons.tune,
  // Scheduled tasks and personal connections.
  'clock': Icons.schedule,
  'line.3.horizontal.decrease.circle': Icons.filter_list,
  'clock.badge.exclamationmark': Icons.history_toggle_off,
  'pause.circle': Icons.pause_circle_outline,
  'play': Icons.play_arrow_outlined,
  'exclamationmark.circle': Icons.error_outline,
  'hourglass': Icons.hourglass_empty,
  'list.bullet': Icons.list,
  'arrow.down.circle': Icons.expand_circle_down_outlined,
  'terminal': Icons.terminal,
  'folder': Icons.folder_outlined,
  'repeat': Icons.repeat,
  'calendar.badge.exclamationmark': Icons.event_busy_outlined,
  'calendar.day.timeline.left': Icons.date_range_outlined,
  'wrench.and.screwdriver': Icons.build_outlined,
  'key.slash': Icons.key_off_outlined,
  'arrow.uturn.backward': Icons.undo,
  'point.topleft.down.to.point.bottomright.curvepath': Icons.route_outlined,
  'curlybraces': Icons.data_object,
  'bolt.horizontal': Icons.bolt_outlined,
  'questionmark.circle': Icons.help_outline,
};
