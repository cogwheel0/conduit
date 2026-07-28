import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';

/// Whether an async channel request still owns the API and auth context that
/// started it.
///
/// Callers keep their `mounted` / `context.mounted` check at the call site so
/// Flutter's async-context lint can prove that subsequent context use is safe.
bool isChannelRequestOwnerCurrent({
  required WidgetRef ref,
  required Object api,
  required Object authSessionEpoch,
}) =>
    identical(ref.read(apiServiceProvider), api) &&
    identical(ref.read(openWebUiAuthSessionEpochProvider), authSessionEpoch);
