import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:mocktail/mocktail.dart';

class ComputerTestPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _View(params);
}

class _View extends PlatformInAppWebViewWidget {
  _View(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();
  @override
  void dispose() {}
}

class ComputerTestWebController extends Fake implements InAppWebViewController {
  final scripts = <String>[];
  final handlers = <String, Function>{};
  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async => scripts.add(source);
  @override
  void addJavaScriptHandler({
    required String handlerName,
    required Function callback,
  }) => handlers[handlerName] = callback;
  @override
  Function? removeJavaScriptHandler({required String handlerName}) =>
      handlers.remove(handlerName);
}
