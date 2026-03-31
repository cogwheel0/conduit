import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import 'backend_config.dart';

part 'server_config.freezed.dart';
part 'server_config.g.dart';

/// Container for passing server and backend config during authentication flow.
@immutable
class AuthFlowConfig {
  const AuthFlowConfig({required this.serverConfig, this.backendConfig});

  /// The server configuration (URL, headers, etc.).
  final ServerConfig serverConfig;

  /// The backend configuration (auth methods, features, etc.).
  /// May be null if not yet fetched.
  final BackendConfig? backendConfig;
}

@freezed
sealed class ServerConfig with _$ServerConfig {
  const factory ServerConfig({
    required String id,
    required String name,
    required String url,
    String? apiKey,
    @Default({}) Map<String, String> customHeaders,
    DateTime? lastConnected,
    @Default(false) bool isActive,

    /// Whether to trust self-signed TLS certificates for this server.
    @Default(false) bool allowSelfSignedCertificates,

    /// PEM-encoded client certificate chain used for mTLS authentication.
    String? mtlsCertificateChainPem,

    /// Display label for the selected mTLS certificate file.
    String? mtlsCertificateLabel,

    /// PEM-encoded private key paired with [mtlsCertificateChainPem].
    String? mtlsPrivateKeyPem,

    /// Display label for the selected mTLS private key file.
    String? mtlsPrivateKeyLabel,

    /// Optional passphrase for the selected mTLS private key.
    String? mtlsPrivateKeyPassword,
  }) = _ServerConfig;

  factory ServerConfig.fromJson(Map<String, dynamic> json) =>
      _$ServerConfigFromJson(json);
}

extension ServerConfigTls on ServerConfig {
  /// Whether both client certificate inputs are present for mTLS.
  bool get hasMutualTlsCredentials {
    final certificate = mtlsCertificateChainPem?.trim();
    final privateKey = mtlsPrivateKeyPem?.trim();
    return certificate != null &&
        certificate.isNotEmpty &&
        privateKey != null &&
        privateKey.isNotEmpty;
  }

  /// Whether the configuration requires a custom `dart:io` TLS client.
  bool get needsCustomTlsClient =>
      allowSelfSignedCertificates || hasMutualTlsCredentials;
}
