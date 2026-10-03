import 'package:checks/checks.dart';
import 'package:conduit_core/models/channel_message.dart';
import 'package:conduit_core/models/user.dart';
import 'package:test/test.dart';

const _me = User(
  id: 'user-1',
  username: 'ava',
  email: 'ava@example.com',
  name: 'Ava',
  role: 'user',
);

// The bare row Open WebUI answers a post or an edit with: no `user`, no
// reactions, no thread counts.
Map<String, dynamic> _bareRow({String content = 'hello'}) => {
  'id': 'm1',
  'channel_id': 'c1',
  'user_id': 'user-1',
  'content': content,
  'created_at': 1,
  'updated_at': 2,
};

void main() {
  test('a posted message names its sender instead of "Unknown"', () {
    final posted = ChannelMessage.fromJson(_bareRow());
    check(posted.userName).equals('Unknown');

    final shown = posted.withSenderIfMissing(_me);
    check(shown.userName).equals('Ava');
    check(shown.user?.id).equals('user-1');
  });

  test('a sender is only filled in for the signed-in user\'s rows', () {
    final other = ChannelMessage.fromJson({..._bareRow(), 'user_id': 'u2'});
    check(other.withSenderIfMissing(_me).user).isNull();
  });

  test('an edit response keeps the sender, reactions and replies', () {
    final listed = ChannelMessage.fromJson({
      ..._bareRow(),
      'user': {'id': 'user-1', 'name': 'Ava'},
      'reactions': [
        {
          'name': '👍',
          'count': 1,
          'users': [
            {'user_id': 'user-1'},
          ],
        },
      ],
      'reply_count': 3,
    });
    final response = ChannelMessage.fromJson({
      ..._bareRow(content: 'edited'),
      'updated_at': 9,
    });

    final updated = listed.withUpdateResponse(response);
    check(updated.content).equals('edited');
    check(updated.updatedAt).equals(9);
    check(updated.userName).equals('Ava');
    check(updated.reactions).length.equals(1);
    check(updated.replyCount).equals(3);
  });
}
