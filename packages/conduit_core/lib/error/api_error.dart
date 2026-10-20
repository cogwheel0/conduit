import 'package:collection/collection.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:meta/meta.dart';

/// Standardized API error representation
/// Provides consistent error information across all API operations
@immutable
class ApiError implements Exception {
  const ApiError._({
    required this.type,
    required this.messageCode,
    this.message,
    this.endpoint,
    this.method,
    this.statusCode,
    this.details,
    this.fieldErrors = const {},
    this.originalError,
    this.technical,
    this.retryAfter,
    this.timeoutDuration,
  });

  // Factory constructors for different error types
  const ApiError.network({
    String? message,
    ErrorMessage messageCode = const ErrorMessage(CoreErrorCode.networkGeneric),
    String? endpoint,
    String? method,
    dynamic originalError,
    String? technical,
  }) : this._(
         type: ApiErrorType.network,
         messageCode: messageCode,
         message: message,
         endpoint: endpoint,
         method: method,
         originalError: originalError,
         technical: technical,
       );

  const ApiError.timeout({
    String? message,
    ErrorMessage messageCode = const ErrorMessage(CoreErrorCode.networkTimeout),
    String? endpoint,
    String? method,
    Duration? timeoutDuration,
  }) : this._(
         type: ApiErrorType.timeout,
         messageCode: messageCode,
         message: message,
         endpoint: endpoint,
         method: method,
         timeoutDuration: timeoutDuration,
       );

  const ApiError.authentication({
    String? message,
    ErrorMessage messageCode = const ErrorMessage(
      CoreErrorCode.authSessionExpired,
    ),
    String? endpoint,
    String? method,
    int? statusCode,
  }) : this._(
         type: ApiErrorType.authentication,
         messageCode: messageCode,
         message: message,
         endpoint: endpoint,
         method: method,
         statusCode: statusCode,
       );

  const ApiError.authorization({
    String? message,
    ErrorMessage messageCode = const ErrorMessage(CoreErrorCode.authForbidden),
    String? endpoint,
    String? method,
    int? statusCode,
  }) : this._(
         type: ApiErrorType.authorization,
         messageCode: messageCode,
         message: message,
         endpoint: endpoint,
         method: method,
         statusCode: statusCode,
       );

  const ApiError.validation({
    String? message,
    ErrorMessage messageCode = const ErrorMessage(
      CoreErrorCode.validationGeneric,
    ),
    String? endpoint,
    String? method,
    Map<String, List<String>> fieldErrors = const {},
    ParsedErrorResponse? details,
  }) : this._(
         type: ApiErrorType.validation,
         messageCode: messageCode,
         message: message,
         endpoint: endpoint,
         method: method,
         statusCode: 422,
         fieldErrors: fieldErrors,
         details: details,
       );

  const ApiError.badRequest({
    String? message,
    ErrorMessage messageCode = const ErrorMessage(
      CoreErrorCode.validationGeneric,
    ),
    String? endpoint,
    String? method,
    ParsedErrorResponse? details,
  }) : this._(
         type: ApiErrorType.badRequest,
         messageCode: messageCode,
         message: message,
         endpoint: endpoint,
         method: method,
         statusCode: 400,
         details: details,
       );

  const ApiError.notFound({
    String? message,
    ErrorMessage messageCode = const ErrorMessage(CoreErrorCode.fileNotFound),
    String? endpoint,
    String? method,
    int? statusCode,
  }) : this._(
         type: ApiErrorType.notFound,
         messageCode: messageCode,
         message: message,
         endpoint: endpoint,
         method: method,
         statusCode: statusCode ?? 404,
       );

  const ApiError.server({
    String? message,
    ErrorMessage messageCode = const ErrorMessage(CoreErrorCode.serverGeneric),
    String? endpoint,
    String? method,
    int? statusCode,
    ParsedErrorResponse? details,
  }) : this._(
         type: ApiErrorType.server,
         messageCode: messageCode,
         message: message,
         endpoint: endpoint,
         method: method,
         statusCode: statusCode,
         details: details,
       );

  const ApiError.rateLimit({
    String? message,
    ErrorMessage messageCode = const ErrorMessage(
      CoreErrorCode.rateLimitExceeded,
    ),
    String? endpoint,
    String? method,
    int? statusCode,
    Duration? retryAfter,
  }) : this._(
         type: ApiErrorType.rateLimit,
         messageCode: messageCode,
         message: message,
         endpoint: endpoint,
         method: method,
         statusCode: statusCode ?? 429,
         retryAfter: retryAfter,
       );

  const ApiError.cancelled({
    String? message,
    ErrorMessage messageCode = const ErrorMessage(CoreErrorCode.generic),
    String? endpoint,
    String? method,
  }) : this._(
         type: ApiErrorType.cancelled,
         messageCode: messageCode,
         message: message,
         endpoint: endpoint,
         method: method,
       );

  const ApiError.security({
    String? message,
    ErrorMessage messageCode = const ErrorMessage(
      CoreErrorCode.securityCertificate,
    ),
    String? endpoint,
    String? method,
  }) : this._(
         type: ApiErrorType.security,
         messageCode: messageCode,
         message: message,
         endpoint: endpoint,
         method: method,
       );

  const ApiError.unknown({
    String? message,
    ErrorMessage messageCode = const ErrorMessage(CoreErrorCode.generic),
    String? endpoint,
    String? method,
    dynamic originalError,
    String? technical,
  }) : this._(
         type: ApiErrorType.unknown,
         messageCode: messageCode,
         message: message,
         endpoint: endpoint,
         method: method,
         originalError: originalError,
         technical: technical,
       );

  const ApiError.client({
    String? message,
    ErrorMessage messageCode = const ErrorMessage(CoreErrorCode.generic),
    String? endpoint,
    String? method,
    int? statusCode,
    ParsedErrorResponse? details,
  }) : this._(
         type: ApiErrorType.badRequest,
         messageCode: messageCode,
         message: message,
         endpoint: endpoint,
         method: method,
         statusCode: statusCode,
         details: details,
       );

  final ApiErrorType type;

  /// Server-supplied prose, when the API returned any.
  ///
  /// Null for failures the core classified itself: the core has no locale and
  /// must not invent English. Render with `resolveApiErrorMessage`
  /// from lib/shared, which falls back to [messageCode].
  final String? message;

  /// The core's own classification. Always present, always localizable.
  final ErrorMessage messageCode;
  final String? endpoint;
  final String? method;
  final int? statusCode;
  final ParsedErrorResponse? details;
  final Map<String, List<String>> fieldErrors;
  final dynamic originalError;
  final String? technical;
  final Duration? retryAfter;
  final Duration? timeoutDuration;

  /// Check if this error has field-specific validation errors
  bool get hasFieldErrors => fieldErrors.isNotEmpty;

  /// Check if this error is retryable
  bool get isRetryable {
    switch (type) {
      case ApiErrorType.network:
      case ApiErrorType.timeout:
      case ApiErrorType.server:
      case ApiErrorType.rateLimit:
        return true;
      case ApiErrorType.authentication:
      case ApiErrorType.authorization:
      case ApiErrorType.validation:
      case ApiErrorType.badRequest:
      case ApiErrorType.notFound:
      case ApiErrorType.cancelled:
      case ApiErrorType.security:
      case ApiErrorType.unknown:
        return false;
    }
  }

  /// Get all field error messages as a flattened list
  List<String> get allFieldErrorMessages {
    final messages = <String>[];
    for (final entry in fieldErrors.entries) {
      final field = entry.key;
      final errors = entry.value;
      for (final error in errors) {
        messages.add('$field: $error');
      }
    }
    return messages;
  }

  /// Get first field error message for quick display
  String? get firstFieldError {
    if (fieldErrors.isEmpty) return null;
    final firstEntry = fieldErrors.entries.first;
    final field = firstEntry.key;
    final firstError = firstEntry.value.first;
    return '$field: $firstError';
  }

  /// Create a copy with updated fields
  ApiError copyWith({
    ApiErrorType? type,
    ErrorMessage? messageCode,
    String? message,
    String? endpoint,
    String? method,
    int? statusCode,
    ParsedErrorResponse? details,
    Map<String, List<String>>? fieldErrors,
    dynamic originalError,
    String? technical,
    Duration? retryAfter,
    Duration? timeoutDuration,
  }) {
    return ApiError._(
      type: type ?? this.type,
      messageCode: messageCode ?? this.messageCode,
      message: message ?? this.message,
      endpoint: endpoint ?? this.endpoint,
      method: method ?? this.method,
      statusCode: statusCode ?? this.statusCode,
      details: details ?? this.details,
      fieldErrors: fieldErrors ?? this.fieldErrors,
      originalError: originalError ?? this.originalError,
      technical: technical ?? this.technical,
      retryAfter: retryAfter ?? this.retryAfter,
      timeoutDuration: timeoutDuration ?? this.timeoutDuration,
    );
  }

  /// Convert to map for logging and debugging
  Map<String, dynamic> toMap() {
    return {
      'type': type.name,
      'message': message,
      'endpoint': endpoint,
      'method': method,
      'statusCode': statusCode,
      'fieldErrors': fieldErrors,
      'technical': technical,
      'retryAfter': retryAfter?.inSeconds,
      'timeoutDuration': timeoutDuration?.inSeconds,
      'isRetryable': isRetryable,
      'hasFieldErrors': hasFieldErrors,
    };
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.write('ApiError(');
    buffer.write('type: ${type.name}, ');
    buffer.write('message: $message');

    if (endpoint != null) {
      buffer.write(', endpoint: $endpoint');
    }

    if (method != null) {
      buffer.write(', method: $method');
    }

    if (statusCode != null) {
      buffer.write(', statusCode: $statusCode');
    }

    if (hasFieldErrors) {
      buffer.write(', fieldErrors: ${fieldErrors.length}');
    }

    buffer.write(')');
    return buffer.toString();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is ApiError &&
        other.type == type &&
        other.message == message &&
        other.endpoint == endpoint &&
        other.method == method &&
        other.statusCode == statusCode &&
        const DeepCollectionEquality().equals(other.fieldErrors, fieldErrors);
  }

  @override
  int get hashCode {
    return Object.hash(
      type,
      message,
      endpoint,
      method,
      statusCode,
      fieldErrors,
    );
  }
}

/// Types of API errors for categorization and handling
enum ApiErrorType {
  network, // Connection issues, DNS resolution, etc.
  timeout, // Request timeout (send, receive, connection)
  authentication, // 401, invalid credentials, expired tokens
  authorization, // 403, insufficient permissions
  validation, // 422, field validation errors
  badRequest, // 400, malformed request
  notFound, // 404, resource not found
  server, // 5xx server errors
  rateLimit, // 429, too many requests
  cancelled, // Request was cancelled
  security, // Certificate, SSL/TLS issues
  unknown, // Unexpected or unhandled errors
}

/// Parsed error response from API
/// Contains structured error information from server responses
class ParsedErrorResponse {
  const ParsedErrorResponse({
    this.message,
    this.code,
    this.errors = const [],
    this.fieldErrors = const {},
    this.metadata = const {},
  });

  final String? message;
  final String? code;
  final List<String> errors;
  final Map<String, List<String>> fieldErrors;
  final Map<String, dynamic> metadata;

  bool get hasFieldErrors => fieldErrors.isNotEmpty;
  bool get hasGeneralErrors => errors.isNotEmpty;

  @override
  String toString() {
    return 'ParsedErrorResponse(message: $message, errors: ${errors.length}, fieldErrors: ${fieldErrors.length})';
  }
}
