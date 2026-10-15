/// Cards, buttons and replies of external apps in channels (Open WebUI
/// 0.12.1).
///
/// The shapes follow `backend/open_webui/models/apps.py` (`Embed`, `Action`,
/// `AppChannelReply`) and the `events:app` payload of
/// `backend/open_webui/routers/channels.py`. They come from a third-party app
/// through the server, so parsing never throws: a malformed card or button is
/// skipped and a malformed reply is dropped.
library;

/// One name and value pair of an [AppEmbed].
class AppEmbedField {
  const AppEmbedField({
    required this.name,
    required this.value,
    this.inline = false,
  });

  final String name;
  final String value;

  /// Whether the field may share a row with other inline fields.
  final bool inline;

  static AppEmbedField? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = _string(json['name']);
    final value = _string(json['value']);
    if (name.isEmpty || value.isEmpty) return null;
    return AppEmbedField(
      name: name,
      value: value,
      inline: json['inline'] == true,
    );
  }
}

/// A card an app attaches to a channel message or a reply.
class AppEmbed {
  const AppEmbed({
    this.title = '',
    this.description = '',
    this.url,
    this.color,
    this.authorName,
    this.footerText,
    this.thumbnailUrl,
    this.fields = const [],
  });

  final String title;

  /// Markdown text of the card.
  final String description;

  /// Link the [title] opens.
  final String? url;

  /// Accent color as a 24-bit RGB value.
  final int? color;
  final String? authorName;
  final String? footerText;
  final String? thumbnailUrl;
  final List<AppEmbedField> fields;

  static AppEmbed? fromJson(Object? json) {
    if (json is! Map) return null;
    final color = json['color'];
    return AppEmbed(
      title: _string(json['title']),
      description: _string(json['description']),
      url: _nonEmpty(json['url']),
      color: color is int && color >= 0 && color <= 0xFFFFFF ? color : null,
      authorName: _nonEmpty(_field(json['author'], 'name')),
      footerText: _nonEmpty(_field(json['footer'], 'text')),
      thumbnailUrl: _nonEmpty(_field(json['thumbnail'], 'url')),
      fields: [
        if (json['fields'] case final List<Object?> fields)
          for (final field in fields) ?AppEmbedField.fromJson(field),
      ],
    );
  }

  /// The cards in [json], a list as found in `data.app.embeds`.
  static List<AppEmbed> listFromJson(Object? json) => [
    if (json is List)
      for (final embed in json) ?AppEmbed.fromJson(embed),
  ];

  /// The text of this card for a reply preview, in the order of Open WebUI's
  /// `getAppMessageText`.
  String get previewText => [
    ?authorName,
    title,
    description,
    for (final field in fields) '${field.name}: ${field.value}',
    ?footerText,
    ?url,
  ].where((part) => part.isNotEmpty).join('\n');
}

/// A button or link an app attaches to a channel message.
///
/// A button carries an [actionId] and is answered through the app's
/// interactions endpoint; a link carries a [url] instead.
class AppAction {
  const AppAction({required this.label, this.actionId, this.url});

  final String label;
  final String? actionId;
  final String? url;

  bool get isLink => actionId == null;

  static AppAction? fromJson(Object? json) {
    if (json is! Map) return null;
    final label = _string(json['label']);
    final actionId = _nonEmpty(json['action_id']);
    final url = _nonEmpty(json['url']);
    // The server requires exactly one of the two.
    if (label.isEmpty || (actionId == null) == (url == null)) return null;
    return AppAction(label: label, actionId: actionId, url: url);
  }

  /// The actions in [json], a list as found in `data.app.actions`.
  static List<AppAction> listFromJson(Object? json) => [
    if (json is List)
      for (final action in json) ?AppAction.fromJson(action),
  ];
}

/// What an app answered: the result of a button press, or a reply sent to
/// the asking user alone over `events:app`.
class AppChannelReply {
  const AppChannelReply({
    this.type = 'message',
    this.visibility = 'private',
    this.title = '',
    this.content = '',
    this.filename = 'report.md',
    this.embeds = const [],
    this.actions = const [],
  });

  /// `message`, `update`, `ack`, `download` or `error`.
  final String type;

  /// `private` (only the asking user sees it) or `channel`.
  final String visibility;
  final String title;

  /// Markdown text of the reply; the file content of a download.
  final String content;

  /// File name of a download.
  final String filename;
  final List<AppEmbed> embeds;
  final List<AppAction> actions;

  bool get isAck => type == 'ack';
  bool get isError => type == 'error';
  bool get isDownload => type == 'download';

  /// Whether the asking user is shown this result of a button press here. A
  /// reply to the channel arrives as a channel message instead. Mirrors
  /// AppChannelReply.svelte.
  bool get showsToAskerOnly =>
      !isAck && (visibility != 'channel' || isError);

  static AppChannelReply? fromJson(Object? json) {
    if (json is! Map) return null;
    return AppChannelReply(
      type: _nonEmpty(json['type']) ?? 'message',
      visibility: _nonEmpty(json['visibility']) ?? 'private',
      title: _string(json['title']),
      content: _string(json['content']),
      filename: _nonEmpty(json['filename']) ?? 'report.md',
      embeds: AppEmbed.listFromJson(json['embeds']),
      actions: AppAction.listFromJson(json['actions']),
    );
  }
}

/// An app reply shown to the signed-in user alone, under the message
/// [messageId] it answers. Open WebUI keeps these on the page only: they are
/// never stored, and leaving the channel or thread drops them.
class AppChannelReplyEvent {
  const AppChannelReplyEvent({
    required this.appId,
    required this.channelId,
    required this.messageId,
    required this.reply,
    this.appName,
    this.parentId,
  });

  final String appId;
  final String? appName;
  final String channelId;

  /// The message the reply is shown under.
  final String messageId;

  /// The thread the reply belongs to, or null for the channel itself.
  final String? parentId;
  final AppChannelReply reply;

  /// One reply per message and app; a newer one replaces it.
  String get key => '$messageId:$appId';

  /// Parses an `events:app` payload:
  /// `{app_id, app_name, channel_id, message_id, parent_id, reply}`.
  static AppChannelReplyEvent? fromJson(Object? json) {
    if (json is! Map) return null;
    final appId = _nonEmpty(json['app_id']);
    final channelId = _nonEmpty(json['channel_id']);
    final messageId = _nonEmpty(json['message_id']);
    final reply = AppChannelReply.fromJson(json['reply']);
    if (appId == null ||
        channelId == null ||
        messageId == null ||
        reply == null) {
      return null;
    }
    return AppChannelReplyEvent(
      appId: appId,
      appName: _nonEmpty(json['app_name']),
      channelId: channelId,
      messageId: messageId,
      parentId: _nonEmpty(json['parent_id']),
      reply: reply,
    );
  }
}

String _string(Object? value) => value is String ? value : '';

String? _nonEmpty(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

Object? _field(Object? map, String key) => map is Map ? map[key] : null;
