import 'package:conduit_core/features/hermes/utils/hermes_time_parsing.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';

const int kMaxHermesSessionTitleCharacters = 512;
const int kMaxHermesSessionPreviewCharacters = 4096;
const int kMaxHermesSessionSourceCharacters = 128;

/// Lightweight summary of a Hermes server-side session, for the sessions list.
class HermesSessionSummary {
  const HermesSessionSummary({
    required this.id,
    required this.title,
    this.preview,
    this.source,
    this.rootTitle,
    this.updatedAt,
    this.archived = false,
  });

  final String id;

  /// Display title; falls back to "Untitled session" when the server has none.
  final String title;

  /// First-line preview of the transcript, when the server provides one.
  final String? preview;

  /// Origin channel (e.g. `telegram`, `cron`, `api_server`).
  final String? source;

  /// Original session title retained when Hermes retitles a conversation.
  final String? rootTitle;
  final DateTime? updatedAt;
  final bool archived;

  /// Same Bot Mode classifier as Hermes desktop's canonical-chat registry.
  bool get isBotChat =>
      rootTitle?.trim() == 'Bot Chat' ||
      (rootTitle?.trim().isNotEmpty != true && title.trim() == 'Bot Chat');

  /// Scheduled execution belongs to the work queue, rather than chat history.
  /// A legacy cron id is used only when the server omitted the origin channel.
  bool get isScheduledRun =>
      const {'cron', 'cron_output'}.contains(source?.toLowerCase()) ||
      (source == null && id.startsWith('cron_'));

  /// Parses one session object from `GET /api/sessions`, or null when it has no
  /// usable id. Tolerant of the field-name variations across Hermes versions.
  static HermesSessionSummary? fromJson(Map<String, dynamic> json) {
    final id =
        validateHermesOpaqueIdentifier(json['id']) ??
        validateHermesOpaqueIdentifier(json['session_id']);
    if (id == null) return null;

    final rawTitle =
        validateHermesBoundedString(
          json['title'],
          maxCharacters: kMaxHermesSessionTitleCharacters,
        ) ??
        validateHermesBoundedString(
          json['name'],
          maxCharacters: kMaxHermesSessionTitleCharacters,
        );
    final rawPreview = validateHermesBoundedString(
      json['preview'],
      maxCharacters: kMaxHermesSessionPreviewCharacters,
    );

    return HermesSessionSummary(
      id: id,
      archived: json['archived'] == true || json['archived'] == 1,
      title: rawTitle ?? 'Untitled session',
      preview: rawPreview,
      source: validateHermesBoundedString(
        json['source'],
        maxCharacters: kMaxHermesSessionSourceCharacters,
      ),
      rootTitle: validateHermesBoundedString(
        json['root_title'],
        maxCharacters: kMaxHermesSessionTitleCharacters,
      ),
      updatedAt: parseHermesTimestamp(
        json['last_active'] ??
            json['updated_at'] ??
            json['updatedAt'] ??
            json['started_at'],
      ),
    );
  }
}
