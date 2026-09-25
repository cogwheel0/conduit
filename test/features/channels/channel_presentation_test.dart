import 'package:checks/checks.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit/features/channels/utils/channel_presentation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('direct messages are titled by their participants', () {
    const dm = Channel(
      id: 'dm-1',
      name: '',
      type: 'dm',
      users: [
        {'name': 'cogwheel'},
        {'name': 'Tapas'},
      ],
    );

    check(channelDisplayName(dm)).equals('cogwheel, Tapas');
    check(channelIcon(dm)).equals(Icons.person_outline);
  });

  test('a DM without participant names falls back to the channel name', () {
    const dm = Channel(
      id: 'dm-2',
      name: 'fallback',
      type: 'dm',
      users: [
        {'name': ''},
      ],
    );

    check(channelDisplayName(dm)).equals('fallback');
  });

  test('standard channels keep their name and privacy glyph', () {
    const channel = Channel(id: 'c-1', name: 'general', isPrivate: true);

    check(channelDisplayName(channel)).equals('general');
    check(channelIcon(channel)).equals(Icons.lock_outlined);
  });
}
