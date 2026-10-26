/// Callback function type for receiving log messages from the VAD pipeline.
///
/// When provided to [VadHandler.create], log lines emitted during model
/// initialization and inference setup are routed through this callback instead
/// of `print`. Consumers can wire it to their crash reporter (Crashlytics,
/// Sentry, etc.) so the messages land as breadcrumbs in crash reports.
typedef VadLogCallback = void Function(String message);
