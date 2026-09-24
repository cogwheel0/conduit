/// Every seam where the core hands off to its host.
///
/// A port exists whenever the answer differs between the Flutter app and the
/// `conduitd` sidecar: the filesystem, the keychain, the network stack's idea
/// of "online", the app lifecycle, and the user sitting in front of a window.
/// Each has one implementation per host (`lib/platform/` and `apps/daemon`),
/// and the core itself never imports either.
///
/// Where "absent" is a coherent answer, the port ships a named no-op
/// (`StaticAppLifecycle`, `NullLogSink`) rather than leaving callers to
/// decide what a null means. Where it is not — there is no sensible guess for
/// where database files live — there is no default and the provider throws.
library;

export 'background_execution_port.dart';
export 'app_lifecycle.dart';
export 'clipboard_port.dart';
export 'connectivity_port.dart';
export 'cookie_jar_port.dart';
export 'database_opener.dart';
export 'external_url_port.dart';
export 'audio_capture_port.dart';
export 'audio_playback_port.dart';
export 'display_boost_port.dart';
export 'flush_scheduler.dart';
export 'post_frame_scheduler.dart';
export 'key_value_store.dart';
export 'log_sink.dart';
export 'paths_port.dart';
export 'secure_key_value_store.dart';
export 'share_staging_port.dart';
export 'ui_request_port.dart';
export 'worker_port.dart';
