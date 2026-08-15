import 'package:conduit/core/widgets/error_boundary.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('process error handling', () {
    late ErrorWidgetBuilder originalErrorWidgetBuilder;
    late void Function(FlutterErrorDetails)? originalFlutterErrorOnError;

    setUp(() {
      originalErrorWidgetBuilder = ErrorWidget.builder;
      originalFlutterErrorOnError = FlutterError.onError;
    });

    tearDown(() {
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });

    testWidgets('does not replace the process-level Flutter error handler', (
      tester,
    ) async {
      void handler(FlutterErrorDetails details) {}

      FlutterError.onError = handler;
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: SizedBox.shrink())),
      );

      expect(identical(FlutterError.onError, handler), isTrue);
    });

    testWidgets('global builder renders a friendly nonblank fallback', (
      tester,
    ) async {
      installConduitErrorWidgetBuilder();
      final fallback = ErrorWidget.builder(
        FlutterErrorDetails(exception: StateError('debug failure')),
      );
      ErrorWidget.builder = originalErrorWidgetBuilder;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: Scaffold(body: fallback)),
        ),
      );

      expect(find.byType(ConduitFriendlyErrorView), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      expect(find.textContaining('Something went wrong'), findsOneWidget);
      expect(find.textContaining('debug failure'), findsOneWidget);
    });
  });
}
