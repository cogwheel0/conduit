import '../utils/hermes_time_parsing.dart';

/// Lightweight summary of a Hermes server-side session, for the sessions list.
class HermesSessionSummary {
  const HermesSessionSummary({
    required this.id,
    required this.title,
    this.preview,
    this.source,
    this.updatedAt,
  });

  final String id;

  /// Display title; falls back to "Untitled session" when the server has none.
  final String title;

  /// First-line preview of the transcript, when the server provides one.
  final String? preview;

  /// Origin channel (e.g. `telegram`, `cron`, `api_server`).
  final String? source;

  final DateTime? updatedAt;

  /// Parses one session object from `GET /api/sessions`, or null when it has no
  /// usable id. Tolerant of the field-name variations across Hermes versions.
  static HermesSessionSummary? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] ?? json['session_id'])?.toString();
    if (id == null || id.isEmpty) return null;

    final rawTitle = (json['title'] ?? json['name'] ?? '').toString().trim();
    final rawPreview = json['preview']?.toString().trim();

    return HermesSessionSummary(
      id: id,
      title: rawTitle.isEmpty ? 'Untitled session' : rawTitle,
      preview: (rawPreview == null || rawPreview.isEmpty) ? null : rawPreview,
      source: json['source']?.toString(),
      updatedAt: parseHermesTimestamp(
        json['last_active'] ??
            json['updated_at'] ??
            json['updatedAt'] ??
            json['started_at'],
      ),
    );
  }
}
