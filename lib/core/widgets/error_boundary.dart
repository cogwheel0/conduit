import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import '../../shared/theme/theme_extensions.dart';
import '../error/enhanced_error_service.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../services/haptic_service.dart';

void installConduitErrorWidgetBuilder() {
  ErrorWidget.builder = (details) => ConduitFriendlyErrorView(details: details);
}

class ConduitFriendlyErrorView extends StatelessWidget {
  const ConduitFriendlyErrorView({super.key, required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    // ErrorWidget.builder may be invoked because an inherited widget failed.
    // Keep this last-resort surface independent of theme, localization, and
    // MediaQuery lookups so the fallback itself cannot repeat that failure.
    final dark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    final background = dark ? const Color(0xFF111214) : const Color(0xFFF7F7F8);
    final foreground = dark ? const Color(0xFFF5F5F7) : const Color(0xFF1D1D1F);
    final secondary = dark ? const Color(0xFFA7A7AC) : const Color(0xFF6E6E73);
    const errorColor = Color(0xFFFF453A);
    final debugDetails =
        '${details.exceptionAsString()}\n${details.stack ?? ''}';

    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: background,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxHeight < 300;
            final content = Semantics(
              liveRegion: true,
              label: 'Something went wrong',
              child: Padding(
                padding: const EdgeInsets.all(Spacing.pagePadding),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        size: compact ? IconSize.medium : IconSize.xxl,
                        color: errorColor,
                      ),
                      SizedBox(height: compact ? Spacing.sm : Spacing.lg),
                      Text(
                        'Something went wrong. Please try again.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: foreground,
                          fontSize: compact ? 14 : 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (kDebugMode) ...[
                        const SizedBox(height: Spacing.sm),
                        GestureDetector(
                          onLongPress: () {
                            Clipboard.setData(
                              ClipboardData(text: debugDetails),
                            );
                            ConduitHaptics.selectionClick();
                          },
                          child: Text(
                            debugDetails,
                            maxLines: compact ? 2 : 8,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: secondary,
                              fontSize: 12,
                              fontFamily: AppTypography.monospaceFontFamily,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );

            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight.isFinite
                      ? constraints.maxHeight
                      : 0,
                ),
                child: SizedBox(
                  width: constraints.maxWidth.isFinite
                      ? constraints.maxWidth
                      : null,
                  child: Center(child: content),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Widget that handles async operations with proper error handling
class AsyncErrorBoundary extends ConsumerWidget {
  final Future<Widget> Function() builder;
  final Widget? loadingWidget;
  final Widget Function(Object error)? errorWidget;
  final bool showRetry;

  const AsyncErrorBoundary({
    super.key,
    required this.builder,
    this.loadingWidget,
    this.errorWidget,
    this.showRetry = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<Widget>(
      future: builder(),
      builder: (context, snapshot) {
        // Loading state
        if (snapshot.connectionState == ConnectionState.waiting) {
          return loadingWidget ??
              const Center(child: CircularProgressIndicator());
        }

        // Error state
        if (snapshot.hasError) {
          final error = snapshot.error!;

          // Log error
          enhancedErrorService.logError(
            error,
            context: 'AsyncErrorBoundary',
            stackTrace: snapshot.stackTrace,
          );

          // Use custom error widget if provided
          if (errorWidget != null) {
            return errorWidget!(error);
          }

          // Default error widget
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 48,
                    color: context.conduitTheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    enhancedErrorService.getUserMessage(error),
                    textAlign: TextAlign.center,
                  ),
                  if (showRetry) ...[
                    const SizedBox(height: 16),
                    AdaptiveButton.child(
                      onPressed: () {
                        // Force rebuild to retry
                        (context as Element).markNeedsBuild();
                      },
                      style: AdaptiveButtonStyle.filled,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.refresh),
                          const SizedBox(width: Spacing.sm),
                          Text(AppLocalizations.of(context)?.retry ?? 'Retry'),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }

        // Success state
        return snapshot.data ?? const SizedBox.shrink();
      },
    );
  }
}

/// Stream error boundary for handling stream errors
class StreamErrorBoundary<T> extends ConsumerWidget {
  final Stream<T> stream;
  final Widget Function(T data) builder;
  final Widget? loadingWidget;
  final Widget Function(Object error)? errorWidget;
  final T? initialData;

  const StreamErrorBoundary({
    super.key,
    required this.stream,
    required this.builder,
    this.loadingWidget,
    this.errorWidget,
    this.initialData,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<T>(
      stream: stream,
      initialData: initialData,
      builder: (context, snapshot) {
        // Error state
        if (snapshot.hasError) {
          final error = snapshot.error!;

          // Log error
          enhancedErrorService.logError(
            error,
            context: 'StreamErrorBoundary',
            stackTrace: snapshot.stackTrace,
          );

          // Use custom error widget if provided
          if (errorWidget != null) {
            return errorWidget!(error);
          }

          // Default error widget
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 48,
                    color: context.conduitTheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    enhancedErrorService.getUserMessage(error),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }

        // Loading state
        if (!snapshot.hasData) {
          return loadingWidget ??
              const Center(child: CircularProgressIndicator());
        }

        // Success state
        return builder(snapshot.data as T);
      },
    );
  }
}
