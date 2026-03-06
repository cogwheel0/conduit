import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/services/message_batch_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MessageBatchService service;

  setUp(() {
    service = MessageBatchService();
  });

  /// Helper to create a [ChatMessage] with sensible defaults.
  ChatMessage msg({
    String id = '1',
    String role = 'user',
    String content = 'hello',
    DateTime? timestamp,
    List<String>? attachmentIds,
    Map<String, dynamic>? metadata,
    String? model,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      content: content,
      timestamp: timestamp ?? DateTime(2025, 1, 1),
      attachmentIds: attachmentIds,
      metadata: metadata,
      model: model,
    );
  }

  group('filterMessages', () {
    test('returns all messages when filter is null', () {
      final messages = [msg(id: '1'), msg(id: '2')];
      final result = service.filterMessages(messages: messages);
      check(result).length.equals(2);
    });

    test('filters by single role', () {
      final messages = [
        msg(id: '1', role: 'user'),
        msg(id: '2', role: 'assistant'),
        msg(id: '3', role: 'system'),
      ];
      final result = service.filterMessages(
        messages: messages,
        filter: const MessageFilter(roles: ['user']),
      );
      check(result).length.equals(1);
      check(result.first.role).equals('user');
    });

    test('filters by multiple roles', () {
      final messages = [
        msg(id: '1', role: 'user'),
        msg(id: '2', role: 'assistant'),
        msg(id: '3', role: 'system'),
      ];
      final result = service.filterMessages(
        messages: messages,
        filter: const MessageFilter(roles: ['user', 'system']),
      );
      check(result).length.equals(2);
    });

    test('filters by dateFrom', () {
      final messages = [
        msg(id: '1', timestamp: DateTime(2025, 1, 1)),
        msg(id: '2', timestamp: DateTime(2025, 6, 1)),
      ];
      final result = service.filterMessages(
        messages: messages,
        filter: MessageFilter(dateFrom: DateTime(2025, 3, 1)),
      );
      check(result).length.equals(1);
      check(result.first.id).equals('2');
    });

    test('filters by dateTo', () {
      final messages = [
        msg(id: '1', timestamp: DateTime(2025, 1, 1)),
        msg(id: '2', timestamp: DateTime(2025, 6, 1)),
      ];
      final result = service.filterMessages(
        messages: messages,
        filter: MessageFilter(dateTo: DateTime(2025, 3, 1)),
      );
      check(result).length.equals(1);
      check(result.first.id).equals('1');
    });

    test('filters by date range', () {
      final messages = [
        msg(id: '1', timestamp: DateTime(2025, 1, 1)),
        msg(id: '2', timestamp: DateTime(2025, 3, 15)),
        msg(id: '3', timestamp: DateTime(2025, 6, 1)),
      ];
      final result = service.filterMessages(
        messages: messages,
        filter: MessageFilter(
          dateFrom: DateTime(2025, 2, 1),
          dateTo: DateTime(2025, 5, 1),
        ),
      );
      check(result).length.equals(1);
      check(result.first.id).equals('2');
    });

    test('filters by content (case-insensitive)', () {
      final messages = [
        msg(id: '1', content: 'Hello World'),
        msg(id: '2', content: 'goodbye'),
        msg(id: '3', content: 'HELLO again'),
      ];
      final result = service.filterMessages(
        messages: messages,
        filter: const MessageFilter(contentFilter: 'hello'),
      );
      check(result).length.equals(2);
    });

    test('filters by hasAttachments true', () {
      final messages = [
        msg(id: '1', attachmentIds: ['a1']),
        msg(id: '2'),
        msg(id: '3', attachmentIds: []),
      ];
      final result = service.filterMessages(
        messages: messages,
        filter: const MessageFilter(hasAttachments: true),
      );
      check(result).length.equals(1);
      check(result.first.id).equals('1');
    });

    test('filters by hasAttachments false', () {
      final messages = [
        msg(id: '1', attachmentIds: ['a1']),
        msg(id: '2'),
      ];
      final result = service.filterMessages(
        messages: messages,
        filter: const MessageFilter(hasAttachments: false),
      );
      check(result).length.equals(1);
      check(result.first.id).equals('2');
    });

    test('combines multiple filters', () {
      final messages = [
        msg(
          id: '1',
          role: 'user',
          content: 'hello',
          timestamp: DateTime(2025, 3, 1),
        ),
        msg(
          id: '2',
          role: 'assistant',
          content: 'hello back',
          timestamp: DateTime(2025, 3, 1),
        ),
        msg(
          id: '3',
          role: 'user',
          content: 'goodbye',
          timestamp: DateTime(2025, 3, 1),
        ),
      ];
      final result = service.filterMessages(
        messages: messages,
        filter: const MessageFilter(
          roles: ['user'],
          contentFilter: 'hello',
        ),
      );
      check(result).length.equals(1);
      check(result.first.id).equals('1');
    });

    test('returns empty list when no messages match', () {
      final messages = [msg(id: '1', role: 'user')];
      final result = service.filterMessages(
        messages: messages,
        filter: const MessageFilter(roles: ['system']),
      );
      check(result).isEmpty();
    });
  });

  group('MessageFilter.copyWith', () {
    test('copies all fields', () {
      final original = MessageFilter(
        roles: const ['user'],
        dateFrom: DateTime(2025, 1, 1),
        dateTo: DateTime(2025, 12, 31),
        contentFilter: 'hello',
        tags: const ['tag1'],
        hasAttachments: true,
      );
      final copied = original.copyWith(roles: ['assistant']);

      check(copied.roles).deepEquals(['assistant']);
      check(copied.dateFrom).equals(original.dateFrom);
      check(copied.dateTo).equals(original.dateTo);
      check(copied.contentFilter).equals('hello');
      check(copied.tags).deepEquals(['tag1']);
      check(copied.hasAttachments).equals(true);
    });

    test('preserves original when no arguments given', () {
      final original = MessageFilter(
        roles: const ['user'],
        contentFilter: 'test',
      );
      final copied = original.copyWith();

      check(copied.roles).deepEquals(['user']);
      check(copied.contentFilter).equals('test');
    });
  });

  group('BatchOperationResult factories', () {
    test('success factory sets fields correctly', () {
      final result = BatchOperationResult.success(
        operation: BatchOperation.export,
        data: {'key': 'value'},
        affectedCount: 5,
      );
      check(result.success).isTrue();
      check(result.operation).equals(BatchOperation.export);
      check(result.affectedCount).equals(5);
      check(result.data).isNotNull();
      check(result.error).isNull();
    });

    test('success factory defaults affectedCount to 0', () {
      final result = BatchOperationResult.success(
        operation: BatchOperation.delete,
      );
      check(result.affectedCount).equals(0);
      check(result.success).isTrue();
    });

    test('error factory sets fields correctly', () {
      final result = BatchOperationResult.error(
        operation: BatchOperation.copy,
        error: 'something went wrong',
      );
      check(result.success).isFalse();
      check(result.operation).equals(BatchOperation.copy);
      check(result.error).equals('something went wrong');
      check(result.affectedCount).equals(0);
    });
  });

  group('exportMessages', () {
    final testMessages = [
      ChatMessage(
        id: '1',
        role: 'user',
        content: 'Hello',
        timestamp: DateTime(2025, 1, 1, 12, 0),
      ),
      ChatMessage(
        id: '2',
        role: 'assistant',
        content: 'Hi there',
        timestamp: DateTime(2025, 1, 1, 12, 1),
        model: 'gpt-4',
      ),
    ];

    group('text format', () {
      test('exports basic text with timestamps', () async {
        final result = await service.exportMessages(
          messages: testMessages,
          format: ExportFormat.text,
        );
        check(result.success).isTrue();
        final content = result.data!['content'] as String;
        check(content).contains('User: Hello');
        check(content).contains('Assistant: Hi there');
        check(content).contains('2025-01-01');
      });

      test('omits timestamps when disabled', () async {
        final result = await service.exportMessages(
          messages: testMessages,
          format: ExportFormat.text,
          options: const ExportOptions(includeTimestamps: false),
        );
        final content = result.data!['content'] as String;
        check(content).contains('User: Hello');
        // Should not contain timestamp markers
        check(content).not((s) => s.contains('[2025-01-01'));
      });
    });

    group('markdown format', () {
      test('exports with role headings', () async {
        final result = await service.exportMessages(
          messages: testMessages,
          format: ExportFormat.markdown,
        );
        check(result.success).isTrue();
        final content = result.data!['content'] as String;
        check(content).contains('## User');
        check(content).contains('## Assistant');
        check(content).contains('Hello');
        check(content).contains('Hi there');
      });

      test('includes metadata header when enabled', () async {
        final result = await service.exportMessages(
          messages: testMessages,
          format: ExportFormat.markdown,
          options: const ExportOptions(includeMetadata: true),
        );
        final content = result.data!['content'] as String;
        check(content).contains('# Conversation Export');
        check(content).contains('**Messages:** 2');
      });
    });

    group('JSON format', () {
      test('produces valid JSON', () async {
        final result = await service.exportMessages(
          messages: testMessages,
          format: ExportFormat.json,
        );
        check(result.success).isTrue();
        final content = result.data!['content'] as String;
        final parsed =
            jsonDecode(content) as Map<String, dynamic>;
        final msgs = parsed['messages'] as List;
        check(msgs).length.equals(2);
      });

      test('includes timestamps by default', () async {
        final result = await service.exportMessages(
          messages: testMessages,
          format: ExportFormat.json,
        );
        final content = result.data!['content'] as String;
        final parsed =
            jsonDecode(content) as Map<String, dynamic>;
        final first =
            (parsed['messages'] as List).first as Map<String, dynamic>;
        check(first).containsKey('timestamp');
      });

      test('includes model when present', () async {
        final result = await service.exportMessages(
          messages: testMessages,
          format: ExportFormat.json,
        );
        final content = result.data!['content'] as String;
        final parsed =
            jsonDecode(content) as Map<String, dynamic>;
        final second =
            (parsed['messages'] as List)[1] as Map<String, dynamic>;
        check(second['model']).equals('gpt-4');
      });

      test('includes metadata when enabled', () async {
        final result = await service.exportMessages(
          messages: testMessages,
          format: ExportFormat.json,
          options: const ExportOptions(includeMetadata: true),
        );
        final content = result.data!['content'] as String;
        final parsed =
            jsonDecode(content) as Map<String, dynamic>;
        check(parsed).containsKey('exportedAt');
        check(parsed).containsKey('messageCount');
      });
    });

    group('CSV format', () {
      test('produces header and data rows', () async {
        final result = await service.exportMessages(
          messages: testMessages,
          format: ExportFormat.csv,
        );
        check(result.success).isTrue();
        final content = result.data!['content'] as String;
        final lines =
            content.trim().split('\n');
        // Header + 2 data rows
        check(lines).length.equals(3);
        check(lines.first).contains('Role');
        check(lines.first).contains('Content');
      });

      test('includes Timestamp column when enabled', () async {
        final result = await service.exportMessages(
          messages: testMessages,
          format: ExportFormat.csv,
        );
        final content = result.data!['content'] as String;
        check(content.split('\n').first).contains('Timestamp');
      });

      test('escapes commas in CSV values', () async {
        final messages = [
          msg(content: 'hello, world'),
        ];
        final result = await service.exportMessages(
          messages: messages,
          format: ExportFormat.csv,
        );
        final content = result.data!['content'] as String;
        // Value containing comma should be quoted
        check(content).contains('"hello, world"');
      });

      test('escapes double quotes in CSV values', () async {
        final messages = [
          msg(content: 'say "hi"'),
        ];
        final result = await service.exportMessages(
          messages: messages,
          format: ExportFormat.csv,
        );
        final content = result.data!['content'] as String;
        // Quotes within quoted value should be doubled
        check(content).contains('""hi""');
      });

      test('escapes newlines in content', () async {
        final messages = [
          msg(content: 'line1\nline2'),
        ];
        final result = await service.exportMessages(
          messages: messages,
          format: ExportFormat.csv,
        );
        final content = result.data!['content'] as String;
        // Newlines in content are replaced with \\n before CSV
        check(content).contains('line1\\nline2');
      });
    });

    test('result includes format name and message count', () async {
      final result = await service.exportMessages(
        messages: testMessages,
        format: ExportFormat.text,
      );
      check(result.data!['format']).equals('text');
      check(result.affectedCount).equals(2);
    });
  });
}
