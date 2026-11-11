import 'dart:async';

import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:fleather/fleather.dart' as fleather;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

class _PdfSelection extends Fake implements PdfTextSelectionDelegate {
  bool copyAllowed = true;
  bool selected = true;
  bool selectingAll = false;
  int copies = 0;
  int selectAlls = 0;
  @override
  bool get isCopyAllowed => copyAllowed;
  @override
  bool get hasSelectedText => selected;
  @override
  bool get isSelectingAllText => selectingAll;
  @override
  Future<bool> copyTextSelection() async {
    copies++;
    return true;
  }

  @override
  Future<void> selectAllText() async {
    selectAlls++;
  }
}

void main() {
  const channel = MethodChannel('app.cogwheel.conduit/text_selection_menu');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> calls;
  late List<Completer<int?>> replies;
  setUp(() {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    calls = [];
    replies = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      if (call.method != 'show') return Future<Object?>.value();
      final reply = Completer<int?>();
      replies.add(reply);
      return reply.future;
    });
  });
  tearDown(() {
    PlatformUiCapabilities.resetDebugOverrides();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });
  Widget host(Widget child) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(supportsShowingSystemContextMenu: true),
      child: LegacyDesignCompatibility(child: child!),
    ),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.fromLTRB(32, 80, 0, 0),
        child: child,
      ),
    ),
  );

  testWidgets(
    'PDF menu uses global native geometry and retains local anchors',
    (tester) async {
      const key = Key('pdf-viewport');
      await tester.pumpWidget(
        host(const SizedBox(key: key, width: 240, height: 180)),
      );
      final context = tester.element(find.byKey(key));
      final box = context.findRenderObject()! as RenderBox;
      final selection = _PdfSelection();
      final params = PdfViewerContextMenuBuilderParams(
        isTextSelectionEnabled: true,
        anchorA: const Offset(20, 30),
        anchorB: const Offset(160, 70),
        textSelectionDelegate: selection,
        dismissContextMenu: () {},
        contextMenuFor: PdfViewerPart.selectedText,
      );
      final result =
          AdaptiveDocumentSelectionMenu.pdf(context, params)! as Align;
      final menu = result.child! as AdaptiveTextSelectionMenu;
      expect(
        menu.selectionRect,
        Rect.fromPoints(
          box.localToGlobal(params.anchorA),
          box.localToGlobal(params.anchorB!),
        ),
      );
      expect(menu.anchors.primaryAnchor, params.anchorA);
      await tester.pumpWidget(host(result));
      await tester.pump();
      final payload =
          calls.singleWhere((call) => call.method == 'show').arguments as Map;
      expect(payload['labels'], ['Copy', 'Select All']);
      expect(payload.containsKey('text'), isFalse);
      replies.single.complete(0);
      await tester.pump();
      expect(selection.copies, 1);
      menu.buttonItems[1].onPressed!();
      expect(selection.selectAlls, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('PDF permissions and empty menus match the original viewer', (
    tester,
  ) async {
    const key = Key('pdf-viewport');
    await tester.pumpWidget(
      host(const SizedBox(key: key, width: 240, height: 180)),
    );
    final context = tester.element(find.byKey(key));
    final selection = _PdfSelection()..copyAllowed = false;
    final params = PdfViewerContextMenuBuilderParams(
      isTextSelectionEnabled: true,
      anchorA: const Offset(20, 30),
      textSelectionDelegate: selection,
      dismissContextMenu: () {},
      contextMenuFor: PdfViewerPart.background,
    );
    final result = AdaptiveDocumentSelectionMenu.pdf(context, params)! as Align;
    final menu = result.child! as AdaptiveTextSelectionMenu;
    expect(menu.buttonItems.map((item) => item.type), [
      ContextMenuButtonType.selectAll,
    ]);
    expect(menu.selectionRect.width, greaterThan(0));
    expect(menu.selectionRect.height, greaterThan(0));
    selection.selectingAll = true;
    expect(AdaptiveDocumentSelectionMenu.pdf(context, params), isNull);
    selection.selectingAll = false;
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
    final fallback =
        AdaptiveDocumentSelectionMenu.pdf(context, params)! as Align;
    expect(fallback.child, isNot(isA<AdaptiveTextSelectionMenu>()));
    expect(calls, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('read-only rich text keeps its selection and Copy callback', (
    tester,
  ) async {
    final controller = fleather.FleatherController(
      document: fleather.ParchmentDocument.fromJson([
        {'insert': 'A small paper bird.\n'},
      ]),
    );
    addTearDown(controller.dispose);
    String? copied;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    await tester.pumpWidget(
      host(
        SingleChildScrollView(
          controller: scrollController,
          child: fleather.FleatherEditor(
            controller: controller,
            readOnly: true,
            scrollable: false,
            scrollController: scrollController,
            contextMenuBuilder: AdaptiveDocumentSelectionMenu.richText,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state<fleather.EditorState>(
      find.byType(fleather.RawEditor),
    );
    final caret = state.renderEditor.getLocalRectForCaret(
      const TextPosition(offset: 10),
    );
    await tester.longPressAt(state.renderEditor.localToGlobal(caret.center));
    await tester.pump();
    final payload =
        calls.singleWhere((call) => call.method == 'show').arguments as Map;
    final selectedText = state.textEditingValue.selection.textInside(
      state.textEditingValue.text,
    );
    expect(selectedText, isNotEmpty);
    expect(payload.containsKey('text'), isFalse);
    final labels = payload['labels'] as List;
    expect(labels, contains('Copy'));
    expect(labels, isNot(contains('Cut')));
    expect(labels, isNot(contains('Paste')));
    replies.single.complete(labels.indexOf('Copy'));
    await tester.pump();
    expect(copied, selectedText);
    expect(controller.document.toPlainText(), 'A small paper bird.\n');
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
