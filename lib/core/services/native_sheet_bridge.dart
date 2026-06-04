import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/conduit_platform_apis.g.dart';
import '../utils/debug_logger.dart';

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
  static const aiMemory = 'ai-memory';
  static const dataConnection = 'data-connection';
  static const helpAbout = 'help-about';
  static const about = 'about';
}

class NativeSheetBridge implements NativeSheetFlutterApi {
  NativeSheetBridge._() {
    NativeSheetFlutterApi.setUp(this);
  }

  static final NativeSheetBridge instance = NativeSheetBridge._();

  final NativeSheetHostApi _api = NativeSheetHostApi();
  final StreamController<NativeSheetEvent> _events =
      StreamController<NativeSheetEvent>.broadcast();
  Future<void> Function(String modelId)? _modelPinToggleHandler;
  Object? _modelPinToggleHandlerOwner;

  @visibleForTesting
  bool? debugIsIOSOverride;

  Stream<NativeSheetEvent> get events => _events.stream;

  bool get _isIOS => debugIsIOSOverride ?? Platform.isIOS;

  Future<bool> presentProfileMenu(NativeProfileSheetConfig config) async {
    if (!_isIOS) return false;
    try {
      return await _api.presentProfileMenu(config.toPlatform());
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

  Future<String?> presentModelSelector({
    required String title,
    required List<NativeSheetModelOption> models,
    String? selectedModelId,
    List<String> pinnedModelIds = const <String>[],
    String? pinTitle,
    String? unpinTitle,
    Future<void> Function(String modelId)? onTogglePinned,
    bool rethrowErrors = false,
  }) async {
    if (!_isIOS || models.isEmpty) return null;
    final previousPinToggleHandler = _modelPinToggleHandler;
    final previousPinToggleHandlerOwner = _modelPinToggleHandlerOwner;
    final pinToggleHandlerOwner = Object();
    var shouldClearPinToggleHandler = false;
    _modelPinToggleHandler = onTogglePinned;
    _modelPinToggleHandlerOwner = pinToggleHandlerOwner;
    try {
      final result = await _api.presentModelSelector(
        PlatformNativeSheetModelSelectorRequest(
          title: title,
          selectedModelId: selectedModelId,
          models: models.map((model) => model.toPlatform()).toList(),
          pinnedModelIds: pinnedModelIds,
          allowsPinning: onTogglePinned != null,
          pinTitle: pinTitle,
          unpinTitle: unpinTitle,
        ),
      );
      shouldClearPinToggleHandler = true;
      if (result != null) {
        return result;
      }
      return null;
    } on PlatformException catch (error, stackTrace) {
      if (!shouldClearPinToggleHandler) {
        _restorePreviousModelPinToggleHandler(
          owner: pinToggleHandlerOwner,
          previousHandler: previousPinToggleHandler,
          previousOwner: previousPinToggleHandlerOwner,
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
        _restorePreviousModelPinToggleHandler(
          owner: pinToggleHandlerOwner,
          previousHandler: previousPinToggleHandler,
          previousOwner: previousPinToggleHandlerOwner,
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
          identical(_modelPinToggleHandlerOwner, pinToggleHandlerOwner)) {
        _modelPinToggleHandler = null;
        _modelPinToggleHandlerOwner = null;
      }
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

  Future<String?> presentOptionsSelector({
    required String title,
    required List<NativeSheetOptionConfig> options,
    String? subtitle,
    String? selectedOptionId,
    bool searchable = true,
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
  Future<bool> applyDetailPatch({
    required String detailId,
    required List<NativeSheetItemConfig> items,
    String? title,
    String? subtitle,
    List<NativeSheetDetailConfig> detailSheets = const [],
  }) async {
    if (!_isIOS) return false;
    try {
      return await _api.applyDetailPatch(
        PlatformNativeSheetApplyDetailPatchRequest(
          detailId: detailId,
          items: items.map((item) => item.toPlatform()).toList(),
          title: title,
          subtitle: subtitle,
          detailSheets: detailSheets.isEmpty
              ? null
              : detailSheets.map((detail) => detail.toPlatform()).toList(),
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

  @override
  void onDismissed() {
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
  void onModelPinToggled(PlatformNativeSheetModelPinToggledEvent event) {
    if (event.modelId.isEmpty) return;
    unawaited(_handleModelPinToggled(event.modelId));
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
  });

  final String? title;
  final String? footer;
  final List<NativeSheetItemConfig> items;

  Map<String, Object?> toMap() {
    return {
      'title': title,
      'footer': footer,
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
  });

  final String id;
  final String title;
  final String? subtitle;
  final List<NativeSheetItemConfig> items;
  final List<NativeSheetSectionConfig> sections;
  final String? confirmActionId;
  final String? confirmActionLabel;

  /// Portion of the largest allowable sheet height (typically ~full screen).
  final double? maxHeightFraction;

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
    };
  }
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
    this.destructive = false,
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
  });

  final String id;
  final String title;
  final String? subtitle;
  final String sfSymbol;
  final bool destructive;
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

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'title': title,
      'subtitle': subtitle,
      'sfSymbol': sfSymbol,
      'destructive': destructive,
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
    };
  }
}

enum NativeSheetItemKind {
  navigation,
  textField,
  multilineTextField,
  secureTextField,
  dropdown,
  searchablePicker,
  toggle,
  segment,
  slider,
  info,
  readOnlyText,
  source,
  statusUpdate,
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
  });

  final String id;
  final String label;
  final String? subtitle;
  final String? sfSymbol;
  final bool enabled;
  final bool destructive;
  final List<bool> ancestorHasMoreSiblings;
  final bool showBranch;
  final bool hasMoreSiblings;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'label': label,
      'subtitle': subtitle,
      'sfSymbol': sfSymbol,
      'enabled': enabled,
      'destructive': destructive,
      'ancestorHasMoreSiblings': ancestorHasMoreSiblings,
      'showBranch': showBranch,
      'hasMoreSiblings': hasMoreSiblings,
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
    this.avatarHeaders = const <String, String>{},
  });

  final String id;
  final String name;
  final String? subtitle;
  final String? sfSymbol;
  final String? avatarUrl;
  final Map<String, String> avatarHeaders;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'subtitle': subtitle,
      'sfSymbol': sfSymbol,
      'avatarUrl': avatarUrl,
      'avatarHeaders': avatarHeaders,
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
      destructive: destructive,
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
      avatarHeaders: avatarHeaders,
    );
  }
}
