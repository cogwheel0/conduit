import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import '../../shared/theme/theme_extensions.dart';
import '../../shared/widgets/adaptive_route_shell.dart';
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

/// Owns one link in the process-global [FlutterError.onError] chain.
///
/// Exposed for lifecycle tests; app code should use [ErrorBoundary].
@visibleForTesting
final class ErrorBoundaryHandlerRegistration {
  ErrorBoundaryHandlerRegistration(this.onError) {
    _installed = _handle;
  }

  static final Set<ErrorBoundaryHandlerRegistration> _active = {};

  final void Function(
    FlutterErrorDetails details,
    void Function(FlutterErrorDetails details)? previous,
  )
  onError;
  void Function(FlutterErrorDetails details)? _previous;
  late final void Function(FlutterErrorDetails details) _installed;

  void _handle(FlutterErrorDetails details) {
    onError(details, _previous);
  }

  void install() {
    _previous = FlutterError.onError;
    _active.add(this);
    FlutterError.onError = _installed;
  }

  void dispose() {
    for (final registration in _active) {
      if (identical(registration._previous, _installed)) {
        registration._previous = _previous;
      }
    }
    _active.remove(this);
    if (identical(FlutterError.onError, _installed)) {
      FlutterError.onError = _previous;
    }
  }
}

/// Error boundary widget that catches and handles errors in child widgets
class ErrorBoundary extends ConsumerStatefulWidget {
  final Widget child;
  final Widget Function(Object error, StackTrace? stack)? errorBuilder;
  final void Function(Object error, StackTrace? stack)? onError;
  final bool showErrorDialog;
  final bool allowRetry;

  const ErrorBoundary({
    super.key,
    required this.child,
    this.errorBuilder,
    this.onError,
    this.showErrorDialog = false,
    this.allowRetry = true,
  });

  @override
  ConsumerState<ErrorBoundary> createState() => _ErrorBoundaryState();
}

class _ErrorBoundaryState extends ConsumerState<ErrorBoundary> {
  Object? _error;
  StackTrace? _stackTrace;
  bool _hasError = false;
  late final ErrorBoundaryHandlerRegistration _handlerRegistration;

  bool _shouldIgnoreError(Object error) {
    final errorString = error.toString();
    // Ignore RenderFlex overflow errors (layout issues)
    if (errorString.contains('RenderFlex') ||
        errorString.contains('overflow') && errorString.contains('pixels')) {
      return true;
    }
    // Ignore "Build scheduled during frame" errors - these are harmless
    // framework warnings from animations during layout
    if (errorString.contains('Build scheduled during frame')) {
      return true;
    }
    return false;
  }

  void _scheduleHandleError(Object error, StackTrace? stack) {
    // Skip errors that should be ignored
    if (_shouldIgnoreError(error)) {
      return;
    }

    // Defer to next frame to avoid setState during build exceptions
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _handleError(error, stack);
      }
    });
  }

  @override
  void initState() {
    super.initState();

    _handlerRegistration = ErrorBoundaryHandlerRegistration((
      details,
      previous,
    ) {
      // Check if this is a harmless error we should completely ignore
      if (_shouldIgnoreError(details.exception)) {
        return; // Don't forward or handle
      }
      previous?.call(details);
      // Defer handling to avoid setState during build
      _scheduleHandleError(details.exception, details.stack);
    })..install();
  }

  @override
  void dispose() {
    _handlerRegistration.dispose();
    super.dispose();
  }

  void _handleError(Object error, StackTrace? stack) {
    // Log error
    enhancedErrorService.logError(
      error,
      context: 'ErrorBoundary',
      stackTrace: stack,
    );

    // Call custom error handler if provided
    widget.onError?.call(error, stack);

    // Update state
    if (mounted) {
      setState(() {
        _error = error;
        _stackTrace = stack;
        _hasError = true;
      });

      // Show error dialog if requested
      if (widget.showErrorDialog && context.mounted) {
        enhancedErrorService.showErrorDialog(context, error);
      }
    }
  }

  void _retry() {
    setState(() {
      _error = null;
      _stackTrace = null;
      _hasError = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError && _error != null) {
      // Use custom error builder if provided
      if (widget.errorBuilder != null) {
        return widget.errorBuilder!(_error!, _stackTrace);
      }

      // Default error UI
      // Respect ambient text direction when available; fall back to LTR.
      TextDirection direction;
      try {
        direction = Directionality.of(context);
      } catch (_) {
        direction = TextDirection.ltr;
      }

      return Directionality(
        textDirection: direction,
        child: AdaptiveRouteShell(
          bodySafeArea: true,
          body: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.pagePadding,
                vertical: Spacing.lg,
              ),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 480),
                decoration: BoxDecoration(
                  color: context.conduitTheme.cardBackground,
                  borderRadius: BorderRadius.circular(
                    context.conduitTheme.radiusLg,
                  ),
                  border: Border.all(
                    color: context.conduitTheme.cardBorder,
                    width: BorderWidth.regular,
                  ),
                  boxShadow: context.conduitTheme.cardShadows,
                ),
                padding: const EdgeInsets.all(Spacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Error icon with gradient background
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: context.conduitTheme.errorBackground,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.error_outline_rounded,
                        size: 40,
                        color: context.conduitTheme.error,
                      ),
                    ),
                    const SizedBox(height: Spacing.lg),

                    // Error title
                    Text(
                      AppLocalizations.of(context)?.errorMessage ??
                          'Something went wrong',
                      style: context.conduitTheme.headingSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: Spacing.sm),

                    // Error description
                    Text(
                      enhancedErrorService.getUserMessage(_error!),
                      textAlign: TextAlign.center,
                      style: context.conduitTheme.bodySmall?.copyWith(
                        color: context.conduitTheme.textSecondary,
                      ),
                    ),

                    if (widget.allowRetry) ...[
                      const SizedBox(height: Spacing.xl),

                      // Retry button
                      SizedBox(
                        width: double.infinity,
                        child: AdaptiveButton.child(
                          onPressed: _retry,
                          color: context.conduitTheme.buttonPrimary,
                          style: AdaptiveButtonStyle.filled,
                          borderRadius: BorderRadius.circular(
                            context.conduitTheme.radiusMd,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: Spacing.lg,
                            vertical: Spacing.md,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.refresh_rounded),
                              const SizedBox(width: Spacing.sm),
                              Text(
                                AppLocalizations.of(context)?.retry ??
                                    'Try Again',
                                style: context.conduitTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: context.conduitTheme.buttonPrimaryText,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Wrap child in error handler
    return Builder(
      builder: (context) {
        try {
          return widget.child;
        } catch (error, stack) {
          // Defer handling to avoid setState during build
          _scheduleHandleError(error, stack);
          return ConduitFriendlyErrorView(
            details: FlutterErrorDetails(exception: error, stack: stack),
          );
        }
      },
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
