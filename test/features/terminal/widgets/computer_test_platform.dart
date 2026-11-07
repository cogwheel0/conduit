import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:mocktail/mocktail.dart';

class ComputerTestPlatform extends InAppWebViewPlatform {
  ComputerTestPlatform({this.pointerController});
  final PlatformViewController? pointerController;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _View(params, pointerController);
}

class _View extends PlatformInAppWebViewWidget {
  _View(super.params, this.pointerController) : super.implementation();
  final PlatformViewController? pointerController;
  @override
  Widget build(BuildContext context) => pointerController == null
      ? const SizedBox.expand()
      : PlatformViewSurface(
          controller: pointerController!,
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          gestureRecognizers: params.gestureRecognizers ?? {},
        );
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
