import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../platform/conduit_platform_apis.g.dart';

import 'package:conduit_core/utils/debug_logger.dart';

void _logNativeSheetBridgeError(
  String method,
  Object error,
  StackTrace stackTrace, {
  Map<String, Object?> data = const {},
}) {
  DebugLogger.error(
    'native-sheet-bridge-call-failed',
    scope: 'native-sheet',
    error: error,
    stackTrace: stackTrace,
    data: {'method': method, ...data},
  );
}

@immutable
class NativeSheetThemeConfig {
  const NativeSheetThemeConfig({
    required this.isDark,
    required this.backgroundArgb,
    required this.surfaceArgb,
    required this.elevatedSurfaceArgb,
    required this.inputArgb,
    required this.foregroundArgb,
    required this.secondaryForegroundArgb,
    required this.iconArgb,
    required this.borderArgb,
    required this.accentArgb,
    required this.onAccentArgb,
    required this.destructiveArgb,
  });

  final bool isDark;
  final int backgroundArgb;
  final int surfaceArgb;
  final int elevatedSurfaceArgb;
  final int inputArgb;
  final int foregroundArgb;
  final int secondaryForegroundArgb;
  final int iconArgb;
  final int borderArgb;
  final int accentArgb;
  final int onAccentArgb;
  final int destructiveArgb;

  PlatformNativeSheetTheme toPlatform() => PlatformNativeSheetTheme(
    isDark: isDark,
    backgroundArgb: backgroundArgb,
    surfaceArgb: surfaceArgb,
    elevatedSurfaceArgb: elevatedSurfaceArgb,
    inputArgb: inputArgb,
    foregroundArgb: foregroundArgb,
    secondaryForegroundArgb: secondaryForegroundArgb,
    iconArgb: iconArgb,
    borderArgb: borderArgb,
    accentArgb: accentArgb,
    onAccentArgb: onAccentArgb,
    destructiveArgb: destructiveArgb,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NativeSheetThemeConfig &&
          isDark == other.isDark &&
          backgroundArgb == other.backgroundArgb &&
          surfaceArgb == other.surfaceArgb &&
          elevatedSurfaceArgb == other.elevatedSurfaceArgb &&
          inputArgb == other.inputArgb &&
          foregroundArgb == other.foregroundArgb &&
          secondaryForegroundArgb == other.secondaryForegroundArgb &&
          iconArgb == other.iconArgb &&
          borderArgb == other.borderArgb &&
          accentArgb == other.accentArgb &&
          onAccentArgb == other.onAccentArgb &&
          destructiveArgb == other.destructiveArgb;

  @override
  int get hashCode => Object.hash(
    isDark,
    backgroundArgb,
    surfaceArgb,
    elevatedSurfaceArgb,
    inputArgb,
    foregroundArgb,
    secondaryForegroundArgb,
    iconArgb,
    borderArgb,
    accentArgb,
    onAccentArgb,
    destructiveArgb,
  );
}

class NativeSheetRoutes {
  const NativeSheetRoutes._();

  static const profileMenu = 'profile-menu';
  static const profile = 'profile';
  static const accountSettings = 'account-settings';
  static const personalization = 'personalization';
  static const audioSettings = 'audio-settings';
  static const appCustomization = 'app-customization';
  static const appearance = 'appearance';
  static const chats = 'chats';
  static const voice = 'voice';
  static const voiceProvider = 'voice-provider';
  static const aiMemory = 'ai-memory';
  static const dataConnection = 'data-connection';
  static const hermes = 'hermes';
  /// The Direct Connections page, Settings's own.
  static const directConnections = 'direct-connections';
  static const personalConnections = 'open-personal-connections';
  static const scheduledTasks = 'open-scheduled-tasks';
  static const calendar = 'open-calendar';
  /// The Chat Data Controls page, Settings's own.
  static const chatDataControls = 'chat-data-controls';
  static const helpAbout = 'help-about';
  static const about = 'about';
  static const notificationSettings = 'notification-settings';
  static const pushTargets = 'push-targets';
  static const workspace = 'workspace-entry';
  static const releaseNotesManual = 'release-notes-manual';
  static const openSourceLicenses = 'open-source-licenses';
}

class NativeSheetBridge implements NativeSheetFlutterApi {
  NativeSheetBridge._() {
    NativeSheetFlutterApi.setUp(this);
  }

  static final NativeSheetBridge instance = NativeSheetBridge._();

  final NativeSheetHostApi _api = NativeSheetHostApi();

  /// Method channel for host calls the generated API does not carry.
  static const nativeSheetChannelName = 'app.cogwheel.conduit/native_sheet';
  final MethodChannel _profileChannel = const MethodChannel(
    nativeSheetChannelName,
  );
  final StreamController<NativeSheetEvent> _events =
      StreamController<NativeSheetEvent>.broadcast();
  Future<void> Function(String modelId)? _modelPinToggleHandler;
  Object? _modelPinToggleHandlerOwner;
  Future<void> Function(String value)? _reasoningEffortChangedHandler;
  Object? _reasoningEffortChangedHandlerOwner;
  Future<void> Function(String key, String value)? _modelControlChangedHandler;
  Object? _modelControlChangedHandlerOwner;
  Object? _reasoningEffortUpdateOwner;
  Future<void> _reasoningEffortUpdateQueue = Future<void>.value();
  NativeSheetThemeConfig? _lastTheme;

  @visibleForTesting
  bool? debugIsIOSOverride;

  Stream<NativeSheetEvent> get events => _events.stream;

  bool get _isIOS => debugIsIOSOverride ?? Platform.isIOS;

  Future<void> syncTheme(NativeSheetThemeConfig theme) async {
    if (!_isIOS || theme == _lastTheme) return;
    _lastTheme = theme;
    try {
      await _api.setTheme(theme.toPlatform());
    } on PlatformException catch (error, stackTrace) {
      _lastTheme = null;
      _logNativeSheetBridgeError('setTheme', error, stackTrace);
    } catch (error, stackTrace) {
      _lastTheme = null;
      _logNativeSheetBridgeError('setTheme', error, stackTrace);
    }
  }

  @visibleForTesting
  void debugResetThemeCache() {
    _lastTheme = null;
  }

  /// Whether the Settings sheet is up, so a question from one of its pages
  /// is asked over it.
  bool get settingsSheetOpen => _settingsSheetOpen;
  bool _settingsSheetOpen = false;

  Future<bool> presentProfileMenu(NativeProfileSheetConfig config) async {
    if (!_isIOS) return false;
    try {
      final presented = await _api.presentProfileMenu(config.toPlatform());
      if (presented) _settingsSheetOpen = true;
      return presented;
    } on PlatformException catch (error, stackTrace) {
      _logNativeSheetBridgeError('presentProfileMenu', error, stackTrace);
      return false;
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError('presentProfileMenu', error, stackTrace);
      return false;
    }
  }

  Future<bool> dismiss() async {
    if (!_isIOS) return false;
    try {
      return await _api.dismiss();
    } on PlatformException catch (error, stackTrace) {
      _logNativeSheetBridgeError('dismiss', error, stackTrace);
      return false;
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError('dismiss', error, stackTrace);
      return false;
    }
  }

  /// Closes the Settings sheet and waits until it has gone, so whatever is
  /// shown next is not presented over a sheet still leaving. Returns
  /// whether Settings is closed: true when it was not open, false when it
  /// had not gone within [patience].
  Future<bool> dismissSettings({
    Duration patience = const Duration(seconds: 2),
  }) async {
    if (!_isIOS || !_settingsSheetOpen) return true;
    var waitedOut = false;
    final gone = _events.stream
        .firstWhere((event) => event is NativeSheetDismissed)
        .timeout(
          patience,
          onTimeout: () {
            waitedOut = true;
            return const NativeSheetDismissed();
          },
        );
    if (!await dismiss()) {
      unawaited(gone.then((_) {}, onError: (_) {}));
      return false;
    }
    _settingsLeaving = true;
    await gone;
    return !waitedOut;
  }

  bool _settingsLeaving = false;

  /// Whether Settings was asked to close, agreed, and has not gone yet:
  /// [dismissSettings] stopped waiting for a sheet still leaving.
  bool get settingsLeaving => _settingsLeaving && _settingsSheetOpen;

  /// Completes once Settings has closed, at once when it is not open.
  Future<void> untilSettingsClosed() => _settingsSheetOpen
      ? _events.stream.firstWhere((event) => event is NativeSheetDismissed)
      : Future<void>.value();

  @visibleForTesting
  set debugSettingsSheetOpen(bool open) => _settingsSheetOpen = open;

  Future<bool> requestAppStoreReview() async {
    if (!_isIOS) return false;
    try {
      return await _api.requestAppStoreReview();
    } on PlatformException catch (error, stackTrace) {
      _logNativeSheetBridgeError('requestAppStoreReview', error, stackTrace);
      return false;
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError('requestAppStoreReview', error, stackTrace);
      return false;
    }
  }

  Future<String?> presentModelSelector({
    required String presentationId,
    required String title,
    required List<NativeSheetModelOption> models,
    String? selectedModelId,
    List<String> pinnedModelIds = const <String>[],
    List<String> featuredModelIds = const <String>[],
    String? pinTitle,
    String? unpinTitle,
    String moreModelsTitle = 'More models',
    String searchModelsTitle = 'Search models',
    String reasoningEffortTitle = 'Effort',
    String reasoningEffortValue = 'medium',
    List<String> reasoningEffortOptions = const <String>[
      'low',
      'medium',
      'high',
    ],
    Map<String, String> reasoningEffortLabels = const <String, String>{},
    bool allowsCustomReasoningEffort = true,
    String customReasoningEffortTitle = 'Custom effort',
    String customReasoningEffortHint = 'Enter effort',
    List<PlatformNativeSheetModelControl> modelControls =
        const <PlatformNativeSheetModelControl>[],
    String modelControlDefaultTitle = 'Default',
    Future<void> Function(String modelId)? onTogglePinned,
    Future<void> Function(String value)? onReasoningEffortChanged,
    Future<void> Function(String key, String value)? onModelControlChanged,
    bool rethrowErrors = false,
  }) async {
    final normalizedPresentationId = presentationId.trim();
    if (!_isIOS || models.isEmpty || normalizedPresentationId.isEmpty) {
      return null;
    }
    // One selector is up at a time: its control picks go to its handler
    // until it closes. A second one the platform refuses leaves the open
    // one's handler in place.
    final previousControlHandler = _modelControlChangedHandler;
    final previousControlHandlerOwner = _modelControlChangedHandlerOwner;
    final controlHandlerOwner = Object();
    _modelControlChangedHandler = onModelControlChanged;
    _modelControlChangedHandlerOwner = controlHandlerOwner;
    void restorePreviousControlHandler() {
      if (!identical(_modelControlChangedHandlerOwner, controlHandlerOwner)) {
        return;
      }
      _modelControlChangedHandler = previousControlHandler;
      _modelControlChangedHandlerOwner = previousControlHandlerOwner;
    }

    final previousPinToggleHandler = _modelPinToggleHandler;
    final previousPinToggleHandlerOwner = _modelPinToggleHandlerOwner;
    final previousEffortHandler = _reasoningEffortChangedHandler;
    final previousEffortHandlerOwner = _reasoningEffortChangedHandlerOwner;
    final previousEffortUpdateOwner = _reasoningEffortUpdateOwner;
    final pinToggleHandlerOwner = Object();
    var shouldClearPinToggleHandler = false;
    _modelPinToggleHandler = onTogglePinned;
    _modelPinToggleHandlerOwner = pinToggleHandlerOwner;
    _reasoningEffortChangedHandler = onReasoningEffortChanged;
    _reasoningEffortChangedHandlerOwner = pinToggleHandlerOwner;
    _reasoningEffortUpdateOwner = null;
    try {
      final result = await _api.presentModelSelector(
        PlatformNativeSheetModelSelectorRequest(
          presentationId: normalizedPresentationId,
          title: title,
          selectedModelId: selectedModelId,
          models: models.map((model) => model.toPlatform()).toList(),
          pinnedModelIds: pinnedModelIds,
          featuredModelIds: featuredModelIds,
          allowsPinning: onTogglePinned != null,
          pinTitle: pinTitle,
          unpinTitle: unpinTitle,
          moreModelsTitle: moreModelsTitle,
          searchModelsTitle: searchModelsTitle,
          reasoningEffortTitle: reasoningEffortTitle,
          reasoningEffortValue: reasoningEffortValue,
          reasoningEffortOptions: reasoningEffortOptions,
          reasoningEffortLabels: reasoningEffortLabels,
          allowsCustomReasoningEffort: allowsCustomReasoningEffort,
          customReasoningEffortTitle: customReasoningEffortTitle,
          customReasoningEffortHint: customReasoningEffortHint,
          modelControls: modelControls,
          modelControlDefaultTitle: modelControlDefaultTitle,
        ),
      );
      shouldClearPinToggleHandler = true;
      if (result != null) {
        return result;
      }
      return null;
    } on PlatformException catch (error, stackTrace) {
      if (!shouldClearPinToggleHandler) {
        restorePreviousControlHandler();
        _restorePreviousModelPinToggleHandler(
          owner: pinToggleHandlerOwner,
          previousHandler: previousPinToggleHandler,
          previousOwner: previousPinToggleHandlerOwner,
        );
        _restorePreviousReasoningEffortHandler(
          owner: pinToggleHandlerOwner,
          previousHandler: previousEffortHandler,
          previousOwner: previousEffortHandlerOwner,
          previousUpdateOwner: previousEffortUpdateOwner,
        );
      }
      _logNativeSheetBridgeError(
        'presentModelSelector',
        error,
        stackTrace,
        data: {'modelCount': models.length},
      );
      if (rethrowErrors) rethrow;
      return null;
    } catch (error, stackTrace) {
      if (!shouldClearPinToggleHandler) {
        restorePreviousControlHandler();
        _restorePreviousModelPinToggleHandler(
          owner: pinToggleHandlerOwner,
          previousHandler: previousPinToggleHandler,
          previousOwner: previousPinToggleHandlerOwner,
        );
        _restorePreviousReasoningEffortHandler(
          owner: pinToggleHandlerOwner,
          previousHandler: previousEffortHandler,
          previousOwner: previousEffortHandlerOwner,
          previousUpdateOwner: previousEffortUpdateOwner,
        );
      }
      _logNativeSheetBridgeError(
        'presentModelSelector',
        error,
        stackTrace,
        data: {'modelCount': models.length},
      );
      if (rethrowErrors) rethrow;
      return null;
    } finally {
      if (shouldClearPinToggleHandler &&
          identical(_modelControlChangedHandlerOwner, controlHandlerOwner)) {
        _modelControlChangedHandler = null;
        _modelControlChangedHandlerOwner = null;
      }
      if (shouldClearPinToggleHandler &&
          identical(_modelPinToggleHandlerOwner, pinToggleHandlerOwner)) {
        _modelPinToggleHandler = null;
        _modelPinToggleHandlerOwner = null;
        if (identical(
          _reasoningEffortChangedHandlerOwner,
          pinToggleHandlerOwner,
        )) {
          _reasoningEffortChangedHandler = null;
          _reasoningEffortChangedHandlerOwner = null;
          _reasoningEffortUpdateOwner = null;
        }
      }
    }
  }

  Future<void> updateModelSelectorModels(
    List<NativeSheetModelOption> models, {
    required String presentationId,
  }) async {
    final normalizedPresentationId = presentationId.trim();
    if (!_isIOS || models.isEmpty || normalizedPresentationId.isEmpty) return;
    try {
      await _api.updateModelSelectorModels(
        normalizedPresentationId,
        models.map((model) => model.toPlatform()).toList(growable: false),
      );
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError(
        'updateModelSelectorModels',
        error,
        stackTrace,
        data: {'modelCount': models.length},
      );
    }
  }

  Future<void> updateModelSelectorReasoningEffort({
    required String presentationId,
    required String value,
    required List<String> options,
    required bool allowsCustom,
    Future<void> Function(String value)? onReasoningEffortChanged,
  }) async {
    final normalizedPresentationId = presentationId.trim();
    if (!_isIOS || normalizedPresentationId.isEmpty) return;
    final previousUpdate = _reasoningEffortUpdateQueue;
    final updateComplete = Completer<void>();
    _reasoningEffortUpdateQueue = updateComplete.future;
    await previousUpdate;
    try {
      final previousHandler = _reasoningEffortChangedHandler;
      final previousUpdateOwner = _reasoningEffortUpdateOwner;
      final updateOwner = Object();
      _reasoningEffortChangedHandler = onReasoningEffortChanged;
      _reasoningEffortUpdateOwner = updateOwner;
      try {
        await _api.updateModelSelectorReasoningEffort(
          normalizedPresentationId,
          value,
          options,
          allowsCustom,
        );
      } catch (error, stackTrace) {
        if (identical(_reasoningEffortUpdateOwner, updateOwner)) {
          _reasoningEffortChangedHandler = previousHandler;
          _reasoningEffortUpdateOwner = previousUpdateOwner;
        }
        _logNativeSheetBridgeError(
          'updateModelSelectorReasoningEffort',
          error,
          stackTrace,
          data: {'optionCount': options.length},
        );
      }
    } finally {
      updateComplete.complete();
    }
  }

  /// Shows [controls] as the selector [presentationId]'s control rows again,
  /// as the account holds them.
  Future<void> updateModelSelectorModelControls({
    required String presentationId,
    required List<PlatformNativeSheetModelControl> controls,
  }) async {
    final normalizedPresentationId = presentationId.trim();
    if (!_isIOS || normalizedPresentationId.isEmpty) return;
    try {
      await _api.updateModelSelectorModelControls(
        normalizedPresentationId,
        controls,
      );
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError(
        'updateModelSelectorModelControls',
        error,
        stackTrace,
        data: {'controlCount': controls.length},
      );
    }
  }

  void _restorePreviousModelPinToggleHandler({
    required Object owner,
    required Future<void> Function(String modelId)? previousHandler,
    required Object? previousOwner,
  }) {
    if (!identical(_modelPinToggleHandlerOwner, owner)) {
      return;
    }
    _modelPinToggleHandler = previousHandler;
    _modelPinToggleHandlerOwner = previousOwner;
  }

  void _restorePreviousReasoningEffortHandler({
    required Object owner,
    required Future<void> Function(String value)? previousHandler,
    required Object? previousOwner,
    required Object? previousUpdateOwner,
  }) {
    if (!identical(_reasoningEffortChangedHandlerOwner, owner)) return;
    _reasoningEffortChangedHandler = previousHandler;
    _reasoningEffortChangedHandlerOwner = previousOwner;
    _reasoningEffortUpdateOwner = previousUpdateOwner;
  }

  /// Returns the selected ID, or null on dismissal, unsupported input, or suppressed errors.
  /// [filterAllLabel] enables group filtering; [rethrowErrors] preserves presentation failures.
  Future<String?> presentOptionsSelector({
    required String title,
    required List<NativeSheetOptionConfig> options,
    String? subtitle,
    String? selectedOptionId,
    bool searchable = true,
    String? filterAllLabel,
    bool rethrowErrors = false,
  }) async {
    if (!_isIOS || options.isEmpty) return null;
    try {
      return await _api.presentOptionsSelector(
        PlatformNativeSheetOptionsSelectorRequest(
          title: title,
          subtitle: subtitle,
          selectedOptionId: selectedOptionId,
          searchable: searchable,
          filterAllLabel: filterAllLabel,
          options: options.map((option) => option.toPlatform()).toList(),
        ),
      );
    } on PlatformException catch (error, stackTrace) {
      _logNativeSheetBridgeError(
        'presentOptionsSelector',
        error,
        stackTrace,
        data: {'optionCount': options.length},
      );
      if (rethrowErrors) rethrow;
      return null;
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError(
        'presentOptionsSelector',
        error,
        stackTrace,
        data: {'optionCount': options.length},
      );
      if (rethrowErrors) rethrow;
      return null;
    }
  }

  Future<DateTime?> presentDatePicker({
    required String title,
    required DateTime initialDate,
    required DateTime firstDate,
    required DateTime lastDate,
    String? doneLabel,
    String? cancelLabel,
    bool rethrowErrors = false,
  }) async {
    if (!_isIOS) return null;
    try {
      final raw = await _api.presentDatePicker(
        PlatformNativeSheetDatePickerRequest(
          title: title,
          initialDateIso8601: initialDate.toIso8601String(),
          firstDateIso8601: firstDate.toIso8601String(),
          lastDateIso8601: lastDate.toIso8601String(),
          doneLabel: doneLabel,
          cancelLabel: cancelLabel,
        ),
      );
      if (raw == null || raw.isEmpty) return null;
      return DateTime.tryParse(raw);
    } on PlatformException catch (error, stackTrace) {
      _logNativeSheetBridgeError('presentDatePicker', error, stackTrace);
      if (rethrowErrors) rethrow;
      return null;
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError('presentDatePicker', error, stackTrace);
      if (rethrowErrors) rethrow;
      return null;
    }
  }

  Future<NativeSheetActionResult?> presentTextEditor({
    required String title,
    required String value,
    String? placeholder,
    String? sendLabel,
    String valueId = 'text',
    String sendActionId = 'send',
    String closeActionId = 'close',
    bool emitChanges = false,
    bool rethrowErrors = false,
  }) async {
    if (!_isIOS) return null;
    try {
      final raw = await _api.presentTextEditor(
        PlatformNativeSheetTextEditorRequest(
          title: title,
          value: value,
          placeholder: placeholder,
          sendLabel: sendLabel,
          valueId: valueId,
          sendActionId: sendActionId,
          closeActionId: closeActionId,
          emitChanges: emitChanges,
        ),
      );
      return raw == null ? null : NativeSheetActionResult.fromPlatform(raw);
    } on PlatformException catch (error, stackTrace) {
      _logNativeSheetBridgeError('presentTextEditor', error, stackTrace);
      if (rethrowErrors) rethrow;
      return null;
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError('presentTextEditor', error, stackTrace);
      if (rethrowErrors) rethrow;
      return null;
    }
  }

  Future<NativeSheetActionResult?> presentSheet({
    required NativeSheetDetailConfig root,
    List<NativeSheetDetailConfig> detailSheets = const [],
    bool rethrowErrors = false,
  }) async {
    if (!_isIOS) return null;
    try {
      final raw = await _api.presentResultSheet(
        PlatformNativeSheetResultRequest(
          root: root.toPlatform(),
          detailSheets: detailSheets
              .map((detail) => detail.toPlatform())
              .toList(),
        ),
      );
      return raw == null ? null : NativeSheetActionResult.fromPlatform(raw);
    } on PlatformException catch (error, stackTrace) {
      _logNativeSheetBridgeError(
        'presentResultSheet',
        error,
        stackTrace,
        data: {'rootId': root.id},
      );
      if (rethrowErrors) rethrow;
      return null;
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError(
        'presentResultSheet',
        error,
        stackTrace,
        data: {'rootId': root.id},
      );
      if (rethrowErrors) rethrow;
      return null;
    }
  }

  /// Replace items for an already-presented detail screen (lazy hydration).
  ///
  /// [NativeSheetRoutes.profileMenu] is reserved for the Settings root
  /// itself: its [sections] (and [title]) replace the open root's rows.
  Future<bool> applyDetailPatch({
    required String detailId,
    required List<NativeSheetItemConfig> items,
    List<NativeSheetSectionConfig> sections = const [],
    String? title,
    String? subtitle,
    bool clearSubtitle = false,
    List<NativeSheetDetailConfig> detailSheets = const [],
    NativeSheetDetailConfig? whole,
  }) async {
    if (items.isNotEmpty && sections.isNotEmpty) {
      throw ArgumentError(
        'A native detail patch must use either items or sections, not both.',
      );
    }
    if (!_isIOS) return false;
    try {
      return await _api.applyDetailPatch(
        PlatformNativeSheetApplyDetailPatchRequest(
          detailId: detailId,
          items: items.map((item) => item.toPlatform()).toList(),
          sections: sections.map((section) => section.toPlatform()).toList(),
          title: title,
          subtitle: subtitle,
          clearSubtitle: clearSubtitle,
          detailSheets: detailSheets.isEmpty
              ? null
              : detailSheets.map((detail) => detail.toPlatform()).toList(),
          whole: whole?.toPlatform(),
        ),
      );
    } on PlatformException catch (error, stackTrace) {
      _logNativeSheetBridgeError(
        'applyDetailPatch',
        error,
        stackTrace,
        data: {'detailId': detailId},
      );
      return false;
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError(
        'applyDetailPatch',
        error,
        stackTrace,
        data: {'detailId': detailId},
      );
      return false;
    }
  }

  /// Hands the open native Settings sheet a newer copy of the account profile,
  /// so its header and profile editors start from what the server holds now
  /// instead of the copy the sheet opened with. Returns false when no
  /// Settings sheet is open to take it.
  Future<bool> updateProfile(NativeProfileSheetUser profile) async {
    if (!_isIOS) return false;
    try {
      return await _profileChannel.invokeMethod<bool>(
            'updateProfile',
            profile.toMap(),
          ) ??
          false;
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError('updateProfile', error, stackTrace);
      return false;
    }
  }

  /// Closes page [detailId] of the open Settings sheet, back to the page
  /// that opened it. Returns false when it was not open.
  /// Asks [title] over whatever is on screen, the Settings sheet included,
  /// without closing it. Returns the id of the action chosen, or null when
  /// nothing could be shown.
  Future<String?> presentAlert({
    required String title,
    String? message,
    required List<NativeSheetAlertAction> actions,
  }) async {
    if (!_isIOS) return null;
    try {
      return await _api.presentAlert(
        PlatformNativeSheetAlertRequest(
          title: title,
          message: message,
          actions: [
            for (final action in actions)
              PlatformNativeSheetAlertAction(
                id: action.id,
                label: action.label,
                style: action.style.platformName,
              ),
          ],
        ),
      );
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError('presentAlert', error, stackTrace);
      return null;
    }
  }

  /// The web sign-ins open over Settings, by session id: what each asks
  /// before it loads a page or checks one.
  final Map<
    String,
    ({
      bool Function(String url) allowsNavigation,
      bool Function(String url) checksPage,
    })
  >
  _webSignIns = {};
  int _webSignInCount = 0;

  /// Opens [url] in a web view over Settings for the user to sign in.
  /// [allowsNavigation] decides each page its main frame may load; on a page
  /// [checksPage] names, the web view runs [checkScript] (with [checkUrl] as
  /// its `url`). Answers true once that says the user is signed in, false
  /// when the web view is closed first, or cannot open.
  Future<bool> presentWebSignIn({
    required String title,
    required String url,
    required String checkScript,
    required String checkUrl,
    required String loadFailedMessage,
    required bool Function(String url) allowsNavigation,
    required bool Function(String url) checksPage,
    String cancelLabel = 'Cancel',
    String reloadLabel = 'Reload',
  }) async {
    if (!_isIOS) return false;
    final sessionId = 'web-sign-in-${++_webSignInCount}';
    _webSignIns[sessionId] = (
      allowsNavigation: allowsNavigation,
      checksPage: checksPage,
    );
    try {
      return await _api.presentWebSignIn(
        PlatformWebSignInRequest(
          sessionId: sessionId,
          title: title,
          url: url,
          checkScript: checkScript,
          checkUrl: checkUrl,
          cancelLabel: cancelLabel,
          reloadLabel: reloadLabel,
          loadFailedMessage: loadFailedMessage,
        ),
      );
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError('presentWebSignIn', error, stackTrace);
      return false;
    } finally {
      _webSignIns.remove(sessionId);
    }
  }

  @override
  Future<bool> webSignInAllowsNavigation(String sessionId, String url) async {
    // A sign-in no longer waited for loads nothing more.
    final session = _webSignIns[sessionId];
    if (session == null) return false;
    try {
      return session.allowsNavigation(url);
    } catch (error, stackTrace) {
      // Refused: a navigation that cannot be judged is not loaded.
      _logNativeSheetBridgeError(
        'webSignInAllowsNavigation',
        error,
        stackTrace,
      );
      return false;
    }
  }

  @override
  Future<bool> webSignInChecksPage(String sessionId, String url) async {
    final session = _webSignIns[sessionId];
    if (session == null) return false;
    try {
      return session.checksPage(url);
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError('webSignInChecksPage', error, stackTrace);
      return false;
    }
  }

  Future<bool> closeDetail(String detailId) async {
    if (!_isIOS) return false;
    try {
      return await _api.closeDetail(detailId);
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError(
        'closeDetail',
        error,
        stackTrace,
        data: {'detailId': detailId},
      );
      return false;
    }
  }

  @override
  void onDismissed() {
    _settingsSheetOpen = false;
    _settingsLeaving = false;
    _events.add(const NativeSheetDismissed());
  }

  @override
  void onLogoutRequested() {
    _events.add(const NativeSheetLogoutRequested());
  }

  @override
  void onControlChanged(PlatformNativeSheetControlChangedEvent event) {
    if (event.id.isEmpty) return;
    _events.add(NativeSheetControlChanged(id: event.id, value: event.value));
  }

  @override
  void onDetailAppeared(PlatformNativeSheetDetailAppearedEvent event) {
    if (event.detailId.isEmpty) return;
    _events.add(NativeSheetDetailAppeared(detailId: event.detailId));
  }

  @override
  void onDetailLeft(PlatformNativeSheetDetailAppearedEvent event) {
    if (event.detailId.isEmpty) return;
    _events.add(NativeSheetDetailLeft(detailId: event.detailId));
  }

  @override
  void onModelPinToggled(PlatformNativeSheetModelPinToggledEvent event) {
    if (event.modelId.isEmpty) return;
    unawaited(_handleModelPinToggled(event.modelId));
  }

  @override
  void onReasoningEffortChanged(
    PlatformNativeSheetReasoningEffortChangedEvent event,
  ) {
    if (event.value.isEmpty) return;
    unawaited(_handleReasoningEffortChanged(event.value));
  }

  @override
  void onModelControlChanged(
    PlatformNativeSheetModelControlChangedEvent event,
  ) {
    if (event.key.isEmpty || event.value.isEmpty) return;
    unawaited(_handleModelControlChanged(event.key, event.value));
  }

  Future<void> _handleModelControlChanged(String key, String value) async {
    try {
      await _modelControlChangedHandler?.call(key, value);
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError(
        'onModelControlChanged',
        error,
        stackTrace,
        data: {'key': key},
      );
    }
  }

  Future<void> _handleReasoningEffortChanged(String value) async {
    try {
      await _reasoningEffortChangedHandler?.call(value);
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError(
        'onReasoningEffortChanged',
        error,
        stackTrace,
        data: {'value': value},
      );
    }
  }

  Future<void> _handleModelPinToggled(String modelId) async {
    try {
      await _modelPinToggleHandler?.call(modelId);
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError(
        'onModelPinToggled',
        error,
        stackTrace,
        data: {'modelId': modelId},
      );
    }
  }

  @override
  void commitEditProfile(PlatformNativeEditProfileCommittedEvent event) {
    _events.add(
      NativeEditProfileCommitted(
        name: event.name,
        profileImageUrl: event.profileImageUrl,
        bio: event.bio,
        gender: event.gender,
        dateOfBirth: event.dateOfBirth,
      ),
    );
  }
}

class NativeProfileSheetConfig {
  const NativeProfileSheetConfig({
    required this.profile,
    required this.editProfileLabel,
    required this.menuItems,
    required this.detailSheets,
    this.profileMenuTitle,
    this.editProfileSheet,
    this.supportTitle,
    this.supportSubtitle,
    this.supportItems = const [],
    this.sections = const [],
  });

  final NativeProfileSheetUser profile;

  /// Root navigation title for the profile sheet (e.g. localized "You").
  final String? profileMenuTitle;
  final String editProfileLabel;
  final NativeEditProfileSheetConfig? editProfileSheet;
  final String? supportTitle;
  final String? supportSubtitle;
  final List<NativeSheetItemConfig> menuItems;
  final List<NativeSheetItemConfig> supportItems;
  final List<NativeSheetSectionConfig> sections;
  final List<NativeSheetDetailConfig> detailSheets;

  Map<String, Object?> toMap() {
    return {
      'profile': profile.toMap(),
      if (profileMenuTitle != null) 'profileMenuTitle': profileMenuTitle,
      'editProfileLabel': editProfileLabel,
      if (editProfileSheet != null)
        'editProfileSheet': editProfileSheet!.toMap(),
      'supportTitle': supportTitle,
      'supportSubtitle': supportSubtitle,
      'menuItems': menuItems.map((item) => item.toMap()).toList(),
      'supportItems': supportItems.map((item) => item.toMap()).toList(),
      if (sections.isNotEmpty)
        'sections': sections.map((section) => section.toMap()).toList(),
      'detailSheets': detailSheets.map((sheet) => sheet.toMap()).toList(),
    };
  }
}

class NativeSheetSectionConfig {
  const NativeSheetSectionConfig({
    required this.items,
    this.title,
    this.footer,
    this.reorderActionId,
  });

  final String? title;
  final String? footer;
  final String? reorderActionId;
  final List<NativeSheetItemConfig> items;

  Map<String, Object?> toMap() {
    return {
      'title': title,
      'footer': footer,
      if (reorderActionId != null) 'reorderActionId': reorderActionId,
      'items': items.map((item) => item.toMap()).toList(),
    };
  }
}

/// Copy for the native edit-profile overlay (UIKit).
class NativeEditProfileSheetConfig {
  const NativeEditProfileSheetConfig({
    required this.title,
    required this.saveLabel,
    required this.cancelLabel,
    required this.okLabel,
    required this.footerText,
    required this.nameLabel,
    required this.nameRequiredMessage,
    required this.customGenderRequiredMessage,
    required this.bioLabel,
    required this.bioHint,
    required this.genderLabel,
    required this.genderPreferNotToSay,
    required this.genderMale,
    required this.genderFemale,
    required this.genderCustom,
    required this.customGenderLabel,
    required this.customGenderHint,
    required this.birthDateLabel,
    required this.selectBirthDateLabel,
    required this.clearLabel,
    required this.uploadFromDeviceLabel,
    required this.useInitialsLabel,
    required this.removeAvatarLabel,
    required this.currentAvatarLabel,
  });

  final String title;
  final String saveLabel;
  final String cancelLabel;
  final String okLabel;
  final String footerText;
  final String nameLabel;
  final String nameRequiredMessage;
  final String customGenderRequiredMessage;
  final String bioLabel;
  final String bioHint;
  final String genderLabel;
  final String genderPreferNotToSay;
  final String genderMale;
  final String genderFemale;
  final String genderCustom;
  final String customGenderLabel;
  final String customGenderHint;
  final String birthDateLabel;
  final String selectBirthDateLabel;
  final String clearLabel;
  final String uploadFromDeviceLabel;
  final String useInitialsLabel;
  final String removeAvatarLabel;
  final String currentAvatarLabel;

  Map<String, Object?> toMap() {
    return {
      'title': title,
      'saveLabel': saveLabel,
      'cancelLabel': cancelLabel,
      'okLabel': okLabel,
      'footerText': footerText,
      'nameLabel': nameLabel,
      'nameRequiredMessage': nameRequiredMessage,
      'customGenderRequiredMessage': customGenderRequiredMessage,
      'bioLabel': bioLabel,
      'bioHint': bioHint,
      'genderLabel': genderLabel,
      'genderPreferNotToSay': genderPreferNotToSay,
      'genderMale': genderMale,
      'genderFemale': genderFemale,
      'genderCustom': genderCustom,
      'customGenderLabel': customGenderLabel,
      'customGenderHint': customGenderHint,
      'birthDateLabel': birthDateLabel,
      'selectBirthDateLabel': selectBirthDateLabel,
      'clearLabel': clearLabel,
      'uploadFromDeviceLabel': uploadFromDeviceLabel,
      'useInitialsLabel': useInitialsLabel,
      'removeAvatarLabel': removeAvatarLabel,
      'currentAvatarLabel': currentAvatarLabel,
    };
  }
}

class NativeProfileSheetUser {
  const NativeProfileSheetUser({
    required this.displayName,
    required this.email,
    required this.initials,
    this.avatarUrl,
    this.avatarBytes,
    this.avatarIsTemplate = false,
    this.avatarHeaders = const {},
    this.bio,
    this.gender,
    this.dateOfBirth,
    this.profileImageUrl,
  });

  final String displayName;
  final String email;
  final String initials;
  final String? avatarUrl;
  final Uint8List? avatarBytes;
  final bool avatarIsTemplate;
  final Map<String, String> avatarHeaders;

  /// Account profile fields (parity with Flutter account settings).
  final String? bio;
  final String? gender;
  final String? dateOfBirth;

  /// Persisted profile image URL from the server (used when the user does not change the avatar).
  final String? profileImageUrl;

  Map<String, Object?> toMap() {
    return {
      'displayName': displayName,
      'email': email,
      'initials': initials,
      'avatarUrl': avatarUrl,
      'avatarBytes': avatarBytes,
      'avatarIsTemplate': avatarIsTemplate,
      'avatarHeaders': avatarHeaders,
      if (bio != null) 'bio': bio,
      if (gender != null) 'gender': gender,
      if (dateOfBirth != null) 'dateOfBirth': dateOfBirth,
      if (profileImageUrl != null) 'profileImageUrl': profileImageUrl,
    };
  }
}

class NativeSheetDetailConfig {
  const NativeSheetDetailConfig({
    required this.id,
    required this.title,
    this.items = const [],
    this.sections = const [],
    this.subtitle,
    this.confirmActionId,
    this.confirmActionLabel,

    /// When set (0–1), iOS uses a single sheet detent at this fraction of the
    /// maximum sheet height (matches capped Material bottom sheets). Ignored
    /// on non-iOS.
    this.maxHeightFraction,
    this.trailingActionId,
    this.trailingActionSfSymbol,
    this.discardPrompt,
    this.busy = false,
    this.announcement,
    this.edited = false,
  }) : assert(
         items.length == 0 || sections.length == 0,
         'A native detail must use either items or sections, not both.',
       );

  final String id;
  final String title;
  final String? subtitle;
  final List<NativeSheetItemConfig> items;
  final List<NativeSheetSectionConfig> sections;
  final String? confirmActionId;
  final String? confirmActionLabel;

  /// Portion of the largest allowable sheet height (typically ~full screen).
  final double? maxHeightFraction;

  /// A bar button, drawn as [trailingActionSfSymbol], that closes the sheet
  /// and then sends this action.
  final String? trailingActionId;
  final String? trailingActionSfSymbol;

  /// What the page asks before its unsaved changes are dropped -- by Back,
  /// a swipe back, or the sheet swiped away. Null drops them without asking.
  /// Changes are text not yet done, or, on a page with a confirm action,
  /// anything changed since it appeared.
  final NativeSheetDiscardPrompt? discardPrompt;

  /// Working on what Done sent: Done waits, and the rows take no taps.
  final bool busy;

  /// Read out by assistive technology as the page is described with it: an
  /// action's outcome, shown on the page as well.
  final String? announcement;

  /// Holds changes not yet saved, made on this page or on the pages it
  /// leads to, as the page's owner counts them: leaving asks
  /// [discardPrompt] whatever was changed here since it appeared.
  final bool edited;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'title': title,
      'subtitle': subtitle,
      'items': items.map((item) => item.toMap()).toList(),
      if (sections.isNotEmpty)
        'sections': sections.map((section) => section.toMap()).toList(),
      if (confirmActionId != null) 'confirmActionId': confirmActionId,
      if (confirmActionLabel != null) 'confirmActionLabel': confirmActionLabel,
      if (maxHeightFraction != null) 'maxHeightFraction': maxHeightFraction,
      if (trailingActionId != null) 'trailingActionId': trailingActionId,
      if (trailingActionSfSymbol != null)
        'trailingActionSfSymbol': trailingActionSfSymbol,
      if (discardPrompt case final prompt?) ...{
        'discardTitle': prompt.title,
        'discardMessage': prompt.message,
        'discardConfirmLabel': prompt.discardLabel,
        'discardCancelLabel': prompt.keepLabel,
      },
      if (busy) 'busy': busy,
      if (announcement != null) 'announcement': announcement,
      if (edited) 'edited': edited,
    };
  }
}

/// How an answer to a question over Settings is drawn.
enum NativeSheetAlertStyle {
  /// An ordinary answer.
  normal,

  /// The answer that leaves things as they are.
  cancel,

  /// An answer that loses something.
  destructive;

  /// The name the native side reads.
  String get platformName => switch (this) {
    normal => 'default',
    cancel => 'cancel',
    destructive => 'destructive',
  };
}

/// One answer to a question asked over Settings.
@immutable
class NativeSheetAlertAction {
  const NativeSheetAlertAction(
    this.id,
    this.label, {
    this.style = NativeSheetAlertStyle.normal,
  });

  final String id;
  final String label;
  final NativeSheetAlertStyle style;
}

/// The question a page asks before its unsaved changes are dropped.
@immutable
class NativeSheetDiscardPrompt {
  const NativeSheetDiscardPrompt({
    required this.title,
    required this.message,
    required this.discardLabel,
    required this.keepLabel,
  });

  final String title;
  final String message;
  final String discardLabel;
  final String keepLabel;
}

class NativeSheetLinkConfig {
  const NativeSheetLinkConfig({required this.url, this.title, this.faviconUrl});

  final String url;
  final String? title;
  final String? faviconUrl;

  Map<String, Object?> toMap() {
    return {'url': url, 'title': title, 'faviconUrl': faviconUrl};
  }
}

class NativeSheetItemConfig {
  const NativeSheetItemConfig({
    required this.id,
    required this.title,
    this.subtitle,
    this.sfSymbol = 'circle',
    this.iconAsset,
    this.iconSize,
    this.showsDisclosure,
    this.destructive = false,
    this.dismissOnSelect = false,
    this.actionId,
    this.actionValue,
    this.url,
    this.kind = NativeSheetItemKind.navigation,
    this.value,
    this.placeholder,
    this.options = const [],
    this.sourceIndex,
    this.sourceUrl,
    this.sourceType,
    this.snippet,
    this.faviconUrl,
    this.queries = const <String>[],
    this.links = const <NativeSheetLinkConfig>[],
    this.pending,
    this.min,
    this.max,
    this.divisions,
    this.avatarName,
    this.avatarBytes,
    this.checked = false,
    this.accent = false,
    this.usesProfileAvatar = false,
    this.filterAllLabel,
    this.confirmMessage,
    this.disabled = false,
    this.keyboard,
    this.passwordRole,
    this.rowActions = const [],
  });

  final String id;
  final String title;
  final String? subtitle;
  final String sfSymbol;
  final String? iconAsset;
  final double? iconSize;
  final bool? showsDisclosure;
  final bool destructive;
  final bool dismissOnSelect;
  final String? actionId;
  final Object? actionValue;
  final String? url;
  final NativeSheetItemKind kind;
  final Object? value;
  final String? placeholder;
  final List<NativeSheetOptionConfig> options;
  final int? sourceIndex;
  final String? sourceUrl;
  final String? sourceType;
  final String? snippet;
  final String? faviconUrl;
  final List<String> queries;
  final List<NativeSheetLinkConfig> links;
  final bool? pending;

  /// Inclusive bounds for [NativeSheetItemKind.slider] (e.g. STT silence ms, TTS rate).
  final double? min;
  final double? max;

  /// Optional discrete steps for `UISlider` (`0` = continuous).
  final int? divisions;

  /// Shown as a round picture -- [avatarBytes], else this name's initials --
  /// in place of [sfSymbol].
  final String? avatarName;
  final Uint8List? avatarBytes;

  /// Marks the row in use with a check.
  final bool checked;

  /// Draws the row in the accent color, as an action.
  final bool accent;

  /// Draws the row as the sheet's profile summary: its large avatar beside
  /// this row's own title and subtitle.
  final bool usesProfileAvatar;

  /// Enables the picker filter pill; this is its unfiltered label.
  final String? filterAllLabel;

  /// Asked before the row acts, with the row's title as the answer that
  /// goes ahead: Delete, Sign Out. Null acts at once.
  final String? confirmMessage;

  /// Shown dimmed, taking no taps: while another row's action runs, say.
  final bool disabled;

  /// The keyboard a text row brings up; null keeps the default.
  final NativeSheetKeyboard? keyboard;

  /// What a secure row holds when it is the account's own password. Null,
  /// for any other secret, keeps the system from offering to save it as a
  /// password.
  final NativeSheetPasswordRole? passwordRole;

  /// What else the row can do, besides what a tap does. On iOS a long press
  /// lists them, and a swipe offers them where the page is not reordering;
  /// the Flutter pages list them in the row's menu. Each is sent as its own
  /// control id.
  final List<NativeSheetRowAction> rowActions;

  Map<String, Object?> toMap() {
    return {
      if (filterAllLabel != null) 'filterAllLabel': filterAllLabel,
      if (confirmMessage != null) 'confirmMessage': confirmMessage,
      if (disabled) 'disabled': disabled,
      if (keyboard != null) 'keyboard': keyboard!.name,
      if (passwordRole != null) 'passwordRole': passwordRole!.name,
      if (rowActions.isNotEmpty)
        'rowActions': [for (final action in rowActions) action.toMap()],
      'id': id,
      'title': title,
      'subtitle': subtitle,
      'sfSymbol': sfSymbol,
      if (iconAsset != null) 'iconAsset': iconAsset,
      if (iconSize != null) 'iconSize': iconSize,
      if (showsDisclosure != null) 'showsDisclosure': showsDisclosure,
      'destructive': destructive,
      'dismissOnSelect': dismissOnSelect,
      if (actionId != null) 'actionId': actionId,
      if (actionValue != null) 'actionValue': actionValue,
      'url': url,
      'kind': kind.name,
      'value': value,
      'placeholder': placeholder,
      'options': options.map((option) => option.toMap()).toList(),
      if (sourceIndex != null) 'sourceIndex': sourceIndex,
      if (sourceUrl != null) 'sourceUrl': sourceUrl,
      if (sourceType != null) 'sourceType': sourceType,
      if (snippet != null) 'snippet': snippet,
      if (faviconUrl != null) 'faviconUrl': faviconUrl,
      if (queries.isNotEmpty) 'queries': queries,
      if (links.isNotEmpty) 'links': links.map((link) => link.toMap()).toList(),
      if (pending != null) 'pending': pending,
      if (min != null) 'min': min,
      if (max != null) 'max': max,
      if (divisions != null) 'divisions': divisions,
      if (avatarName != null) 'avatarName': avatarName,
      if (avatarBytes != null) 'avatarBytes': avatarBytes,
      if (checked) 'checked': checked,
      if (accent) 'accent': accent,
      if (usesProfileAvatar) 'usesProfileAvatar': usesProfileAvatar,
    };
  }
}

/// The keyboard a text row brings up.
enum NativeSheetKeyboard { url, email, number }

/// Which of the account's passwords a secure row holds: the one in use, or
/// one being set.
enum NativeSheetPasswordRole { current, newPassword }

/// One more thing a row can do, sent as its own control id.
@immutable
class NativeSheetRowAction {
  const NativeSheetRowAction({
    required this.id,
    required this.label,
    this.sfSymbol,
    this.destructive = false,
    this.confirmMessage,
  });

  final String id;
  final String label;
  final String? sfSymbol;
  final bool destructive;

  /// Asked before it acts, with [label] as the answer that goes ahead.
  final String? confirmMessage;

  Map<String, Object?> toMap() => {
    'id': id,
    'label': label,
    if (sfSymbol != null) 'sfSymbol': sfSymbol,
    'destructive': destructive,
    if (confirmMessage != null) 'confirmMessage': confirmMessage,
  };

  PlatformNativeSheetRowAction toPlatform() => PlatformNativeSheetRowAction(
    id: id,
    label: label,
    sfSymbol: sfSymbol,
    destructive: destructive,
    confirmMessage: confirmMessage,
  );
}

enum NativeSheetItemKind {
  navigation,
  textField,
  multilineTextField,
  secureTextField,
  dropdown,
  searchablePicker,
  toggle,

  /// One of a few values. On iOS a one-line row whose value at the trailing
  /// edge opens a menu, as a Settings form's menu picker does; the
  /// subtitle, if any, runs under the title.
  segment,
  slider,
  info,
  readOnlyText,
  source,
  statusUpdate,

  /// Preview tiles for a few looks (System, Light, Dark), each painted from
  /// its option's swatches, with a label and a selection mark under it.
  appearanceTiles,
}

class NativeSheetOptionConfig {
  const NativeSheetOptionConfig({
    required this.id,
    required this.label,
    this.subtitle,
    this.sfSymbol,
    this.enabled = true,
    this.destructive = false,
    this.ancestorHasMoreSiblings = const <bool>[],
    this.showBranch = false,
    this.hasMoreSiblings = false,
    this.filterGroup,
    this.swatches,
    this.darkSwatches,
  });

  final String id;
  final String label;
  final String? subtitle;
  final String? sfSymbol;

  /// Colours (ARGB) that preview the option, such as a palette's, shown as
  /// small discs beside its label in light appearance; [darkSwatches] in
  /// dark. Null for an ordinary option.
  final List<int>? swatches;
  final List<int>? darkSwatches;
  final bool enabled;
  final bool destructive;
  final List<bool> ancestorHasMoreSiblings;
  final bool showBranch;
  final bool hasMoreSiblings;

  /// Label in the picker filter menu. Empty keeps an option in every group.
  final String? filterGroup;

  Map<String, Object?> toMap() {
    return {
      if (filterGroup != null) 'filterGroup': filterGroup,
      'id': id,
      'label': label,
      'subtitle': subtitle,
      'sfSymbol': sfSymbol,
      'enabled': enabled,
      'destructive': destructive,
      'ancestorHasMoreSiblings': ancestorHasMoreSiblings,
      'showBranch': showBranch,
      'hasMoreSiblings': hasMoreSiblings,
      if (swatches != null) 'swatches': swatches,
      if (darkSwatches != null) 'darkSwatches': darkSwatches,
    };
  }
}

class NativeSheetModelOption {
  const NativeSheetModelOption({
    required this.id,
    required this.name,
    this.subtitle,
    this.sfSymbol,
    this.avatarUrl,
    this.avatarBytes,
    this.avatarHeaders = const <String, String>{},
    this.tags = const <String>[],
  });

  final String id;
  final String name;
  final String? subtitle;
  final String? sfSymbol;
  final String? avatarUrl;
  final Uint8List? avatarBytes;
  final Map<String, String> avatarHeaders;
  final List<String> tags;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'subtitle': subtitle,
      'sfSymbol': sfSymbol,
      'avatarUrl': avatarUrl,
      'avatarBytes': avatarBytes,
      'avatarHeaders': avatarHeaders,
      'tags': tags,
    };
  }
}

sealed class NativeSheetEvent {
  const NativeSheetEvent();
}

final class NativeSheetDismissed extends NativeSheetEvent {
  const NativeSheetDismissed();
}

final class NativeSheetLogoutRequested extends NativeSheetEvent {
  const NativeSheetLogoutRequested();
}

final class NativeSheetControlChanged extends NativeSheetEvent {
  const NativeSheetControlChanged({required this.id, required this.value});

  final String id;
  final Object? value;
}

/// A native detail screen became visible (push). Used to lazy-load heavy payloads.
final class NativeSheetDetailAppeared extends NativeSheetEvent {
  const NativeSheetDetailAppeared({required this.detailId});

  final String detailId;
}

/// A page is gone: popped, or its sheet closed. A page covered by one it
/// opened has not left.
final class NativeSheetDetailLeft extends NativeSheetEvent {
  const NativeSheetDetailLeft({required this.detailId});

  final String detailId;
}

/// Single atomic save from the native edit-profile overlay.
final class NativeEditProfileCommitted extends NativeSheetEvent {
  const NativeEditProfileCommitted({
    required this.name,
    required this.profileImageUrl,
    required this.bio,
    this.gender,
    this.dateOfBirth,
  });

  final String name;
  final String profileImageUrl;
  final String bio;
  final String? gender;
  final String? dateOfBirth;

  static NativeEditProfileCommitted? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'] as String?;
    final profileImageUrl = raw['profileImageUrl'] as String?;
    if (name == null || profileImageUrl == null) return null;
    final genderRaw = raw['gender'];
    final dobRaw = raw['dateOfBirth'];
    return NativeEditProfileCommitted(
      name: name,
      profileImageUrl: profileImageUrl,
      bio: raw['bio'] as String? ?? '',
      gender: genderRaw is String ? genderRaw : null,
      dateOfBirth: dobRaw is String ? dobRaw : null,
    );
  }
}

final class NativeSheetActionResult {
  const NativeSheetActionResult({
    required this.actionId,
    this.values = const {},
  });

  final String actionId;
  final Map<String, Object?> values;

  static NativeSheetActionResult? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final actionId = raw['actionId'] as String?;
    if (actionId == null || actionId.isEmpty) return null;
    final parsedValues = <String, Object?>{};
    final values = raw['values'];
    if (values is Map) {
      for (final entry in values.entries) {
        final key = entry.key;
        if (key is String) {
          parsedValues[key] = entry.value;
        }
      }
    }
    return NativeSheetActionResult(actionId: actionId, values: parsedValues);
  }

  static NativeSheetActionResult fromPlatform(
    PlatformNativeSheetActionResult raw,
  ) {
    return NativeSheetActionResult(actionId: raw.actionId, values: raw.values);
  }
}

extension on NativeProfileSheetConfig {
  PlatformNativeProfileSheetConfig toPlatform() {
    return PlatformNativeProfileSheetConfig(
      profile: profile.toPlatform(),
      profileMenuTitle: profileMenuTitle,
      editProfileLabel: editProfileLabel,
      editProfileSheet: editProfileSheet?.toPlatform(),
      supportTitle: supportTitle,
      supportSubtitle: supportSubtitle,
      menuItems: menuItems.map((item) => item.toPlatform()).toList(),
      supportItems: supportItems.map((item) => item.toPlatform()).toList(),
      sections: sections.map((section) => section.toPlatform()).toList(),
      detailSheets: detailSheets.map((sheet) => sheet.toPlatform()).toList(),
    );
  }
}

extension on NativeSheetSectionConfig {
  PlatformNativeSheetSection toPlatform() {
    return PlatformNativeSheetSection(
      title: title,
      footer: footer,
      reorderActionId: reorderActionId,
      items: items.map((item) => item.toPlatform()).toList(),
    );
  }
}

extension on NativeEditProfileSheetConfig {
  PlatformNativeEditProfileSheetConfig toPlatform() {
    return PlatformNativeEditProfileSheetConfig(
      title: title,
      saveLabel: saveLabel,
      cancelLabel: cancelLabel,
      okLabel: okLabel,
      footerText: footerText,
      nameLabel: nameLabel,
      nameRequiredMessage: nameRequiredMessage,
      customGenderRequiredMessage: customGenderRequiredMessage,
      bioLabel: bioLabel,
      bioHint: bioHint,
      genderLabel: genderLabel,
      genderPreferNotToSay: genderPreferNotToSay,
      genderMale: genderMale,
      genderFemale: genderFemale,
      genderCustom: genderCustom,
      customGenderLabel: customGenderLabel,
      customGenderHint: customGenderHint,
      birthDateLabel: birthDateLabel,
      selectBirthDateLabel: selectBirthDateLabel,
      clearLabel: clearLabel,
      uploadFromDeviceLabel: uploadFromDeviceLabel,
      useInitialsLabel: useInitialsLabel,
      removeAvatarLabel: removeAvatarLabel,
      currentAvatarLabel: currentAvatarLabel,
    );
  }
}

extension on NativeProfileSheetUser {
  PlatformNativeProfileSheetUser toPlatform() {
    return PlatformNativeProfileSheetUser(
      displayName: displayName,
      email: email,
      initials: initials,
      avatarUrl: avatarUrl,
      avatarBytes: avatarBytes,
      avatarIsTemplate: avatarIsTemplate,
      avatarHeaders: avatarHeaders,
      bio: bio,
      gender: gender,
      dateOfBirth: dateOfBirth,
      profileImageUrl: profileImageUrl,
    );
  }
}

extension on NativeSheetDetailConfig {
  PlatformNativeSheetDetail toPlatform() {
    return PlatformNativeSheetDetail(
      id: id,
      title: title,
      subtitle: subtitle,
      items: items.map((item) => item.toPlatform()).toList(),
      sections: sections.map((section) => section.toPlatform()).toList(),
      confirmActionId: confirmActionId,
      confirmActionLabel: confirmActionLabel,
      maxHeightFraction: maxHeightFraction,
      trailingActionId: trailingActionId,
      trailingActionSfSymbol: trailingActionSfSymbol,
      discardTitle: discardPrompt?.title,
      discardMessage: discardPrompt?.message,
      discardConfirmLabel: discardPrompt?.discardLabel,
      discardCancelLabel: discardPrompt?.keepLabel,
      busy: busy ? true : null,
      announcement: announcement,
      edited: edited ? true : null,
    );
  }
}

extension on NativeSheetLinkConfig {
  PlatformNativeSheetLink toPlatform() {
    return PlatformNativeSheetLink(
      url: url,
      title: title,
      faviconUrl: faviconUrl,
    );
  }
}

extension on NativeSheetItemConfig {
  PlatformNativeSheetItem toPlatform() {
    return PlatformNativeSheetItem(
      id: id,
      title: title,
      subtitle: subtitle,
      sfSymbol: sfSymbol,
      iconAsset: iconAsset,
      iconSize: iconSize,
      showsDisclosure: showsDisclosure,
      destructive: destructive,
      dismissOnSelect: dismissOnSelect,
      actionId: actionId,
      actionValue: actionValue,
      url: url,
      kind: kind.toPlatform(),
      value: value,
      placeholder: placeholder,
      options: options.map((option) => option.toPlatform()).toList(),
      sourceIndex: sourceIndex,
      sourceUrl: sourceUrl,
      sourceType: sourceType,
      snippet: snippet,
      faviconUrl: faviconUrl,
      queries: queries,
      links: links.map((link) => link.toPlatform()).toList(),
      pending: pending ?? false,
      min: min,
      max: max,
      divisions: divisions,
      avatarName: avatarName,
      avatarBytes: avatarBytes,
      checked: checked,
      accent: accent,
      usesProfileAvatar: usesProfileAvatar,
      filterAllLabel: filterAllLabel,
      confirmMessage: confirmMessage,
      disabled: disabled ? true : null,
      keyboard: keyboard?.name,
      passwordRole: passwordRole?.name,
      rowActions: rowActions.isEmpty
          ? null
          : [for (final action in rowActions) action.toPlatform()],
    );
  }
}

extension on NativeSheetItemKind {
  PlatformNativeSheetItemKind toPlatform() {
    return switch (this) {
      NativeSheetItemKind.navigation => PlatformNativeSheetItemKind.navigation,
      NativeSheetItemKind.textField => PlatformNativeSheetItemKind.textField,
      NativeSheetItemKind.multilineTextField =>
        PlatformNativeSheetItemKind.multilineTextField,
      NativeSheetItemKind.secureTextField =>
        PlatformNativeSheetItemKind.secureTextField,
      NativeSheetItemKind.dropdown => PlatformNativeSheetItemKind.dropdown,
      NativeSheetItemKind.searchablePicker =>
        PlatformNativeSheetItemKind.searchablePicker,
      NativeSheetItemKind.toggle => PlatformNativeSheetItemKind.toggle,
      NativeSheetItemKind.segment => PlatformNativeSheetItemKind.segment,
      NativeSheetItemKind.slider => PlatformNativeSheetItemKind.slider,
      NativeSheetItemKind.info => PlatformNativeSheetItemKind.info,
      NativeSheetItemKind.readOnlyText =>
        PlatformNativeSheetItemKind.readOnlyText,
      NativeSheetItemKind.source => PlatformNativeSheetItemKind.source,
      NativeSheetItemKind.statusUpdate =>
        PlatformNativeSheetItemKind.statusUpdate,
      NativeSheetItemKind.appearanceTiles =>
        PlatformNativeSheetItemKind.appearanceTiles,
    };
  }
}

extension on NativeSheetOptionConfig {
  PlatformNativeSheetOption toPlatform() {
    return PlatformNativeSheetOption(
      id: id,
      label: label,
      subtitle: subtitle,
      sfSymbol: sfSymbol,
      enabled: enabled,
      destructive: destructive,
      ancestorHasMoreSiblings: ancestorHasMoreSiblings,
      showBranch: showBranch,
      hasMoreSiblings: hasMoreSiblings,
      filterGroup: filterGroup,
      swatchesArgb: swatches,
      darkSwatchesArgb: darkSwatches,
    );
  }
}

extension on NativeSheetModelOption {
  PlatformNativeSheetModelOption toPlatform() {
    return PlatformNativeSheetModelOption(
      id: id,
      name: name,
      subtitle: subtitle,
      sfSymbol: sfSymbol,
      avatarUrl: avatarUrl,
      avatarBytes: avatarBytes,
      avatarHeaders: avatarHeaders,
      tags: tags,
    );
  }
}
