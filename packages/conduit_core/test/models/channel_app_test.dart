// Open WebUI 0.12.1 channel parity: the mute flag of channel responses
// (routers/channels.py) and the cards, buttons and replies of external apps
// (models/apps.py, src/lib/utils/apps.ts).
import 'package:checks/checks.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/channel_message.dart';
import 'package:test/test.dart';

// An app message as the channel message list returns it: no user_id, the app
// named in `user`, and its cards and buttons kept in `data`.
Map<String, dynamic> _appMessage({Object? data}) => {
  'id': 'm1',
  'channel_id': 'c1',
  'user_id': null,
  'app_id': 'app-1',
  'content': '',
  'user': {
    'id': 'app-1',
    'name': 'Deploy Bot',
    'role': 'app',
    'profile_image_url': 'https://bot.example/icon.png',
  },
  'data':
      data ??
      {
        'app': {
          'embeds': [
            {
              'title': 'Build 42',
              'description': 'All **green**',
              'url': 'https://ci.example/42',
              'color': 0x22C55E,
              'author': {'name': 'CI'},
              'footer': {'text': 'took 3m'},
              'thumbnail': {'url': 'https://ci.example/thumb.png'},
              'fields': [
                {'name': 'Branch', 'value': 'main', 'inline': true},
                {'name': 'Commit', 'value': 'abc123'},
              ],
            },
          ],
          'actions': [
            {'action_id': 'redeploy', 'label': 'Redeploy', 'context': {}},
            {'label': 'Open logs', 'url': 'https://ci.example/42/logs'},
          ],
        },
      },
};

void main() {
  group('channel mute flag', () {
    test('is read from is_channel_muted and defaults to off', () {
      check(
        Channel.fromJson({
          'id': 'c1',
          'name': 'general',
          'is_channel_muted': true,
        }).isChannelMuted,
      ).isTrue();
      // Servers before 0.12.1 do not send it.
      check(
        Channel.fromJson({'id': 'c1', 'name': 'general'}).isChannelMuted,
      ).isFalse();
    });
  });

  group('app messages', () {
    test('parse the app id, cards and buttons', () {
      final message = ChannelMessage.fromJson(_appMessage());

      check(message.isAppMessage).isTrue();
      check(message.appId).equals('app-1');
      check(message.userId).isNull();
      check(message.userName).equals('Deploy Bot');

      final embed = message.appEmbeds.single;
      check(embed.title).equals('Build 42');
      check(embed.description).equals('All **green**');
      check(embed.url).equals('https://ci.example/42');
      check(embed.color).equals(0x22C55E);
      check(embed.authorName).equals('CI');
      check(embed.footerText).equals('took 3m');
      check(embed.thumbnailUrl).equals('https://ci.example/thumb.png');
      check(embed.fields.map((f) => '${f.name}=${f.value}:${f.inline}'))
          .deepEquals(['Branch=main:true', 'Commit=abc123:false']);

      final actions = message.appActions;
      check(actions.map((a) => a.label)).deepEquals(['Redeploy', 'Open logs']);
      check(actions[0].actionId).equals('redeploy');
      check(actions[0].isLink).isFalse();
      check(actions[1].url).equals('https://ci.example/42/logs');
      check(actions[1].isLink).isTrue();
    });

    test('a card-only message previews the text of its cards', () {
      final message = ChannelMessage.fromJson(_appMessage());
      // Same order as Open WebUI's getAppMessageText.
      check(message.previewText).equals(
        'CI\nBuild 42\nAll **green**\nBranch: main\nCommit: abc123\n'
        'took 3m\nhttps://ci.example/42',
      );

      final human = ChannelMessage.fromJson({
        'id': 'm2',
        'user_id': 'u1',
        'content': 'hello',
      });
      check(human.previewText).equals('hello');
    });

    test('a reply preview keeps the cards the slim response carries', () {
      final reply = ChannelMessage.fromJson({
        'id': 'm3',
        'user_id': 'u1',
        'content': 'thanks',
        'reply_to_message': _appMessage(
          data: {
            'app': {
              'embeds': [
                {'title': 'Build 42'},
              ],
            },
          },
        ),
      });
      check(reply.replyToMessage!.previewText).equals('Build 42');
    });

    test('malformed cards and buttons are skipped, not thrown', () {
      final message = ChannelMessage.fromJson(
        _appMessage(
          data: {
            'app': {
              'embeds': [
                'not a card',
                {'title': 'Kept', 'color': 'red', 'fields': 'none'},
              ],
              'actions': [
                {'label': 'Both', 'action_id': 'a', 'url': 'https://x.test'},
                {'label': '', 'action_id': 'b'},
                {'action_id': 'c'},
                42,
              ],
            },
          },
        ),
      );
      check(message.appEmbeds.single.title).equals('Kept');
      check(message.appEmbeds.single.color).isNull();
      check(message.appEmbeds.single.fields).isEmpty();
      check(message.appActions).isEmpty();
    });

    test('a person cannot post cards or buttons', () {
      final message = ChannelMessage.fromJson({
        ..._appMessage(),
        'app_id': null,
        'user_id': 'u1',
        'user': {'id': 'u1', 'name': 'Mallory'},
      });
      check(message.isAppMessage).isFalse();
      check(message.appEmbeds).isEmpty();
      check(message.appActions).isEmpty();
    });
  });

  group('app replies', () {
    test('an events:app payload names its message, thread and reply', () {
      final event = AppChannelReplyEvent.fromJson({
        'app_id': 'app-1',
        'app_name': 'Deploy Bot',
        'channel_id': 'c1',
        'message_id': 'm1',
        'parent_id': 'p1',
        'reply': {'type': 'error', 'content': 'App is inactive'},
      })!;
      check(event.key).equals('m1:app-1');
      check(event.appName).equals('Deploy Bot');
      check(event.parentId).equals('p1');
      check(event.reply.isError).isTrue();
      check(event.reply.content).equals('App is inactive');

      check(AppChannelReplyEvent.fromJson({'app_id': 'app-1'})).isNull();
      check(
        AppChannelReplyEvent.fromJson({
          'app_id': 'app-1',
          'channel_id': 'c1',
          'message_id': 'm1',
          'parent_id': null,
          'reply': {'type': 'error'},
        })!.parentId,
      ).isNull();
    });

    test('only an answer for the asking user is shown in place', () {
      AppChannelReply reply(Map<String, dynamic> json) =>
          AppChannelReply.fromJson(json)!;
      // The interactions endpoint defaults to a private message.
      check(reply({'content': 'Only you'}).showsToAskerOnly).isTrue();
      check(reply({'type': 'ack'}).showsToAskerOnly).isFalse();
      // A channel reply comes back as a channel message.
      check(
        reply({'type': 'message', 'visibility': 'channel'}).showsToAskerOnly,
      ).isFalse();
      check(
        reply({'type': 'error', 'visibility': 'channel'}).showsToAskerOnly,
      ).isTrue();
      final download = reply({
        'type': 'download',
        'content': '# Report',
        'filename': 'weekly.md',
      });
      check(download.isDownload).isTrue();
      check(download.filename).equals('weekly.md');
      check(reply({'type': 'download'}).filename).equals('report.md');
    });
  });
}
