import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/error/error_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ErrorParser parser;

  setUp(() {
    parser = ErrorParser();
  });

  group('parseErrorResponse', () {
    test('null returns empty response', () {
      final result = parser.parseErrorResponse(null);
      check(result.message).isNull();
      check(result.errors).isEmpty();
    });

    test('Map with "message" extracts message', () {
      final result = parser.parseErrorResponse(<String, dynamic>{
        'message': 'Something went wrong',
      });
      check(result.message).equals('Something went wrong');
    });

    test('Map with "error" extracts message', () {
      final result = parser.parseErrorResponse(<String, dynamic>{
        'error': 'Not found',
      });
      check(result.message).equals('Not found');
    });

    test('Map with "detail" extracts message', () {
      final result = parser.parseErrorResponse(<String, dynamic>{
        'detail': 'Access denied',
      });
      check(result.message).equals('Access denied');
    });

    test('extracts code from "code" field', () {
      final result = parser.parseErrorResponse(<String, dynamic>{
        'message': 'Error',
        'code': 'ERR_001',
      });
      check(result.code).equals('ERR_001');
    });

    test('extracts integer code as string', () {
      final result = parser.parseErrorResponse(<String, dynamic>{
        'message': 'Error',
        'code': 42,
      });
      check(result.code).equals('42');
    });

    test('string response becomes message', () {
      final result = parser.parseErrorResponse('Plain text error');
      check(result.message).equals('Plain text error');
      check(result.metadata['format']).equals('string');
    });

    test('list response extracts errors', () {
      final result = parser.parseErrorResponse(
        <dynamic>['Error one', 'Error two'],
      );
      check(result.message).equals('Error one');
      check(result.errors).deepEquals(['Error one', 'Error two']);
      check(result.metadata['format']).equals('list');
    });

    test('errors array extraction from map', () {
      final result = parser.parseErrorResponse(<String, dynamic>{
        'message': 'Multiple issues',
        'errors': ['First', 'Second'],
      });
      check(result.errors).deepEquals(['First', 'Second']);
    });

    test('metadata from unrecognized fields', () {
      final result = parser.parseErrorResponse(<String, dynamic>{
        'message': 'Error',
        'custom_field': 'custom_value',
      });
      check(result.metadata['custom_field']).equals('custom_value');
    });

    test('binary Uint8List payload is decoded', () {
      final jsonStr = '{"message": "Binary error"}';
      final bytes = Uint8List.fromList(utf8.encode(jsonStr));
      final result = parser.parseErrorResponse(bytes);
      check(result.message).equals('Binary error');
    });
  });

  group('parseValidationError', () {
    test('extracts field_errors object', () {
      final result = parser.parseValidationError(<String, dynamic>{
        'message': 'Validation failed',
        'field_errors': {
          'email': ['is required', 'must be valid'],
          'name': ['too short'],
        },
      });
      check(result.message).equals('Validation failed');
      check(result.fieldErrors['email']).isNotNull().deepEquals([
        'is required',
        'must be valid',
      ]);
      check(result.fieldErrors['name']).isNotNull().deepEquals([
        'too short',
      ]);
    });

    test('OpenAPI format with detail array containing loc/msg', () {
      final result = parser.parseValidationError(<String, dynamic>{
        'detail': [
          {
            'loc': ['body', 'email'],
            'msg': 'field required',
          },
          {
            'loc': ['body', 'age'],
            'msg': 'must be positive',
          },
        ],
      });
      check(result.fieldErrors['email']).isNotNull().deepEquals([
        'field required',
      ]);
      check(result.fieldErrors['age']).isNotNull().deepEquals([
        'must be positive',
      ]);
    });
  });

  group('formatFieldName', () {
    test('snake_case converts to title case with spaces', () {
      final result = parser.formatFieldName('first_name');
      check(result).equals('First Name');
    });

    test('camelCase adds spaces before capitals', () {
      final result = parser.formatFieldName('firstName');
      check(result).equals('first Name');
    });
  });

  group('formatFieldError', () {
    test('prepends formatted field name', () {
      final result = parser.formatFieldError(
        'first_name',
        'is required',
      );
      check(result).equals('First Name: is required');
    });

    test('avoids duplicate when error contains field name', () {
      final result = parser.formatFieldError(
        'email',
        'email must be valid',
      );
      check(result).equals('email must be valid');
    });
  });
}
