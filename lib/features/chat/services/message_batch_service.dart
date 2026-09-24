import 'dart:async';
import 'dart:convert';

import 'package:riverpod/riverpod.dart';
import 'package:meta/meta.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';

part 'message_batch_service.g.dart';

/// Service for managing batch operations on messages
class MessageBatchService {
  /// Export messages to various formats
  Future<BatchOperationResult> exportMessages({
    required List<ChatMessage> messages,
    required ExportFormat format,
    ExportOptions? options,
  }) async {
    try {
      final exportOptions = options ?? const ExportOptions();
      String content;

      switch (format) {
        case ExportFormat.text:
          content = _exportToText(messages, exportOptions);
          break;
        case ExportFormat.markdown:
          content = _exportToMarkdown(messages, exportOptions);
          break;
        case ExportFormat.json:
          content = _exportToJson(messages, exportOptions);
          break;
        case ExportFormat.csv:
          content = _exportToCsv(messages, exportOptions);
          break;
      }

      return BatchOperationResult.success(
        operation: BatchOperation.export,
        data: {'content': content, 'format': format.name},
        affectedCount: messages.length,
      );
    } catch (e) {
      return BatchOperationResult.error(
        operation: BatchOperation.export,
        error: e.toString(),
      );
    }
  }

  /// Delete multiple messages
  Future<BatchOperationResult> deleteMessages({
    required List<String> messageIds,
    required Conversation conversation,
  }) async {
    try {
      final updatedMessages = conversation.messages
          .where((message) => !messageIds.contains(message.id))
          .toList();

      final updatedConversation = conversation.copyWith(
        messages: updatedMessages,
        updatedAt: DateTime.now(),
      );

      return BatchOperationResult.success(
        operation: BatchOperation.delete,
        data: {'conversation': updatedConversation},
        affectedCount: messageIds.length,
      );
    } catch (e) {
      return BatchOperationResult.error(
        operation: BatchOperation.delete,
        error: e.toString(),
      );
    }
  }

  /// Copy messages to clipboard or another conversation
  Future<BatchOperationResult> copyMessages({
    required List<ChatMessage> messages,
    String? targetConversationId,
    CopyFormat? format,
  }) async {
    try {
      final copyFormat = format ?? CopyFormat.markdown;
      String content;

      switch (copyFormat) {
        case CopyFormat.plain:
          content = messages.map((m) => m.content).join('\n\n');
          break;
        case CopyFormat.markdown:
          content = _exportToMarkdown(messages, const ExportOptions());
          break;
        case CopyFormat.json:
          content = _exportToJson(messages, const ExportOptions());
          break;
      }

      return BatchOperationResult.success(
        operation: BatchOperation.copy,
        data: {
          'content': content,
          'format': copyFormat.name,
          'targetConversation': targetConversationId,
        },
        affectedCount: messages.length,
      );
    } catch (e) {
      return BatchOperationResult.error(
        operation: BatchOperation.copy,
        error: e.toString(),
      );
    }
  }

  /// Move messages to another conversation
  Future<BatchOperationResult> moveMessages({
    required List<String> messageIds,
    required Conversation sourceConversation,
    required Conversation targetConversation,
  }) async {
    try {
      final messagesToMove = sourceConversation.messages
          .where((message) => messageIds.contains(message.id))
          .toList();

      final updatedSourceMessages = sourceConversation.messages
          .where((message) => !messageIds.contains(message.id))
          .toList();

      final updatedTargetMessages = [
        ...targetConversation.messages,
        ...messagesToMove,
      ];

      final updatedSourceConversation = sourceConversation.copyWith(
        messages: updatedSourceMessages,
        updatedAt: DateTime.now(),
      );

      final updatedTargetConversation = targetConversation.copyWith(
        messages: updatedTargetMessages,
        updatedAt: DateTime.now(),
      );

      return BatchOperationResult.success(
        operation: BatchOperation.move,
        data: {
          'sourceConversation': updatedSourceConversation,
          'targetConversation': updatedTargetConversation,
        },
        affectedCount: messageIds.length,
      );
    } catch (e) {
      return BatchOperationResult.error(
        operation: BatchOperation.move,
        error: e.toString(),
      );
    }
  }

  /// Archive multiple messages
  Future<BatchOperationResult> archiveMessages({
    required List<String> messageIds,
    required Conversation conversation,
  }) async {
    try {
      final updatedMessages = conversation.messages.map((message) {
        if (messageIds.contains(message.id)) {
          return message.copyWith(
            metadata: {
              ...?message.metadata,
              'archived': true,
              'archivedAt': DateTime.now().toIso8601String(),
            },
          );
        }
        return message;
      }).toList();

      final updatedConversation = conversation.copyWith(
        messages: updatedMessages,
        updatedAt: DateTime.now(),
      );

      return BatchOperationResult.success(
        operation: BatchOperation.archive,
        data: {'conversation': updatedConversation},
        affectedCount: messageIds.length,
      );
    } catch (e) {
      return BatchOperationResult.error(
        operation: BatchOperation.archive,
        error: e.toString(),
      );
    }
  }

  /// Add tags to multiple messages
  Future<BatchOperationResult> tagMessages({
    required List<String> messageIds,
    required List<String> tags,
    required Conversation conversation,
  }) async {
    try {
      final updatedMessages = conversation.messages.map((message) {
        if (messageIds.contains(message.id)) {
          final existingTags =
              (message.metadata?['tags'] as List<String>?) ?? <String>[];
          final newTags = <String>{...existingTags, ...tags}.toList();

          return message.copyWith(
            metadata: {...?message.metadata, 'tags': newTags},
          );
        }
        return message;
      }).toList();

      final updatedConversation = conversation.copyWith(
        messages: updatedMessages,
        updatedAt: DateTime.now(),
      );

      return BatchOperationResult.success(
        operation: BatchOperation.tag,
        data: {'conversation': updatedConversation},
        affectedCount: messageIds.length,
      );
    } catch (e) {
      return BatchOperationResult.error(
        operation: BatchOperation.tag,
        error: e.toString(),
      );
    }
  }

  /// Filter messages by criteria
  List<ChatMessage> filterMessages({
    required List<ChatMessage> messages,
    MessageFilter? filter,
  }) {
    if (filter == null) return messages;

    return messages.where((message) {
      // Role filter
      if (filter.roles.isNotEmpty && !filter.roles.contains(message.role)) {
        return false;
      }

      // Date range filter
      if (filter.dateFrom != null &&
          message.timestamp.isBefore(filter.dateFrom!)) {
        return false;
      }
      if (filter.dateTo != null && message.timestamp.isAfter(filter.dateTo!)) {
        return false;
      }

      // Content filter
      if (filter.contentFilter != null &&
          !message.content.toLowerCase().contains(
            filter.contentFilter!.toLowerCase(),
          )) {
        return false;
      }

      // Tag filter
      if (filter.tags.isNotEmpty) {
        final messageTags = (message.metadata?['tags'] as List<String>?) ?? [];
        if (!filter.tags.any((tag) => messageTags.contains(tag))) {
          return false;
        }
      }

      // Has attachments filter
      if (filter.hasAttachments != null) {
        final hasAttachments = message.attachmentIds?.isNotEmpty ?? false;
        if (filter.hasAttachments! != hasAttachments) {
          return false;
        }
      }

      return true;
    }).toList();
  }

  // Export format implementations
  String _exportToText(List<ChatMessage> messages, ExportOptions options) {
    final buffer = StringBuffer();

    if (options.includeMetadata) {
      buffer.writeln('Exported on: ${DateTime.now().toIso8601String()}');
      buffer.writeln('Messages: ${messages.length}');
      buffer.writeln('${'=' * 50}\n');
    }

    for (final message in messages) {
      if (options.includeTimestamps) {
        buffer.writeln('[${message.timestamp.toIso8601String()}]');
      }

      buffer.writeln('${_formatRole(message.role)}: ${message.content}');

      if (options.includeMetadata && message.metadata?.isNotEmpty == true) {
        buffer.writeln('Metadata: ${message.metadata}');
      }

      buffer.writeln();
    }

    return buffer.toString();
  }

  String _exportToMarkdown(List<ChatMessage> messages, ExportOptions options) {
    final buffer = StringBuffer();

    if (options.includeMetadata) {
      buffer.writeln('# Conversation Export\n');
      buffer.writeln('- **Exported on:** ${DateTime.now().toIso8601String()}');
      buffer.writeln('- **Messages:** ${messages.length}\n');
      buffer.writeln('---\n');
    }

    for (final message in messages) {
      buffer.writeln('## ${_formatRole(message.role)}');

      if (options.includeTimestamps) {
        buffer.writeln('*${message.timestamp.toIso8601String()}*\n');
      }

      buffer.writeln(message.content);
      buffer.writeln();
    }

    return buffer.toString();
  }

  String _exportToJson(List<ChatMessage> messages, ExportOptions options) {
    final data = {
      if (options.includeMetadata) ...{
        'exportedAt': DateTime.now().toIso8601String(),
        'messageCount': messages.length,
      },
      'messages': messages
          .map(
            (message) => {
              'id': message.id,
              'role': message.role,
              'content': message.content,
              if (options.includeTimestamps)
                'timestamp': message.timestamp.toIso8601String(),
              if (message.model != null) 'model': message.model,
              if (message.attachmentIds?.isNotEmpty == true)
                'attachmentIds': message.attachmentIds,
              if (options.includeMetadata &&
                  message.metadata?.isNotEmpty == true)
                'metadata': message.metadata,
            },
          )
          .toList(),
    };

    return JsonEncoder.withIndent('  ').convert(data);
  }

  String _exportToCsv(List<ChatMessage> messages, ExportOptions options) {
    final buffer = StringBuffer();

    // Header
    final headers = ['Role', 'Content'];
    if (options.includeTimestamps) headers.insert(1, 'Timestamp');
    if (options.includeMetadata) headers.add('Metadata');

    buffer.writeln(headers.map(_escapeCsv).join(','));

    // Data rows
    for (final message in messages) {
      final row = <String>[
        message.role,
        message.content.replaceAll('\n', '\\n'),
      ];

      if (options.includeTimestamps) {
        row.insert(1, message.timestamp.toIso8601String());
      }

      if (options.includeMetadata) {
        row.add(message.metadata?.toString() ?? '');
      }

      buffer.writeln(row.map(_escapeCsv).join(','));
    }

    return buffer.toString();
  }

  String _formatRole(String role) {
    switch (role.toLowerCase()) {
      case 'user':
        return 'User';
      case 'assistant':
        return 'Assistant';
      case 'system':
        return 'System';
      default:
        return role;
    }
  }

  String _escapeCsv(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}

/// Export formats supported by the batch service
enum ExportFormat { text, markdown, json, csv }

/// Copy formats for clipboard operations
enum CopyFormat { plain, markdown, json }

/// Batch operations that can be performed
enum BatchOperation { export, delete, copy, move, archive, tag }

/// Options for export operations
@immutable
class ExportOptions {
  final bool includeTimestamps;
  final bool includeMetadata;
  final bool includeAttachments;

  const ExportOptions({
    this.includeTimestamps = true,
    this.includeMetadata = false,
    this.includeAttachments = true,
  });
}

/// Filter criteria for messages
@immutable
class MessageFilter {
  final List<String> roles;
  final DateTime? dateFrom;
  final DateTime? dateTo;
  final String? contentFilter;
  final List<String> tags;
  final bool? hasAttachments;

  const MessageFilter({
    this.roles = const [],
    this.dateFrom,
    this.dateTo,
    this.contentFilter,
    this.tags = const [],
    this.hasAttachments,
  });

  MessageFilter copyWith({
    List<String>? roles,
    DateTime? dateFrom,
    DateTime? dateTo,
    String? contentFilter,
    List<String>? tags,
    bool? hasAttachments,
  }) {
    return MessageFilter(
      roles: roles ?? this.roles,
      dateFrom: dateFrom ?? this.dateFrom,
      dateTo: dateTo ?? this.dateTo,
      contentFilter: contentFilter ?? this.contentFilter,
      tags: tags ?? this.tags,
      hasAttachments: hasAttachments ?? this.hasAttachments,
    );
  }
}

/// Result of a batch operation
@immutable
class BatchOperationResult {
  final BatchOperation operation;
  final bool success;
  final String? error;
  final Map<String, dynamic>? data;
  final int affectedCount;

  const BatchOperationResult({
    required this.operation,
    required this.success,
    this.error,
    this.data,
    this.affectedCount = 0,
  });

  factory BatchOperationResult.success({
    required BatchOperation operation,
    Map<String, dynamic>? data,
    int affectedCount = 0,
  }) {
    return BatchOperationResult(
      operation: operation,
      success: true,
      data: data,
      affectedCount: affectedCount,
    );
  }

  factory BatchOperationResult.error({
    required BatchOperation operation,
    required String error,
  }) {
    return BatchOperationResult(
      operation: operation,
      success: false,
      error: error,
    );
  }
}

/// Provider for message batch service
final messageBatchServiceProvider = Provider<MessageBatchService>((ref) {
  return MessageBatchService();
});

/// Provider for selected messages (for batch operations)
final selectedMessagesProvider =
    NotifierProvider<SelectedMessagesNotifier, Set<String>>(
      SelectedMessagesNotifier.new,
    );

/// Provider for batch operation mode
@Riverpod(keepAlive: true)
class BatchMode extends _$BatchMode {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

/// Provider for message filter
final messageFilterProvider =
    NotifierProvider<MessageFilterNotifier, MessageFilter?>(
      MessageFilterNotifier.new,
    );

class SelectedMessagesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => <String>{};

  void set(Set<String> messages) => state = Set<String>.from(messages);

  void clear() => state = <String>{};
}

class MessageFilterNotifier extends Notifier<MessageFilter?> {
  @override
  MessageFilter? build() => null;

  void set(MessageFilter? filter) => state = filter;
}
