import 'package:conduit/core/widgets/error_boundary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ErrorBoundary', () {
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

    testWidgets('renders child normally when no error', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ErrorBoundary(child: const Text('Hello World')),
            ),
          ),
        ),
      );

      expect(find.text('Hello World'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('can be found by type', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: ErrorBoundary(child: const SizedBox.shrink())),
          ),
        ),
      );

      expect(find.byType(ErrorBoundary), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('does not replace the process-level Flutter error handler', (
      tester,
    ) async {
      void handler(FlutterErrorDetails details) {}

      FlutterError.onError = handler;
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: ErrorBoundary(child: SizedBox.shrink())),
        ),
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
