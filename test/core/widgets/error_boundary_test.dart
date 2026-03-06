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
              body: ErrorBoundary(
                child: const Text('Hello World'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Hello World'), findsOneWidget);

      // Dispose the widget tree so ErrorBoundary restores globals.
      await tester.pumpWidget(const SizedBox.shrink());
      // Manually restore ErrorWidget.builder since ErrorBoundary
      // sets it in build(), not initState.
      ErrorWidget.builder = originalErrorWidgetBuilder;
    });

    testWidgets('can be found by type', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ErrorBoundary(
                child: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(ErrorBoundary), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
    });

    testWidgets('accepts custom errorBuilder parameter', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ErrorBoundary(
                errorBuilder: (error, stack) =>
                    Text('Error: ${error.toString()}'),
                child: const Text('No error here'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('No error here'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
    });
  });
}
