import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/views/chat_markdown_virtualization_controller.dart';
import 'package:conduit/shared/widgets/markdown/compiled_markdown_document.dart';
import 'package:conduit/shared/widgets/markdown/markdown_compile_service.dart';
import 'package:conduit/shared/widgets/markdown/markdown_display_part.dart';
import 'package:flutter_test/flutter_test.dart';

class _GatedCompiler extends MarkdownCompileService {
  factory _GatedCompiler() => _GatedCompiler._(WorkerManager());

  _GatedCompiler._(this.workerManager) : super(workerManager: workerManager);

  final WorkerManager workerManager;
  final gates = <String, Completer<void>>{};
  final failures = <String>{};

  @override
  void dispose() {
    super.dispose();
    workerManager.dispose();
  }

  @override
  Future<String> prepareContent(
    String content, {
    required bool streaming,
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async => content;

  @override
  Future<CompiledMarkdownDocument> compilePrepared(
    String preparedContent, {
    bool allowSynchronous = false,
    bool widgetTest = false,
    bool cacheResult = true,
  }) async {
    final gate = gates[preparedContent];
    if (gate != null) await gate.future;
    if (failures.contains(preparedContent)) throw StateError('compile failed');
    return compilePreparedMarkdownSync(preparedContent);
  }
}

ChatMessage _assistant(String content, {bool streaming = false}) => ChatMessage(
  id: 'assistant',
  role: 'assistant',
  content: content,
  timestamp: DateTime(2026),
  isStreaming: streaming,
);

void main() {
  late _GatedCompiler compiler;
  late ChatMarkdownVirtualizationController controller;

  setUp(() {
    compiler = _GatedCompiler();
    controller = ChatMarkdownVirtualizationController(
      compiler: compiler,
      onChanged: () {},
    );
  });

  tearDown(() {
    controller.dispose();
    compiler.dispose();
  });

  test(
    'promotes only streaming documents above the strict block threshold',
    () {
      for (final count in [24, 25]) {
        final content = List.generate(
          count,
          (index) => 'paragraph $index',
        ).join('\n\n');
        final document = compilePreparedMarkdownSync(content);
        check(buildMarkdownDisplayParts(document, isStreaming: false)).length
            .equals(count);
        final streaming = _assistant(content, streaming: true);
        controller.cacheStreamingDocument(
          message: streaming,
          versionIndex: -1,
          content: content,
          document: document,
        );
        final settled = streaming.copyWith(isStreaming: false);
        final view = controller.reconcile([
          settled,
        ], customResponseBuilderActive: false);
        check(view.partsByMessageId.containsKey(settled.id))
            .equals(count == 25);
        controller.clear();
      }
    },
  );

  test(
    'stale async completion cannot replace newer reconnect content',
    () async {
      final oldContent = '${List.filled(3001, 'old ').join()}A';
      final newContent = '${List.filled(3001, 'new ').join()}B';
      final newestContent = '${List.filled(3001, 'newest ').join()}C';
      final oldMessage = _assistant(oldContent);
      controller.acceptSettledDocument(
        message: oldMessage,
        versionIndex: -1,
        content: oldContent,
        document: compilePreparedMarkdownSync(oldContent),
      );
      compiler.gates[newContent] = Completer<void>();
      final newMessage = _assistant(newContent);
      var view = controller.reconcile([
        newMessage,
      ], customResponseBuilderActive: false);
      check(view.partsByMessageId['assistant']).isNotNull();
      controller.startPendingCompilations();

      final newestMessage = _assistant(newestContent);
      view = controller.reconcile([
        newestMessage,
      ], customResponseBuilderActive: false);
      check(view.partsByMessageId['assistant']).isNotNull();
      compiler.gates[newContent]!.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      view = controller.reconcile([
        newestMessage,
      ], customResponseBuilderActive: false);
      check(view.partsByMessageId['assistant']).isNotNull();
      check(view.pendingMessageIds).contains('assistant');
      controller.startPendingCompilations();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      view = controller.reconcile([
        newestMessage,
      ], customResponseBuilderActive: false);
      check(
        view.partsByMessageId['assistant']!.first.document.normalizedContent,
      ).contains('newest');
    },
  );

  test('failed signatures fall back without compiling forever', () async {
    final oldContent = List.generate(
      25,
      (index) => 'cached $index',
    ).join('\n\n');
    final content = '$oldContent\n\nbroken replacement';
    final oldMessage = _assistant(oldContent);
    controller.acceptSettledDocument(
      message: oldMessage,
      versionIndex: -1,
      content: oldContent,
      document: compilePreparedMarkdownSync(oldContent),
    );
    compiler.failures.add(content);
    final replacement = _assistant(content);
    var view = controller.reconcile([
      replacement,
    ], customResponseBuilderActive: false);
    check(view.partsByMessageId['assistant']).isNotNull();
    controller.startPendingCompilations();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    view = controller.reconcile([
      replacement,
    ], customResponseBuilderActive: false);
    check(view.partsByMessageId).isEmpty();
    check(view.pendingMessageIds).isEmpty();
  });

  test('final token keeps the last streaming blocks until replacement', () {
    final streamingContent = List.generate(
      25,
      (index) => 'streaming $index',
    ).join('\n\n');
    final finalContent = '$streamingContent\n\nfinal token';
    final streaming = _assistant(streamingContent, streaming: true);
    controller.cacheStreamingDocument(
      message: streaming,
      versionIndex: -1,
      content: streamingContent,
      document: compilePreparedMarkdownSync(streamingContent),
    );

    final view = controller.reconcile([
      _assistant(finalContent),
    ], customResponseBuilderActive: false);
    check(view.partsByMessageId['assistant']).isNotNull();
    check(view.pendingMessageIds).contains('assistant');
  });

  test(
    'version changes atomically replace old parts when selection is ready',
    () async {
      final current = List.generate(
        25,
        (index) => 'current $index',
      ).join('\n\n');
      final previous = List.generate(
        25,
        (index) => 'previous $index',
      ).join('\n\n');
      final message = _assistant(current).copyWith(
        versions: [
          ChatMessageVersion(
            id: 'version-0',
            content: previous,
            timestamp: DateTime(2025),
          ),
        ],
      );
      controller.acceptSettledDocument(
        message: message,
        versionIndex: -1,
        content: current,
        document: compilePreparedMarkdownSync(current),
      );
      controller.selectVersion(message.id, 0);

      var view = controller.reconcile([
        message,
      ], customResponseBuilderActive: false);
      check(view.partsByMessageId[message.id]).isNotNull();
      check(controller.displayedVersionIndex(message)).equals(-1);
      check(view.pendingMessageIds).contains(message.id);
      controller.startPendingCompilations();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      view = controller.reconcile([
        message,
      ], customResponseBuilderActive: false);
      check(view.partsByMessageId[message.id]).isNotNull();
      check(controller.displayedVersionIndex(message)).equals(0);
    },
  );

  test('removed archived versions never expose their cached row identity', () {
    final content = List.generate(25, (index) => 'version $index').join('\n\n');
    final message = _assistant('current').copyWith(
      versions: [
        ChatMessageVersion(
          id: 'removed-version',
          content: content,
          timestamp: DateTime(2025),
        ),
      ],
    );
    controller.selectVersion(message.id, 0);
    controller.acceptSettledDocument(
      message: message,
      versionIndex: 0,
      content: content,
      document: compilePreparedMarkdownSync(content),
    );

    final withoutVersion = message.copyWith(versions: []);
    final view = controller.reconcile([
      withoutVersion,
    ], customResponseBuilderActive: false);
    check(view.partsByMessageId).isEmpty();
    check(controller.displayedVersionIndex(withoutVersion)).equals(-1);
  });

  test(
    'proactive compilation strips leftover assistant placeholders',
    () async {
      final content =
          '[TYPING_INDICATOR]${List.filled(3001, 'answer ').join()}';
      final message = _assistant(content);
      controller.reconcile([message], customResponseBuilderActive: false);
      controller.startPendingCompilations();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final view = controller.reconcile([
        message,
      ], customResponseBuilderActive: false);
      check(view.partsByMessageId[message.id]!.first.document.normalizedContent)
          .not((it) => it.contains('[TYPING_INDICATOR]'));
    },
  );

  test('duplicate IDs disable virtualization for every colliding row', () {
    final content = List.generate(25, (index) => 'part $index').join('\n\n');
    final assistant = _assistant(content);
    controller.acceptSettledDocument(
      message: assistant,
      versionIndex: -1,
      content: content,
      document: compilePreparedMarkdownSync(content),
    );
    final user = ChatMessage(
      id: assistant.id,
      role: 'user',
      content: 'first retained row',
      timestamp: DateTime(2026),
    );

    final view = controller.reconcile([
      user,
      assistant,
    ], customResponseBuilderActive: false);
    check(view.partsByMessageId).isEmpty();
    check(view.pendingMessageIds).isEmpty();
  });
}
