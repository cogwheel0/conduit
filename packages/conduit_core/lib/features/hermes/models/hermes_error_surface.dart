import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/utils/sensitive_value_utils.dart';

/// Message metadata key holding a failed Hermes turn's [HermesErrorSurface].
const String kHermesErrorSurfaceMeta = 'hermesErrorSurface';

/// The longest server sentence a card shows.
const int _kMaxHermesErrorSentence = 600;

/// The fewest suggested models a card keeps (it offers only the first).
const int _kMaxHermesModelSuggestions = 4;

/// The provider pages where a user fixes an account-level routing or privacy
/// block, for the providers Hermes knows one for.
const Map<String, String> _kHermesProviderSettingsUrls = {
  'openrouter': 'https://openrouter.ai/settings/privacy',
  'nous': 'https://portal.nousresearch.com',
};

/// Which part of the stack failed a Hermes turn.
enum HermesErrorLayer {
  provider,
  endpoint,
  streaming,
  auth,
  billing,
  gateway,
  runtime,
  disk,
}

/// What broke, in the words a card leads with.
enum HermesErrorKind {
  provider,
  endpoint,
  connection,
  auth,
  billing,
  usageLimit,
  freeTier,
  rateLimit,
  contextOverflow,
  model,
  policy,
  truncated,
  badReply,
  workspace,
  session,
  busy,
  gateway,
  disk,
  unknown,
}

/// The one thing a card offers to do about a failure.
enum HermesErrorAction {
  retry,
  continueReply,
  compact,
  switchModel,
  openProviderSettings,
  openBilling,
  useCredits,
  newChat,
}

/// Whether the chat can go on (a retry, a continue) or is stuck until the
/// cause is fixed.
enum HermesErrorSeverity { blocking, degraded }

/// Hermes Desktop's recovery actions, of which Conduit performs a subset.
enum _Fix {
  retry,
  retryAtReset,
  updateApiKey,
  signInAgain,
  signInFreeTier,
  switchProvider,
  chooseModel,
  compress,
  startNewSession,
  editMessage,
  openHermesFolder,
  continueReply,
  openProviderSettings,
  openSetupGuide,
  openModelSettings,
  switchToModel,
  useCredits,
  openBilling,
}

typedef _Fixes = (_Fix?, _Fix?);

/// One model a usage-window plan still serves past its limit.
final class HermesModelSuggestion {
  const HermesModelSuggestion({
    required this.model,
    required this.label,
    required this.provider,
  });

  final String model;
  final String label;
  final String provider;

  static HermesModelSuggestion? fromJson(Object? json) {
    if (json is! Map) return null;
    final model = validateHermesOpaqueIdentifier(json['model']);
    if (model == null) return null;
    return HermesModelSuggestion(
      model: model,
      label:
          validateHermesBoundedString(json['label'], maxCharacters: 128) ??
          model,
      provider: validateHermesOpaqueIdentifier(json['provider']) ?? 'nous',
    );
  }

  Map<String, Object?> toJson() => {
    'model': model,
    'label': label,
    'provider': provider,
  };
}

/// A failed Hermes turn, classified: what broke, whether the chat is
/// blocked, when a limit resets, and the one action that helps.
///
/// Built from a Desktop Gateway `message.complete` (its `error_surface`,
/// `billing` and `partial` fields) or mapped from an API server refusal.
/// Every string a provider controls is sanitized before it is kept.
final class HermesErrorSurface {
  const HermesErrorSurface({
    required this.layer,
    required this.code,
    this.retryable = true,
    this.provider,
    this.providerLabel,
    this.model,
    this.authKind,
    this.message,
    this.resetsAt,
    this.suggestions = const [],
    this.creditsAction,
    this.billingUrl,
    this.partial = false,
  });

  final HermesErrorLayer layer;

  /// Hermes' failure code (a classifier reason or a gateway site code).
  final String code;

  /// False when the same request fails the same way again.
  final bool retryable;
  final String? provider;
  final String? providerLabel;
  final String? model;

  /// `oauth` or `api_key`, for an auth failure.
  final String? authKind;

  /// Hermes' own sentence for the failure, when it wrote one.
  final String? message;

  /// When the provider said the limit lifts.
  final DateTime? resetsAt;

  /// Models a plan still serves past its limit, best first.
  final List<HermesModelSuggestion> suggestions;

  /// `use_credits`, `add_credits` or `add_credits_and_keep_going`.
  final String? creditsAction;

  /// The failing provider's billing page, from Hermes' billing descriptor.
  final String? billingUrl;

  /// Whether the turn's text so far is a partial answer worth keeping.
  final bool partial;

  /// Reads a failed `message.complete` [payload]; null when it carries no
  /// structured failure (older gateways), so the plain error text stays.
  static HermesErrorSurface? fromCompletion(
    Map<String, dynamic> payload, {
    Iterable<String> sensitiveValues = const <String>[],
  }) {
    final raw = payload['error_surface'];
    final billing = payload['billing'];
    if (raw is! Map && billing is! Map) return null;
    String? sentence(Object? value) => _sentence(value, sensitiveValues);
    final surface = raw is Map ? raw : const <Object?, Object?>{};
    final billingBlock = billing is Map ? billing : const <Object?, Object?>{};
    final layer =
        _layer(surface['layer']) ??
        (billing is Map ? HermesErrorLayer.billing : null);
    if (layer == null) return null;
    final limit = surface['usage_limit'];
    final limitMap = limit is Map ? limit : const <Object?, Object?>{};
    final reason = validateHermesOpaqueIdentifier(payload['failure_reason']);
    final code =
        validateHermesOpaqueIdentifier(surface['code']) ??
        reason ??
        (layer == HermesErrorLayer.billing ? 'billing' : 'unknown');
    final credits = limitMap['credits'];
    final creditsAction = credits is Map ? credits['action'] : null;
    return HermesErrorSurface(
      layer: layer,
      code: code,
      retryable: surface['retryable'] != false,
      provider: validateHermesOpaqueIdentifier(
        surface['provider'] ?? billingBlock['provider'],
      ),
      providerLabel: validateHermesBoundedString(
        surface['provider_label'] ?? billingBlock['provider_label'],
        maxCharacters: 80,
      ),
      model: validateHermesOpaqueIdentifier(
        surface['model'] ?? billingBlock['model'],
      ),
      authKind: switch (surface['auth_kind']) {
        'oauth' => 'oauth',
        'api_key' => 'api_key',
        _ => null,
      },
      message:
          sentence(surface['message']) ??
          sentence(limitMap['message']) ??
          sentence(billingBlock['message']),
      resetsAt:
          _epochSeconds(surface['resets_at']) ??
          _epochMilliseconds(limitMap['resets_at_ms']),
      suggestions: [
        if (limitMap['suggestions'] case final List items)
          for (final item in items.take(_kMaxHermesModelSuggestions))
            ?HermesModelSuggestion.fromJson(item),
      ],
      creditsAction: switch (creditsAction) {
        'use_credits' ||
        'add_credits' ||
        'add_credits_and_keep_going' => creditsAction as String,
        _ => null,
      },
      billingUrl: _webUrl(billingBlock['billing_url']),
      partial: payload['partial'] == true,
    );
  }

  /// Reads a surface Conduit stored in message metadata.
  static HermesErrorSurface? fromJson(Object? json) {
    if (json is! Map) return null;
    final layer = _layer(json['layer']);
    final code = validateHermesOpaqueIdentifier(json['code']);
    if (layer == null || code == null) return null;
    final resetsAt = json['resetsAt'];
    return HermesErrorSurface(
      layer: layer,
      code: code,
      retryable: json['retryable'] != false,
      provider: validateHermesOpaqueIdentifier(json['provider']),
      providerLabel: validateHermesBoundedString(
        json['providerLabel'],
        maxCharacters: 80,
      ),
      model: validateHermesOpaqueIdentifier(json['model']),
      authKind: switch (json['authKind']) {
        'oauth' => 'oauth',
        'api_key' => 'api_key',
        _ => null,
      },
      message: validateHermesBoundedString(
        json['message'],
        maxCharacters: _kMaxHermesErrorSentence,
      ),
      resetsAt: resetsAt is String ? DateTime.tryParse(resetsAt) : null,
      suggestions: [
        if (json['suggestions'] case final List items)
          for (final item in items.take(_kMaxHermesModelSuggestions))
            ?HermesModelSuggestion.fromJson(item),
      ],
      creditsAction: switch (json['creditsAction']) {
        'use_credits' ||
        'add_credits' ||
        'add_credits_and_keep_going' => json['creditsAction'] as String,
        _ => null,
      },
      billingUrl: _webUrl(json['billingUrl']),
      partial: json['partial'] == true,
    );
  }

  Map<String, Object?> toJson() => {
    'layer': layer.name,
    'code': code,
    'retryable': retryable,
    'provider': ?provider,
    'providerLabel': ?providerLabel,
    'model': ?model,
    'authKind': ?authKind,
    'message': ?message,
    if (resetsAt != null) 'resetsAt': resetsAt!.toUtc().toIso8601String(),
    if (suggestions.isNotEmpty)
      'suggestions': [for (final item in suggestions) item.toJson()],
    'creditsAction': ?creditsAction,
    'billingUrl': ?billingUrl,
    if (partial) 'partial': true,
  };

  /// The provider's name for a card: its label, else its id.
  String? get providerName => providerLabel ?? provider;

  /// The provider's own settings page, when Hermes knows one.
  String? get providerSettingsUrl =>
      _kHermesProviderSettingsUrls[(provider ?? '').toLowerCase()];

  /// Where Open billing goes: Hermes' billing link, else the Nous portal
  /// for a Nous plan limit.
  String? get billingPageUrl {
    if (billingUrl != null) return billingUrl;
    final nous = (provider ?? 'nous').toLowerCase() == 'nous';
    return code == 'usage_window' || (layer == HermesErrorLayer.billing && nous)
        ? _kHermesProviderSettingsUrls['nous']
        : null;
  }

  HermesErrorKind get kind {
    switch (code) {
      case 'auth' || 'auth_permanent':
        return HermesErrorKind.auth;
      case 'billing' || 'billing_unverified':
        return HermesErrorKind.billing;
      case 'usage_window':
        return HermesErrorKind.usageLimit;
      case 'rate_limit' || 'upstream_rate_limit':
        return HermesErrorKind.rateLimit;
      case 'overloaded' || 'server_error' || 'timeout':
        return layer == HermesErrorLayer.endpoint
            ? HermesErrorKind.endpoint
            : HermesErrorKind.provider;
      case 'ssl_cert_verification' || 'local_runtime_unavailable':
        return HermesErrorKind.endpoint;
      case 'stream_drop':
        return HermesErrorKind.connection;
      case 'context_overflow' || 'payload_too_large':
        return HermesErrorKind.contextOverflow;
      case 'model_not_found':
        return HermesErrorKind.model;
      case 'provider_policy_blocked' ||
          'content_policy_blocked' ||
          'data_policy_denied' ||
          'upstream_blocked':
        return HermesErrorKind.policy;
      case 'truncated':
        return HermesErrorKind.truncated;
      case 'format_error' || 'invalid_response' || 'empty_response':
        return HermesErrorKind.badReply;
      case 'workspace_unavailable':
        return HermesErrorKind.workspace;
      case 'SESSION_NOT_OWNED' ||
          'session_read_only' ||
          'cron_session_read_only' ||
          'launch_credentials_unavailable' ||
          'session_not_found':
        return HermesErrorKind.session;
      case 'SESSION_OWNER_BUSY' ||
          'SESSION_OWNER_UNCONFIRMED' ||
          'session_busy' ||
          'gateway_draining':
        return HermesErrorKind.busy;
      case 'disk_full':
        return HermesErrorKind.disk;
    }
    if (code.startsWith('free_tier_')) return HermesErrorKind.freeTier;
    return switch (layer) {
      HermesErrorLayer.provider =>
        code == 'unknown' ? HermesErrorKind.unknown : HermesErrorKind.provider,
      HermesErrorLayer.endpoint => HermesErrorKind.endpoint,
      HermesErrorLayer.streaming => HermesErrorKind.connection,
      HermesErrorLayer.auth => HermesErrorKind.auth,
      HermesErrorLayer.billing => HermesErrorKind.billing,
      HermesErrorLayer.gateway ||
      HermesErrorLayer.runtime => HermesErrorKind.gateway,
      HermesErrorLayer.disk => HermesErrorKind.disk,
    };
  }

  /// The one action the card offers at [now], or null when nothing Conduit
  /// can do helps (the fix is on the Hermes server).
  ///
  /// Follows Hermes Desktop's table of a main fix and a second option per
  /// failure, and takes the first of the two Conduit can perform.
  HermesErrorAction? actionAt(DateTime now) {
    final (primary, secondary) = _fixes(now);
    return _performable(primary) ?? _performable(secondary);
  }

  /// Whether the chat still works ([HermesErrorSeverity.degraded]) or is
  /// stuck until the cause is fixed, as Hermes Desktop decides it.
  HermesErrorSeverity severityAt(DateTime now) {
    if (code == 'free_tier_model_not_free') return HermesErrorSeverity.degraded;
    if (code == 'agent_init_failed') return HermesErrorSeverity.blocking;
    final (primary, _) = _fixes(now);
    return switch (primary) {
      _Fix.retry ||
      _Fix.retryAtReset ||
      _Fix.continueReply => HermesErrorSeverity.degraded,
      _ => HermesErrorSeverity.blocking,
    };
  }

  /// The reset time when it is still ahead of [now].
  DateTime? upcomingResetAt(DateTime now) {
    final reset = resetsAt;
    return reset != null && reset.isAfter(now) ? reset : null;
  }

  HermesErrorAction? _performable(_Fix? fix) => switch (fix) {
    _Fix.retry || _Fix.retryAtReset => HermesErrorAction.retry,
    _Fix.continueReply => HermesErrorAction.continueReply,
    _Fix.compress => HermesErrorAction.compact,
    _Fix.switchToModel when suggestions.isNotEmpty =>
      HermesErrorAction.switchModel,
    _Fix.useCredits => HermesErrorAction.useCredits,
    _Fix.openBilling when billingPageUrl != null =>
      HermesErrorAction.openBilling,
    _Fix.openProviderSettings when providerSettingsUrl != null =>
      HermesErrorAction.openProviderSettings,
    _Fix.startNewSession => HermesErrorAction.newChat,
    _ => null,
  };

  _Fixes _fixes(DateTime now) {
    if (layer == HermesErrorLayer.auth) {
      return (
        authKind == 'oauth' && provider != null
            ? _Fix.signInAgain
            : _Fix.updateApiKey,
        _Fix.retry,
      );
    }
    if (code == 'local_runtime_unavailable') {
      return retryable
          ? (_Fix.retry, _Fix.switchProvider)
          : (_Fix.switchProvider, null);
    }
    if (layer == HermesErrorLayer.endpoint &&
        (code == 'timeout' || code == 'ssl_cert_verification')) {
      return code == 'timeout'
          ? (_Fix.retry, _Fix.openSetupGuide)
          : (_Fix.openSetupGuide, null);
    }
    if (code == 'usage_window') return _usageWindowFixes(now);
    if (code == 'provider_policy_blocked' && providerSettingsUrl == null) {
      return (_Fix.chooseModel, null);
    }
    final byCode = _kCodeFixes[code];
    if (byCode != null) return byCode;
    if (code.startsWith('free_tier_')) {
      return retryable
          ? (_Fix.signInFreeTier, _Fix.retry)
          : (_Fix.signInFreeTier, null);
    }
    if ((code == 'rate_limit' || code == 'upstream_rate_limit') &&
        upcomingResetAt(now) != null) {
      return (_Fix.retryAtReset, _Fix.retry);
    }
    if (retryable) return (_Fix.retry, null);
    const switchable = {
      HermesErrorLayer.auth,
      HermesErrorLayer.billing,
      HermesErrorLayer.endpoint,
      HermesErrorLayer.provider,
    };
    return (switchable.contains(layer) ? _Fix.switchProvider : null, null);
  }

  _Fixes _usageWindowFixes(DateTime now) {
    final credits = creditsAction == 'use_credits'
        ? _Fix.useCredits
        : _Fix.openBilling;
    if (suggestions.isNotEmpty) return (_Fix.switchToModel, credits);
    if (creditsAction == null) return (credits, _Fix.chooseModel);
    final reset = resetsAt;
    if (reset == null) return (credits, null);
    return reset.isAfter(now)
        ? (credits, _Fix.retryAtReset)
        : (credits, _Fix.retry);
  }
}

/// One main fix and at most one second option per failure code, as Hermes
/// Desktop offers them.
const Map<String, _Fixes> _kCodeFixes = {
  'billing': (_Fix.openBilling, _Fix.switchProvider),
  'content_policy_blocked': (_Fix.editMessage, null),
  'context_overflow': (_Fix.compress, _Fix.startNewSession),
  'disk_full': (_Fix.openHermesFolder, _Fix.retry),
  'free_tier_at_capacity': (_Fix.signInFreeTier, _Fix.retry),
  'format_error': (_Fix.switchProvider, _Fix.startNewSession),
  'free_tier_outage': (_Fix.retry, null),
  'model_not_found': (_Fix.chooseModel, null),
  'payload_too_large': (_Fix.compress, _Fix.startNewSession),
  'provider_policy_blocked': (_Fix.openProviderSettings, _Fix.chooseModel),
  'SESSION_NOT_OWNED': (_Fix.startNewSession, null),
  'ssl_cert_verification': (_Fix.openSetupGuide, null),
  'truncated': (_Fix.continueReply, null),
  'upstream_blocked': (_Fix.switchProvider, null),
  'agent_init_failed': (_Fix.retry, _Fix.openModelSettings),
  'SESSION_OWNER_BUSY': (_Fix.retry, null),
  // It may already be queued: sending it again could run it twice.
  'SESSION_OWNER_UNCONFIRMED': (null, null),
  'cron_session_read_only': (_Fix.startNewSession, null),
  'session_read_only': (_Fix.startNewSession, null),
  'workspace_unavailable': (_Fix.retry, _Fix.startNewSession),
  'launch_credentials_unavailable': (_Fix.startNewSession, null),
  'loop_error': (_Fix.retry, _Fix.startNewSession),
  // Conduit's own codes for API server refusals.
  'session_not_found': (_Fix.startNewSession, null),
  'gateway_draining': (_Fix.retry, null),
};

HermesErrorLayer? _layer(Object? value) {
  if (value is! String) return null;
  for (final layer in HermesErrorLayer.values) {
    if (layer.name == value) return layer;
  }
  return null;
}

String? _sentence(Object? value, Iterable<String> sensitiveValues) {
  final text = validateHermesBoundedString(
    value,
    maxCharacters: _kMaxHermesErrorSentence * 4,
  );
  if (text == null) return null;
  final safe = sanitizeProviderErrorMessage(
    text,
    fallback: '',
    sensitiveValues: sensitiveValues,
    maxCharacters: _kMaxHermesErrorSentence,
  );
  return safe.isEmpty || safe == '[REDACTED]' ? null : safe;
}

DateTime? _epochSeconds(Object? value) {
  if (value is! num || value is bool || !value.isFinite || value <= 0) {
    return null;
  }
  return _bounded((value * 1000).round());
}

DateTime? _epochMilliseconds(Object? value) {
  if (value is! num || !value.isFinite || value <= 0) return null;
  return _bounded(value.round());
}

/// Rejects a reset time a provider could not mean (past the year 9999).
DateTime? _bounded(int milliseconds) => milliseconds > 253402300799000
    ? null
    : DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);

String? _webUrl(Object? value) {
  final text = validateHermesBoundedString(value, maxCharacters: 2048);
  if (text == null) return null;
  final uri = Uri.tryParse(text);
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
      ? text
      : null;
}
