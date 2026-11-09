import 'package:conduit_core/features/hermes/utils/hermes_time_parsing.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';

const int kMaxHermesSessionTitleCharacters = 512;
const int kMaxHermesSessionPreviewCharacters = 4096;
const int kMaxHermesSessionSourceCharacters = 128;

/// Session sources the Hermes API server owns and may add turns to.
const Set<String> kHermesApiOwnedSessionSources = {'api_server', 'bot_room'};

/// Whether a session came from another Hermes surface (CLI, desktop, a
/// messaging platform, cron). Unknown sources count as API-owned so older
/// servers, which do not report one, keep working.
bool isForeignHermesSessionSource(String? source) {
  final normalized = source?.trim().toLowerCase();
  return normalized != null &&
      normalized.isNotEmpty &&
      !kHermesApiOwnedSessionSources.contains(normalized);
}

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
      title: rawTitle ?? 'Untitled session',
      preview: rawPreview,
      source: validateHermesBoundedString(
        json['source'],
        maxCharacters: kMaxHermesSessionSourceCharacters,
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
