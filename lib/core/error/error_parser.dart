import 'dart:convert';
import 'dart:typed_data';

import 'api_error.dart';
import '../utils/current_localizations.dart';
import '../utils/debug_logger.dart';

/// Comprehensive error response parser
/// Handles various API error response formats and extracts structured information
class ErrorParser {
  /// Parse general error response from API
  ParsedErrorResponse parseErrorResponse(dynamic responseData) {
    if (responseData == null) {
      return const ParsedErrorResponse();
    }

    try {
      final decoded = _decodeBinaryPayload(responseData);
      if (decoded != null) {
        return parseErrorResponse(decoded);
      }

      if (responseData is Map<String, dynamic>) {
        return _parseErrorMap(responseData);
      } else if (responseData is String) {
        return _parseErrorString(responseData);
      } else if (responseData is List) {
        return _parseErrorList(responseData);
      } else {
        return ParsedErrorResponse(
          message: currentAppLocalizations().errorMessage,
          metadata: {'rawData': responseData.toString()},
        );
      }
    } catch (e) {
      DebugLogger.log(
        'ErrorParser: Error parsing response: $e',
        scope: 'api/error-parser',
      );
      return ParsedErrorResponse(
        message: currentAppLocalizations().errorMessage,
        metadata: {
          'parseError': e.toString(),
          'rawData': responseData.toString(),
        },
      );
    }
  }

  dynamic _decodeBinaryPayload(dynamic responseData) {
    Uint8List? bytes;
    if (responseData is Uint8List) {
      bytes = responseData;
    } else if (responseData is List<int>) {
      bytes = Uint8List.fromList(responseData);
    } else if (responseData is List &&
        responseData.every((item) => item is int)) {
      bytes = Uint8List.fromList(responseData.cast<int>());
    }

    if (bytes == null || bytes.isEmpty) {
      return null;
    }

    try {
      final text = utf8.decode(bytes).trim();
      if (text.isEmpty) {
        return null;
      }

      if (text.startsWith('{') || text.startsWith('[')) {
        final decoded = json.decode(text);
        if (decoded is Map<String, dynamic> ||
            decoded is List ||
            decoded is String) {
          return decoded;
        }
      }

      return text;
    } catch (_) {
      return null;
    }
  }

  /// Parse validation error (422) with field-specific errors
  ParsedErrorResponse parseValidationError(dynamic responseData) {
    final baseResult = parseErrorResponse(responseData);

    if (responseData is Map<String, dynamic>) {
      final fieldErrors = _extractFieldErrors(responseData);

      return ParsedErrorResponse(
        message: baseResult.message ?? 'Validation failed',
        code: baseResult.code,
        errors: baseResult.errors,
        fieldErrors: fieldErrors,
        metadata: baseResult.metadata,
      );
    }

    return baseResult;
  }

  /// Parse error response from a Map (most common format)
  ParsedErrorResponse _parseErrorMap(Map<String, dynamic> data) {
    final message = _extractMessage(data);
    final code = _extractCode(data);
    final errors = _extractGeneralErrors(data);
    final fieldErrors = _extractFieldErrors(data);
    final metadata = _extractMetadata(data);

    return ParsedErrorResponse(
      message: message,
      code: code,
      errors: errors,
      fieldErrors: fieldErrors,
      metadata: metadata,
    );
  }

  /// Parse error response from a String
  ParsedErrorResponse _parseErrorString(String data) {
    return ParsedErrorResponse(message: data, metadata: {'format': 'string'});
  }

  /// Parse error response from a List
  ParsedErrorResponse _parseErrorList(List<dynamic> data) {
    final errors = <String>[];

    for (final item in data) {
      if (item is String) {
        errors.add(item);
      } else if (item is Map<String, dynamic>) {
        final message = _extractMessage(item);
        if (message != null) {
          errors.add(message);
        }
      } else {
        errors.add(item.toString());
      }
    }

    return ParsedErrorResponse(
      message: errors.isNotEmpty
          ? errors.first
          : currentAppLocalizations().errorMessage,
      errors: errors,
      metadata: {'format': 'list', 'count': data.length},
    );
  }

  /// Extract error message from various possible fields
  String? _extractMessage(Map<String, dynamic> data) {
    // Common error message fields in order of preference
    const messageFields = [
      'message',
      'error',
      'detail',
      'description',
      'msg',
      'error_description',
      'title',
      'summary',
    ];

    for (final field in messageFields) {
      final value = data[field];
      if (value is String && value.isNotEmpty) {
        return value;
      }
    }

    return null;
  }

  /// Extract error code from response
  String? _extractCode(Map<String, dynamic> data) {
    const codeFields = [
      'code',
      'error_code',
      'errorCode',
      'type',
      'error_type',
      'errorType',
    ];

    for (final field in codeFields) {
      final value = data[field];
      if (value is String && value.isNotEmpty) {
        return value;
      } else if (value is int) {
        return value.toString();
      }
    }

    return null;
  }

  /// Extract general error messages (non-field-specific)
  List<String> _extractGeneralErrors(Map<String, dynamic> data) {
    final errors = <String>[];

    // Check for error arrays
    const errorArrayFields = ['errors', 'messages', 'details', 'issues'];

    for (final field in errorArrayFields) {
      final value = data[field];
      if (value is List) {
        for (final item in value) {
          if (item is String && item.isNotEmpty) {
            errors.add(item);
          } else if (item is Map<String, dynamic>) {
            final message = _extractMessage(item);
            if (message != null) {
              errors.add(message);
            }
          }
        }
      }
    }

    return errors;
  }

  /// Extract field-specific validation errors
  Map<String, List<String>> _extractFieldErrors(Map<String, dynamic> data) {
    final fieldErrors = <String, List<String>>{};

    // Common patterns for field errors
    _extractFromFieldErrorsObject(data, fieldErrors);
    _extractFromValidationErrorsArray(data, fieldErrors);
    _extractFromDetailsObject(data, fieldErrors);
    _extractFromOpenAPIFormat(data, fieldErrors);

    return fieldErrors;
  }

  /// Extract from 'field_errors' or 'fieldErrors' object
  void _extractFromFieldErrorsObject(
    Map<String, dynamic> data,
    Map<String, List<String>> fieldErrors,
  ) {
    const fieldErrorFields = [
      'field_errors',
      'fieldErrors',
      'validation_errors',
      'validationErrors',
      'field_messages',
      'fieldMessages',
    ];

    for (final field in fieldErrorFields) {
      final value = data[field];
      if (value is Map<String, dynamic>) {
        for (final entry in value.entries) {
          final fieldName = entry.key;
          final fieldValue = entry.value;

          final errors = <String>[];
          if (fieldValue is String) {
            errors.add(fieldValue);
          } else if (fieldValue is List) {
            for (final item in fieldValue) {
              if (item is String) {
                errors.add(item);
              } else {
                errors.add(item.toString());
              }
            }
          }

          if (errors.isNotEmpty) {
            fieldErrors[fieldName] = errors;
          }
        }
      }
    }
  }

  /// Extract from validation errors array format
  void _extractFromValidationErrorsArray(
    Map<String, dynamic> data,
    Map<String, List<String>> fieldErrors,
  ) {
    const arrayFields = ['errors', 'details', 'issues'];

    for (final field in arrayFields) {
      final value = data[field];
      if (value is List) {
        for (final item in value) {
          if (item is Map<String, dynamic>) {
            final field =
                item['field'] as String? ??
                item['property'] as String? ??
                item['path'] as String?;
            final message = _extractMessage(item);

            if (field != null && message != null) {
              fieldErrors.putIfAbsent(field, () => []).add(message);
            }
          }
        }
      }
    }
  }

  /// Extract from 'details' object (common in some APIs)
  void _extractFromDetailsObject(
    Map<String, dynamic> data,
    Map<String, List<String>> fieldErrors,
  ) {
    final details = data['details'];
    if (details is Map<String, dynamic>) {
      for (final entry in details.entries) {
        final fieldName = entry.key;
        final fieldValue = entry.value;

        if (fieldValue is String) {
          fieldErrors.putIfAbsent(fieldName, () => []).add(fieldValue);
        } else if (fieldValue is List) {
          final errors = fieldValue
              .map((e) => e.toString())
              .where((s) => s.isNotEmpty)
              .toList();
          if (errors.isNotEmpty) {
            fieldErrors[fieldName] = errors;
          }
        }
      }
    }
  }

  /// Extract from OpenAPI specification error format
  void _extractFromOpenAPIFormat(
    Map<String, dynamic> data,
    Map<String, List<String>> fieldErrors,
  ) {
    // OpenAPI validation errors often come in this format
    final detail = data['detail'];
    if (detail is List) {
      for (final item in detail) {
        if (item is Map<String, dynamic>) {
          final loc = item['loc'];
          final msg = item['msg'] as String?;

          if (loc is List && loc.isNotEmpty && msg != null) {
            // Location can be like ['body', 'fieldName'] or ['fieldName']
            final fieldName = loc.last.toString();
            fieldErrors.putIfAbsent(fieldName, () => []).add(msg);
          }
        }
      }
    }
  }

  /// Extract additional metadata from error response
  Map<String, dynamic> _extractMetadata(Map<String, dynamic> data) {
    final metadata = <String, dynamic>{};

    // Common metadata fields
    const metadataFields = [
      'timestamp',
      'request_id',
      'requestId',
      'trace_id',
      'traceId',
      'correlation_id',
      'correlationId',
      'instance',
      'path',
      'method',
      'status',
      'documentation',
      'help',
      'support',
    ];

    for (final field in metadataFields) {
      final value = data[field];
      if (value != null) {
        metadata[field] = value;
      }
    }

    // Include any unrecognized fields as metadata
    final recognizedFields = {
      'message',
      'error',
      'detail',
      'description',
      'msg',
      'error_description',
      'title',
      'summary',
      'code',
      'error_code',
      'errorCode',
      'type',
      'error_type',
      'errorType',
      'errors',
      'messages',
      'details',
      'issues',
      'field_errors',
      'fieldErrors',
      'validation_errors',
      'validationErrors',
      'field_messages',
      'fieldMessages',
      ...metadataFields,
    };

    for (final entry in data.entries) {
      if (!recognizedFields.contains(entry.key)) {
        metadata[entry.key] = entry.value;
      }
    }

    return metadata;
  }

  /// Convert field name from API format to user-friendly format
  String formatFieldName(String fieldName) {
    // Convert snake_case to human readable
    if (fieldName.contains('_')) {
      return fieldName
          .split('_')
          .map(
            (word) =>
                word.isEmpty ? word : word[0].toUpperCase() + word.substring(1),
          )
          .join(' ');
    }

    // Convert camelCase to human readable
    return fieldName
        .replaceAllMapped(RegExp(r'([A-Z])'), (match) => ' ${match.group(1)}')
        .trim();
  }

  /// Get user-friendly error message for a field
  String formatFieldError(String fieldName, String error) {
    final friendlyFieldName = formatFieldName(fieldName);

    // If error already mentions the field, don't duplicate it
    if (error.toLowerCase().contains(fieldName.toLowerCase()) ||
        error.toLowerCase().contains(friendlyFieldName.toLowerCase())) {
      return error;
    }

    return '$friendlyFieldName: $error';
  }
}
