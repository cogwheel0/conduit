import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../utils/debug_logger.dart';

const _nativeSheetChannel = MethodChannel('conduit/native_sheet');

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
  static const accountSettings = 'account-settings';
  static const personalization = 'personalization';
  static const audioSettings = 'audio-settings';
  static const appCustomization = 'app-customization';
  static const about = 'about';
}

class NativeSheetBridge {
  NativeSheetBridge._() {
    _nativeSheetChannel.setMethodCallHandler(_handleMethodCall);
  }

  static final NativeSheetBridge instance = NativeSheetBridge._();

  final StreamController<NativeSheetEvent> _events =
      StreamController<NativeSheetEvent>.broadcast();

  Stream<NativeSheetEvent> get events => _events.stream;

  Future<bool> presentProfileMenu(NativeProfileSheetConfig config) async {
    if (!Platform.isIOS) return false;
    try {
      return await _nativeSheetChannel.invokeMethod<bool>(
            'presentProfileMenu',
            config.toMap(),
          ) ??
          false;
    } on PlatformException catch (error, stackTrace) {
      _logNativeSheetBridgeError('presentProfileMenu', error, stackTrace);
      return false;
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError('presentProfileMenu', error, stackTrace);
      return false;
    }
  }

  Future<bool> dismiss() async {
    if (!Platform.isIOS) return false;
    try {
      return await _nativeSheetChannel.invokeMethod<bool>('dismiss') ?? false;
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
    bool rethrowErrors = false,
  }) async {
    if (!Platform.isIOS || models.isEmpty) return null;
    try {
      return await _nativeSheetChannel
          .invokeMethod<String>('presentModelSelector', {
            'title': title,
            'selectedModelId': selectedModelId,
            'models': models.map((model) => model.toMap()).toList(),
          });
    } on PlatformException catch (error, stackTrace) {
      _logNativeSheetBridgeError(
        'presentModelSelector',
        error,
        stackTrace,
        data: {'modelCount': models.length},
      );
      if (rethrowErrors) rethrow;
      return null;
    } catch (error, stackTrace) {
      _logNativeSheetBridgeError(
        'presentModelSelector',
        error,
        stackTrace,
        data: {'modelCount': models.length},
      );
      if (rethrowErrors) rethrow;
      return null;
    }
  }

  Future<String?> presentOptionsSelector({
    required String title,
    required List<NativeSheetOptionConfig> options,
    String? subtitle,
    String? selectedOptionId,
    bool searchable = true,
    bool rethrowErrors = false,
  }) async {
    if (!Platform.isIOS || options.isEmpty) return null;
    try {
      return await _nativeSheetChannel
          .invokeMethod<String>('presentOptionsSelector', {
            'title': title,
            'subtitle': subtitle,
            'selectedOptionId': selectedOptionId,
            'searchable': searchable,
            'options': options.map((option) => option.toMap()).toList(),
          });
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
    if (!Platform.isIOS) return null;
    try {
      final raw = await _nativeSheetChannel
          .invokeMethod<String>('presentDatePicker', {
            'title': title,
            'initialDate': initialDate.toIso8601String(),
            'firstDate': firstDate.toIso8601String(),
            'lastDate': lastDate.toIso8601String(),
            'doneLabel': doneLabel,
            'cancelLabel': cancelLabel,
          });
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

  Future<NativeSheetActionResult?> presentSheet({
    required NativeSheetDetailConfig root,
    List<NativeSheetDetailConfig> detailSheets = const [],
    bool rethrowErrors = false,
  }) async {
    if (!Platform.isIOS) return null;
    try {
      final raw = await _nativeSheetChannel.invokeMethod<Object>(
        'presentResultSheet',
        {
          'root': root.toMap(),
          'detailSheets': detailSheets.map((detail) => detail.toMap()).toList(),
        },
      );
      return NativeSheetActionResult.tryParse(raw);
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
    if (!Platform.isIOS) return false;
    try {
      final payload = <String, Object?>{
        'detailId': detailId,
        'items': items.map((item) => item.toMap()).toList(),
      };
      if (title != null) payload['title'] = title;
      if (subtitle != null) payload['subtitle'] = subtitle;
      if (detailSheets.isNotEmpty) {
        payload['detailSheets'] = detailSheets
            .map((detail) => detail.toMap())
            .toList();
      }
      return await _nativeSheetChannel.invokeMethod<bool>(
            'applyDetailPatch',
            payload,
          ) ??
          false;
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

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onDismissed':
        _events.add(const NativeSheetDismissed());
        break;
      case 'onLogoutRequested':
        _events.add(const NativeSheetLogoutRequested());
        break;
      case 'onControlChanged':
        final args = call.arguments;
        if (args is Map) {
          final id = args['id'] as String?;
          if (id == null || id.isEmpty) return;
          _events.add(NativeSheetControlChanged(id: id, value: args['value']));
        }
        break;
      case 'onDetailAppeared':
        final args = call.arguments;
        if (args is Map) {
          final id = args['detailId'] as String?;
          if (id == null || id.isEmpty) return;
          _events.add(NativeSheetDetailAppeared(detailId: id));
        }
        break;
      case 'commitEditProfile':
        final args = call.arguments;
        if (args is Map) {
          final parsed = NativeEditProfileCommitted.tryParse(args);
          if (parsed != null) {
            _events.add(parsed);
          }
        }
        break;
      default:
        break;
    }
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
      'detailSheets': detailSheets.map((sheet) => sheet.toMap()).toList(),
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
    required this.items,
    this.subtitle,
    this.confirmActionId,
    this.confirmActionLabel,
  });

  final String id;
  final String title;
  final String? subtitle;
  final List<NativeSheetItemConfig> items;
  final String? confirmActionId;
  final String? confirmActionLabel;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'title': title,
      'subtitle': subtitle,
      'items': items.map((item) => item.toMap()).toList(),
      if (confirmActionId != null) 'confirmActionId': confirmActionId,
      if (confirmActionLabel != null) 'confirmActionLabel': confirmActionLabel,
    };
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
}
