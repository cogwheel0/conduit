import 'package:conduit_core/features/notes/services/note_audio_upload_service.dart';
import 'package:path_provider/path_provider.dart';

export 'package:conduit_core/features/notes/services/note_audio_upload_service.dart';

/// The upload store over the platform's directories: durable copies in
/// application support, the recorder's cache file in the temporary directory.
NoteAudioUploadStore createNoteAudioUploadStore() => NoteAudioUploadStore(
  applicationSupportDirectory: getApplicationSupportDirectory,
  temporaryDirectory: getTemporaryDirectory,
);
