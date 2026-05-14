import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../features/auth/providers/unified_auth_providers.dart';
import '../../features/chat/providers/chat_providers.dart';
import '../../features/chat/services/file_attachment_service.dart';
import '../../shared/services/tasks/task_queue.dart';
import '../providers/app_providers.dart';
import '../utils/debug_logger.dart';
import 'app_intents_service.dart';
import 'navigation_service.dart';

part 'home_widget_service.g.dart';

/// Widget action identifiers matching native widget implementations.
class WidgetActions {
  static const String newChat = 'new_chat';
  static const String mic = 'mic';
  static const String camera = 'camera';
  static const String photos = 'photos';
  static const String clipboard = 'clipboard';
}

/// App group identifier for iOS widget data sharing.
const String _appGroupId = 'group.app.cogwheel.conduit';

/// Android widget provider class name.
const String _androidWidgetName = 'ConduitWidgetProvider';

/// iOS widget kind identifier.
const String _iOSWidgetKind = 'ConduitWidget';

/// Handles home screen widget interactions for Android and iOS.
///
/// The widget provides quick actions:
/// - New Chat: Start a fresh conversation
/// - Camera: Take a photo and attach to chat
/// - Photos: Pick from gallery and attach to chat
/// - Clipboard: Paste clipboard content as prompt
@Riverpod(keepAlive: true)
class HomeWidgetCoordinator extends _$HomeWidgetCoordinator {
  StreamSubscription<Uri?>? _widgetClickSubscription;
  Uri? _pendingWidgetAction;

  @override
  FutureOr<void> build() async {
    if (kIsWeb) return;
    if (!Platform.isIOS && !Platform.isAndroid) return;

    await _initialize();

    ref.onDispose(() {
      _widgetClickSubscription?.cancel();
    });
  }

  Future<void> _initialize() async {
    try {
      // Set app group for iOS data sharing
      if (Platform.isIOS) {
        await HomeWidget.setAppGroupId(_appGroupId);
      }

      // Handle widget clicks
      _widgetClickSubscription = HomeWidget.widgetClicked.listen(
        _handleWidgetClick,
        onError: (error) {
          DebugLogger.error(
            'home-widget-stream',
            scope: 'widget',
            error: error,
          );
        },
      );

      // Check for initial launch from widget
      final initialUri = await HomeWidget.initiallyLaunchedFromHomeWidget();
      if (initialUri != null) {
        DebugLogger.log(
          'Widget: Initial launch URI: $initialUri',
          scope: 'widget',
        );
        // Store for later processing once app is ready
        _pendingWidgetAction = initialUri;
        // Try to process after a delay to allow router to initialize
        _processInitialWidgetAction();
      }

      DebugLogger.log('Home widget service initialized', scope: 'widget');
    } catch (error, stackTrace) {
      DebugLogger.error(
        'home-widget-init',
        scope: 'widget',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Process initial widget action after ensuring router and auth are ready.
  Future<void> _processInitialWidgetAction() async {
    if (_pendingWidgetAction == null) return;

    // Wait for router to be attached first
    for (var i = 0; i < 50; i++) {
      // Try for up to 5 seconds
      await Future<void>.delayed(const Duration(milliseconds: 100));

      if (NavigationService.currentRoute != null) {
        DebugLogger.log(
          'Widget: Router ready, waiting for authentication',
          scope: 'widget',
        );
        break;
      }
    }

    if (NavigationService.currentRoute == null) {
      DebugLogger.log(
        'Widget: Timeout waiting for router, clearing pending action',
        scope: 'widget',
      );
      _pendingWidgetAction = null;
      return;
    }

    // Check if action was already processed by stream handler while waiting
    if (_pendingWidgetAction == null) return;

    // Now wait for authentication to complete (up to 30 seconds for login flow)
    for (var i = 0; i < 300; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));

      if (!ref.mounted) {
        DebugLogger.log(
          'Widget: Provider disposed while waiting for auth',
          scope: 'widget',
        );
        _pendingWidgetAction = null;
        return;
      }

      final authState = ref.read(authNavigationStateProvider);
      if (authState == AuthNavigationState.authenticated) {
        DebugLogger.log(
          'Widget: Authenticated, processing pending action',
          scope: 'widget',
        );
        final uri = _pendingWidgetAction;
        _pendingWidgetAction = null;
        await _handleWidgetClick(uri);
        return;
      }

      // If user is on login page and not loading, they need to authenticate
      // Don't clear the pending action yet - keep waiting
      if (authState == AuthNavigationState.needsLogin ||
          authState == AuthNavigationState.error) {
        // Continue waiting - user might be logging in
        continue;
      }
    }

    DebugLogger.log(
      'Widget: Timeout waiting for authentication, clearing pending action',
      scope: 'widget',
    );
    _pendingWidgetAction = null;
  }

  Future<void> _handleWidgetClick(Uri? uri) async {
    if (uri == null) return;

    // If router isn't ready yet, store for later
    if (NavigationService.currentRoute == null) {
      DebugLogger.log(
        'Widget: Router not ready, storing action for later',
        scope: 'widget',
      );
      _pendingWidgetAction = uri;
      _processInitialWidgetAction();
      return;
    }

    final action = uri.host.isNotEmpty
        ? uri.host
        : uri.pathSegments.firstOrNull;
    if (action == null || action.isEmpty) {
      // Default action: open new chat
      await _handleNewChat();
      return;
    }

    DebugLogger.log('Widget action: $action', scope: 'widget');

    switch (action) {
      case WidgetActions.newChat:
        await _handleNewChat();
        break;
      case WidgetActions.mic:
        await _handleMic();
        break;
      case WidgetActions.camera:
        await _handleCamera();
        break;
      case WidgetActions.photos:
        await _handlePhotos();
        break;
      case WidgetActions.clipboard:
        await _handleClipboard();
        break;
      default:
        DebugLogger.log('Unknown widget action: $action', scope: 'widget');
        await _handleNewChat();
    }
  }

  Future<void> _handleNewChat() async {
    DebugLogger.log('Widget: Starting new chat', scope: 'widget');
    await _waitForNavigation();
    await ref
        .read(appIntentCoordinatorProvider.notifier)
        .openChatFromExternal(focusComposer: true, resetChat: true);
  }

  Future<void> _handleMic() async {
    DebugLogger.log('Widget: Starting voice call', scope: 'widget');
    await _waitForNavigation();
    try {
      await ref
          .read(appIntentCoordinatorProvider.notifier)
          .startVoiceCallFromExternal();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'home-widget-mic',
        scope: 'widget',
        error: error,
        stackTrace: stackTrace,
      );
      // Fall back to opening chat with focus
      await ref
          .read(appIntentCoordinatorProvider.notifier)
          .openChatFromExternal(focusComposer: true, resetChat: true);
    }
  }

  Future<void> _handleCamera() async {
    DebugLogger.log('Widget: Opening camera', scope: 'widget');
    await _waitForNavigation();

    // Navigate to chat first
    await ref
        .read(appIntentCoordinatorProvider.notifier)
        .openChatFromExternal(focusComposer: false, resetChat: true);

    // Wait for navigation to settle
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Check auth state
    final navState = ref.read(authNavigationStateProvider);
    if (navState != AuthNavigationState.authenticated) {
      DebugLogger.log('Widget: Not authenticated for camera', scope: 'widget');
      return;
    }

    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );

      if (image != null) {
        await _attachFile(File(image.path));
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'home-widget-camera',
        scope: 'widget',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _handlePhotos() async {
    DebugLogger.log('Widget: Opening photo picker', scope: 'widget');
    await _waitForNavigation();

    // Navigate to chat first
    await ref
        .read(appIntentCoordinatorProvider.notifier)
        .openChatFromExternal(focusComposer: false, resetChat: true);

    // Wait for navigation to settle
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Check auth state
    final navState = ref.read(authNavigationStateProvider);
    if (navState != AuthNavigationState.authenticated) {
      DebugLogger.log('Widget: Not authenticated for photos', scope: 'widget');
      return;
    }

    try {
      final picker = ImagePicker();
      final images = await picker.pickMultiImage(imageQuality: 85);

      if (images.isNotEmpty) {
        for (final image in images) {
          await _attachFile(File(image.path));
        }
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'home-widget-photos',
        scope: 'widget',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _handleClipboard() async {
    DebugLogger.log('Widget: Pasting from clipboard', scope: 'widget');
    await _waitForNavigation();

    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      final text = clipboardData?.text?.trim();

      if (text == null || text.isEmpty) {
        DebugLogger.log('Widget: Clipboard is empty', scope: 'widget');
        // Still open chat even if clipboard is empty
        await ref
            .read(appIntentCoordinatorProvider.notifier)
            .openChatFromExternal(focusComposer: true, resetChat: true);
        return;
      }

      await ref
          .read(appIntentCoordinatorProvider.notifier)
          .openChatFromExternal(
            prompt: text,
            focusComposer: true,
            resetChat: true,
          );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'home-widget-clipboard',
        scope: 'widget',
        error: error,
        stackTrace: stackTrace,
      );
      // Fall back to just opening chat
      await ref
          .read(appIntentCoordinatorProvider.notifier)
          .openChatFromExternal(focusComposer: true, resetChat: true);
    }
  }

  /// Wait for the navigation system to be ready.
  Future<void> _waitForNavigation() async {
    // Wait for bindings to be initialized
    WidgetsBinding.instance.addPostFrameCallback((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  Future<void> _attachFile(File file) async {
    if (!ref.mounted) return;

    // Warm the attachment service
    final _ = ref.read(fileAttachmentServiceProvider);
    final notifier = ref.read(attachedFilesProvider.notifier);
    final taskQueue = ref.read(taskQueueProvider.notifier);
    final activeConv = ref.read(activeConversationProvider);

    final attachment = LocalAttachment(
      file: file,
      displayName: path.basename(file.path),
    );

    notifier.addFiles([attachment]);

    try {
      await taskQueue.enqueueUploadMedia(
        conversationId: activeConv?.id,
        filePath: file.path,
        fileName: attachment.displayName,
        fileSize: await file.length(),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'home-widget-upload',
        scope: 'widget',
        error: error,
        stackTrace: stackTrace,
      );
    }

    // Focus the composer after attaching
    final tick = ref.read(inputFocusTriggerProvider);
    ref.read(inputFocusTriggerProvider.notifier).set(tick + 1);
  }

  /// Update widget data displayed on home screen.
  ///
  /// Call this when app state changes that should be reflected in widget.
  Future<void> updateWidgetData() async {
    if (kIsWeb) return;
    if (!Platform.isIOS && !Platform.isAndroid) return;

    try {
      // For now, we just trigger a widget update
      // In the future, we could pass data like recent conversations

      if (Platform.isAndroid) {
        await HomeWidget.updateWidget(androidName: _androidWidgetName);
      } else if (Platform.isIOS) {
        await HomeWidget.updateWidget(iOSName: _iOSWidgetKind);
      }

      DebugLogger.log('Widget data updated', scope: 'widget');
    } catch (error, stackTrace) {
      DebugLogger.error(
        'home-widget-update',
        scope: 'widget',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

/// Provider to trigger home widget initialization at app startup.
final homeWidgetInitializerProvider = Provider<void>((ref) {
  if (kIsWeb) return;
  if (!Platform.isIOS && !Platform.isAndroid) return;

  // Initialize the coordinator which sets up widget click handling
  ref.watch(homeWidgetCoordinatorProvider);
});
