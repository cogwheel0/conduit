import 'package:conduit_core/features/chat/composer/composer_mentions.dart';
import 'package:conduit_core/features/chat/models/chat_context_attachment.dart';
import 'package:conduit_protocol/conduit_protocol.dart';

/// [text] in Open WebUI's wire format: each of [mentions] (UTF-16 offsets,
/// as a Dart string counts them) replaced by its token, `<@U:id|Name>` or
/// `<$id|Name>`, by the core's tracker -- what mobile's composer sends.
String composerWireText(String text, List<ComposerMentionDto> mentions) {
  if (mentions.isEmpty) return text;
  final tracker = ComposerMentionTracker();
  for (final mention in mentions) {
    if (mention.start < 0 ||
        mention.end > text.length ||
        mention.start >= mention.end) {
      continue;
    }
    tracker.add(
      mention.start,
      mention.end,
      idType: mention.idType,
      id: mention.id,
      label: mention.label,
      kind: switch (mention.kind) {
        MentionKind.entity => ComposerMentionKind.entity,
        MentionKind.skill => ComposerMentionKind.skill,
      },
    );
  }
  return tracker.toWireFormat(text);
}

/// The core's context attachment for what a window sent.
ChatContextAttachment contextFromDto(ContextAttachmentDto dto) =>
    ChatContextAttachment(
      id: dto.id,
      type: switch (dto.kind) {
        ContextAttachmentKind.web => ChatContextAttachmentType.web,
        ContextAttachmentKind.youtube => ChatContextAttachmentType.youtube,
        ContextAttachmentKind.knowledge => ChatContextAttachmentType.knowledge,
        ContextAttachmentKind.note => ChatContextAttachmentType.note,
      },
      displayName: dto.name,
      url: dto.url,
      content: dto.content,
      collectionName: dto.collectionName,
      fileId: dto.fileId,
    );

/// [attachment] as the windows see it.
ContextAttachmentDto contextToDto(ChatContextAttachment attachment) =>
    ContextAttachmentDto(
      id: attachment.id,
      kind: switch (attachment.type) {
        ChatContextAttachmentType.web => ContextAttachmentKind.web,
        ChatContextAttachmentType.youtube => ContextAttachmentKind.youtube,
        ChatContextAttachmentType.knowledge => ContextAttachmentKind.knowledge,
        ChatContextAttachmentType.note => ContextAttachmentKind.note,
      },
      name: attachment.displayName,
      url: attachment.url,
      content: attachment.content,
      collectionName: attachment.collectionName,
      fileId: attachment.fileId,
    );
