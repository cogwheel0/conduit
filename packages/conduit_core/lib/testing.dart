/// Fakes for the things the core defines, for any host that tests against it.
///
/// These live in `lib/` rather than the package's own `test/` because they are
/// shared across a package boundary: the mobile app's tests, the package's own
/// tests and the desktop UI and daemon all need to stand up a
/// fake OpenWebUI server or a fake `AppLifecyclePort`. A `test/` directory is
/// not importable from outside its package, so a helper kept there can only
/// ever serve one side. This is the same reason `package:http` ships
/// `http/testing.dart`.
///
/// Nothing here imports `package:test`: these are fakes, not matchers, so the
/// test framework stays a dev dependency.
library;

export 'testing/fake_app_lifecycle.dart';
export 'testing/fake_open_webui_server.dart';
export 'testing/fake_sync_api_client.dart';
export 'testing/gated_close_database.dart';
export 'testing/transcript_chain_fixture.dart';
