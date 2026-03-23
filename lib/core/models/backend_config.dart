import 'package:flutter/foundation.dart';

/// Represents the available OAuth providers configured on the server.
@immutable
class OAuthProviders {
  const OAuthProviders({
    this.google,
    this.microsoft,
    this.github,
    this.oidc,
    this.feishu,
  });

  /// Google OAuth provider name (if enabled).
  final String? google;

  /// Microsoft OAuth provider name (if enabled).
  final String? microsoft;

  /// GitHub OAuth provider name (if enabled).
  final String? github;

  /// Generic OIDC provider name (if enabled).
  final String? oidc;

  /// Feishu OAuth provider name (if enabled).
  final String? feishu;

  /// Whether any OAuth provider is enabled.
  bool get hasAnyProvider =>
      google != null ||
      microsoft != null ||
      github != null ||
      oidc != null ||
      feishu != null;

  /// Returns the list of enabled provider keys.
  List<String> get enabledProviders => [
    if (google != null) 'google',
    if (microsoft != null) 'microsoft',
    if (github != null) 'github',
    if (oidc != null) 'oidc',
    if (feishu != null) 'feishu',
  ];

  /// Returns the display name for a provider.
  String getProviderDisplayName(String key) {
    return switch (key) {
      'google' => google ?? 'Google',
      'microsoft' => microsoft ?? 'Microsoft',
      'github' => github ?? 'GitHub',
      'oidc' => oidc ?? 'SSO',
      'feishu' => feishu ?? 'Feishu',
      _ => key,
    };
  }

  factory OAuthProviders.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const OAuthProviders();
    return OAuthProviders(
      google: json['google'] as String?,
      microsoft: json['microsoft'] as String?,
      github: json['github'] as String?,
      oidc: json['oidc'] as String?,
      feishu: json['feishu'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    if (google != null) 'google': google,
    if (microsoft != null) 'microsoft': microsoft,
    if (github != null) 'github': github,
    if (oidc != null) 'oidc': oidc,
    if (feishu != null) 'feishu': feishu,
  };
}

/// Describes a server TTS voice exposed by the backend.
@immutable
class BackendTtsVoice {
  const BackendTtsVoice({required this.id, required this.name, this.locale});

  final String id;
  final String name;
  final String? locale;

  factory BackendTtsVoice.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] ?? json['name'] ?? '').toString().trim();
    final name = (json['name'] ?? json['id'] ?? '').toString().trim();
    final locale = (json['locale'] ?? json['language'])?.toString().trim();

    return BackendTtsVoice(
      id: id,
      name: name.isNotEmpty ? name : id,
      locale: locale != null && locale.isNotEmpty ? locale : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (locale != null) 'locale': locale,
  };
}

/// Subset of the backend `/api/config` response the app cares about.
@immutable
class BackendConfig {
  const BackendConfig({
    this.enableWebsocket,
    this.enableAudioInput,
    this.enableAudioOutput,
    this.sttProvider,
    this.ttsProvider,
    this.ttsVoice,
    this.ttsSplitOn,
    this.ttsVoices = const [],
    this.defaultSttLocale,
    this.audioSampleRate,
    this.audioFrameSize,
    this.vadEnabled,
    this.oauthProviders = const OAuthProviders(),
    this.enableLdap = false,
    this.enableLoginForm = true,
  });

  /// Mirrors `features.enable_websocket` from OpenWebUI.
  final bool? enableWebsocket;
  final bool? enableAudioInput;
  final bool? enableAudioOutput;
  final String? sttProvider;
  final String? ttsProvider;
  final String? ttsVoice;
  final String? ttsSplitOn;
  final List<BackendTtsVoice> ttsVoices;
  final String? defaultSttLocale;
  final int? audioSampleRate;
  final int? audioFrameSize;
  final bool? vadEnabled;

  /// OAuth providers configured on the server.
  final OAuthProviders oauthProviders;

  /// Whether LDAP authentication is enabled on the server.
  final bool enableLdap;

  /// Whether the standard login form (email/password) is enabled.
  final bool enableLoginForm;

  /// Whether SSO (OAuth) login is available.
  bool get hasSsoEnabled => oauthProviders.hasAnyProvider;

  /// Returns a copy with updated fields.
  BackendConfig copyWith({
    bool? enableWebsocket,
    bool? enableAudioInput,
    bool? enableAudioOutput,
    String? sttProvider,
    String? ttsProvider,
    String? ttsVoice,
    String? ttsSplitOn,
    List<BackendTtsVoice>? ttsVoices,
    String? defaultSttLocale,
    int? audioSampleRate,
    int? audioFrameSize,
    bool? vadEnabled,
    OAuthProviders? oauthProviders,
    bool? enableLdap,
    bool? enableLoginForm,
  }) {
    return BackendConfig(
      enableWebsocket: enableWebsocket ?? this.enableWebsocket,
      enableAudioInput: enableAudioInput ?? this.enableAudioInput,
      enableAudioOutput: enableAudioOutput ?? this.enableAudioOutput,
      sttProvider: sttProvider ?? this.sttProvider,
      ttsProvider: ttsProvider ?? this.ttsProvider,
      ttsVoice: ttsVoice ?? this.ttsVoice,
      ttsSplitOn: ttsSplitOn ?? this.ttsSplitOn,
      ttsVoices: ttsVoices ?? this.ttsVoices,
      defaultSttLocale: defaultSttLocale ?? this.defaultSttLocale,
      audioSampleRate: audioSampleRate ?? this.audioSampleRate,
      audioFrameSize: audioFrameSize ?? this.audioFrameSize,
      vadEnabled: vadEnabled ?? this.vadEnabled,
      oauthProviders: oauthProviders ?? this.oauthProviders,
      enableLdap: enableLdap ?? this.enableLdap,
      enableLoginForm: enableLoginForm ?? this.enableLoginForm,
    );
  }

  /// Whether the backend only allows WebSocket transport.
  bool get websocketOnly => enableWebsocket == true;

  /// Whether the backend only allows HTTP polling transport.
  bool get pollingOnly => enableWebsocket == false;

  /// Whether the backend permits choosing WebSocket-only mode.
  bool get supportsWebsocketOnly => !pollingOnly;

  /// Whether the backend permits choosing polling fallback.
  bool get supportsPolling => !websocketOnly;

  /// Returns the enforced transport mode derived from backend policy.
  String? get enforcedTransportMode {
    if (websocketOnly) return 'ws';
    if (pollingOnly) return 'polling';
    return null;
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'enable_websocket': enableWebsocket,
      'enable_audio_input': enableAudioInput,
      'enable_audio_output': enableAudioOutput,
      'stt_provider': sttProvider,
      'tts_provider': ttsProvider,
      'tts_voice': ttsVoice,
      'tts_split_on': ttsSplitOn,
      'tts_voices': ttsVoices.map((voice) => voice.toJson()).toList(),
      'default_stt_locale': defaultSttLocale,
      'audio_sample_rate': audioSampleRate,
      'audio_frame_size': audioFrameSize,
      'vad_enabled': vadEnabled,
      'oauth': {'providers': oauthProviders.toJson()},
      'enable_ldap': enableLdap,
      'enable_login_form': enableLoginForm,
    };
  }

  static BackendConfig fromJson(Map<String, dynamic> json) {
    bool? enableWebsocket;
    bool? enableAudioInput;
    bool? enableAudioOutput;
    String? sttProvider;
    String? ttsProvider;
    String? ttsVoice;
    String? ttsSplitOn;
    List<BackendTtsVoice> ttsVoices = const [];
    String? defaultSttLocale;
    int? audioSampleRate;
    int? audioFrameSize;
    bool? vadEnabled;
    OAuthProviders oauthProviders = const OAuthProviders();
    bool enableLdap = false;
    bool enableLoginForm = true;

    // Try canonical format first
    final value = json['enable_websocket'];
    if (value is bool) {
      enableWebsocket = value;
    }

    final audioIn = json['enable_audio_input'];
    if (audioIn is bool) enableAudioInput = audioIn;
    final audioOut = json['enable_audio_output'];
    if (audioOut is bool) enableAudioOutput = audioOut;

    final stt = json['stt_provider'];
    if (stt is String) sttProvider = stt;
    final tts = json['tts_provider'];
    if (tts is String) ttsProvider = tts;
    final ttsVoiceValue = json['tts_voice'];
    if (ttsVoiceValue is String) ttsVoice = ttsVoiceValue;
    final ttsSplitOnValue = json['tts_split_on'];
    if (ttsSplitOnValue is String) ttsSplitOn = ttsSplitOnValue;
    final ttsVoicesValue = json['tts_voices'];
    if (ttsVoicesValue is List) {
      ttsVoices = ttsVoicesValue
          .whereType<Map>()
          .map(
            (voice) => BackendTtsVoice.fromJson(voice.cast<String, dynamic>()),
          )
          .where((voice) => voice.id.isNotEmpty || voice.name.isNotEmpty)
          .toList(growable: false);
    }

    final defaultLocale = json['default_stt_locale'];
    if (defaultLocale is String) defaultSttLocale = defaultLocale;

    final sampleRate = json['audio_sample_rate'];
    if (sampleRate is int) audioSampleRate = sampleRate;
    final frameSize = json['audio_frame_size'];
    if (frameSize is int) audioFrameSize = frameSize;

    final vad = json['vad_enabled'];
    if (vad is bool) vadEnabled = vad;

    // Parse OAuth providers from top-level oauth.providers
    final oauth = json['oauth'];
    if (oauth is Map<String, dynamic>) {
      final providers = oauth['providers'];
      if (providers is Map<String, dynamic>) {
        oauthProviders = OAuthProviders.fromJson(providers);
      }
    }

    // Parse auth features from top-level
    final ldapValue = json['enable_ldap'];
    if (ldapValue is bool) enableLdap = ldapValue;
    final loginFormValue = json['enable_login_form'];
    if (loginFormValue is bool) enableLoginForm = loginFormValue;

    // Fallback to nested format for backwards compatibility
    final features = json['features'];
    if (features is Map<String, dynamic>) {
      final nestedValue = features['enable_websocket'];
      if (nestedValue is bool && enableWebsocket == null) {
        enableWebsocket = nestedValue;
      }
      final nestedAudioIn = features['enable_audio_input'];
      if (nestedAudioIn is bool && enableAudioInput == null) {
        enableAudioInput = nestedAudioIn;
      }
      final nestedAudioOut = features['enable_audio_output'];
      if (nestedAudioOut is bool && enableAudioOutput == null) {
        enableAudioOutput = nestedAudioOut;
      }
      final nestedStt = features['stt_provider'];
      if (nestedStt is String && sttProvider == null) {
        sttProvider = nestedStt;
      }
      final nestedTts = features['tts_provider'];
      if (nestedTts is String && ttsProvider == null) {
        ttsProvider = nestedTts;
      }
      final nestedVoice = features['tts_voice'];
      if (nestedVoice is String && ttsVoice == null) {
        ttsVoice = nestedVoice;
      }
      final nestedSplitOn = features['tts_split_on'];
      if (nestedSplitOn is String && ttsSplitOn == null) {
        ttsSplitOn = nestedSplitOn;
      }
      final nestedVoices = features['tts_voices'];
      if (nestedVoices is List && ttsVoices.isEmpty) {
        ttsVoices = nestedVoices
            .whereType<Map>()
            .map(
              (voice) =>
                  BackendTtsVoice.fromJson(voice.cast<String, dynamic>()),
            )
            .where((voice) => voice.id.isNotEmpty || voice.name.isNotEmpty)
            .toList(growable: false);
      }
      final nestedLocale = features['default_stt_locale'];
      if (nestedLocale is String && defaultSttLocale == null) {
        defaultSttLocale = nestedLocale;
      }
      final nestedSample = features['audio_sample_rate'];
      if (nestedSample is int && audioSampleRate == null) {
        audioSampleRate = nestedSample;
      }
      final nestedFrame = features['audio_frame_size'];
      if (nestedFrame is int && audioFrameSize == null) {
        audioFrameSize = nestedFrame;
      }
      final nestedVad = features['vad_enabled'];
      if (nestedVad is bool && vadEnabled == null) {
        vadEnabled = nestedVad;
      }
      // Auth features in nested format
      final nestedLdap = features['enable_ldap'];
      if (nestedLdap is bool) enableLdap = nestedLdap;
      final nestedLoginForm = features['enable_login_form'];
      if (nestedLoginForm is bool) enableLoginForm = nestedLoginForm;
    }

    return BackendConfig(
      enableWebsocket: enableWebsocket,
      enableAudioInput: enableAudioInput,
      enableAudioOutput: enableAudioOutput,
      sttProvider: sttProvider,
      ttsProvider: ttsProvider,
      ttsVoice: ttsVoice,
      ttsSplitOn: ttsSplitOn,
      ttsVoices: ttsVoices,
      defaultSttLocale: defaultSttLocale,
      audioSampleRate: audioSampleRate,
      audioFrameSize: audioFrameSize,
      vadEnabled: vadEnabled,
      oauthProviders: oauthProviders,
      enableLdap: enableLdap,
      enableLoginForm: enableLoginForm,
    );
  }
}
