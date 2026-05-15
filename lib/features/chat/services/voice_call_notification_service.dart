import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../../core/utils/current_localizations.dart';

/// Service to manage persistent notifications for voice calls
class VoiceCallNotificationService {
  static final VoiceCallNotificationService _instance =
      VoiceCallNotificationService._internal();
  factory VoiceCallNotificationService() => _instance;
  VoiceCallNotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  // Notification IDs and channels
  static const String _channelId = 'voice_call_channel';
  static const int _notificationId = 2001;

  // Action IDs
  static const String _actionMute = 'mute_call';
  static const String _actionUnmute = 'unmute_call';
  static const String _actionEndCall = 'end_call';

  // Callback for handling notification actions
  void Function(String action)? onActionPressed;

  Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
      onDidReceiveBackgroundNotificationResponse:
          _handleBackgroundNotificationResponse,
    );

    // Create notification channel for Android
    if (Platform.isAndroid) {
      await _createAndroidNotificationChannel();
    }

    _initialized = true;
  }

  Future<void> _createAndroidNotificationChannel() async {
    final l10n = currentAppLocalizations();
    final androidChannel = AndroidNotificationChannel(
      _channelId,
      l10n.voiceCallTitle,
      description: l10n.voiceCallChannelDescription,
      importance: Importance.high,
      playSound: false,
      enableVibration: false,
      showBadge: false,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(androidChannel);
  }

  void _handleNotificationResponse(NotificationResponse response) {
    final action = response.actionId;
    if (action != null && onActionPressed != null) {
      onActionPressed!(action);
    }
  }

  @pragma('vm:entry-point')
  static void _handleBackgroundNotificationResponse(
    NotificationResponse response,
  ) {
    // Background action handling
    // Note: This runs in an isolate, so we can't directly call instance methods
    // Actions will be handled when app returns to foreground
  }

  /// Show ongoing voice call notification
  Future<void> showCallNotification({
    required String modelName,
    required bool isMuted,
    required bool isSpeaking,
    required bool isPaused,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    final l10n = currentAppLocalizations();
    final status = isSpeaking
        ? l10n.voiceCallSpeaking
        : isMuted
        ? l10n.voiceCallMuted
        : isPaused
        ? l10n.voiceCallPaused
        : l10n.voiceStatusListening;
    final muteAction = isMuted ? l10n.unmute : l10n.mute;
    final muteActionId = isMuted ? _actionUnmute : _actionMute;

    if (Platform.isAndroid) {
      final androidDetails = AndroidNotificationDetails(
        _channelId,
        l10n.voiceCallTitle,
        channelDescription: l10n.voiceCallChannelDescription,
        importance: Importance.high,
        priority: Priority.high,
        ongoing: true,
        autoCancel: false,
        playSound: false,
        enableVibration: false,
        showWhen: true,
        usesChronometer: true,
        chronometerCountDown: false,
        category: AndroidNotificationCategory.call,
        visibility: NotificationVisibility.public,
        icon: '@mipmap/ic_launcher',
        colorized: false,
        actions: <AndroidNotificationAction>[
          AndroidNotificationAction(
            muteActionId,
            muteAction,
            icon: DrawableResourceAndroidBitmap(
              isMuted ? '@drawable/ic_mic_off' : '@drawable/ic_mic_on',
            ),
            showsUserInterface: false,
            cancelNotification: false,
          ),
          AndroidNotificationAction(
            _actionEndCall,
            l10n.voiceCallEnd,
            icon: DrawableResourceAndroidBitmap('@drawable/ic_call_end'),
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      );

      await _notifications.show(
        id: _notificationId,
        title: l10n.voiceCallWithModel(modelName),
        body: status,
        notificationDetails: NotificationDetails(android: androidDetails),
      );
    } else if (Platform.isIOS) {
      // iOS doesn't support action buttons for ongoing notifications
      // Use a simpler persistent notification
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: false,
        presentSound: false,
        interruptionLevel: InterruptionLevel.timeSensitive,
      );

      await _notifications.show(
        id: _notificationId,
        title: l10n.voiceCallWithModel(modelName),
        body: status,
        notificationDetails: const NotificationDetails(iOS: iosDetails),
      );
    }
  }

  /// Update notification status
  Future<void> updateCallStatus({
    required String modelName,
    required bool isMuted,
    required bool isSpeaking,
    required bool isPaused,
  }) async {
    await showCallNotification(
      modelName: modelName,
      isMuted: isMuted,
      isSpeaking: isSpeaking,
      isPaused: isPaused,
    );
  }

  /// Cancel the voice call notification
  Future<void> cancelNotification() async {
    await _notifications.cancel(id: _notificationId);
  }

  /// Check if notifications are enabled
  Future<bool> areNotificationsEnabled() async {
    if (Platform.isAndroid) {
      final androidImpl = _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      return await androidImpl?.areNotificationsEnabled() ?? false;
    } else if (Platform.isIOS) {
      // iOS doesn't have a direct check, assume enabled if initialized
      return _initialized;
    }
    return false;
  }

  /// Request notification permissions
  Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      final androidImpl = _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final granted = await androidImpl?.requestNotificationsPermission();
      return granted ?? false;
    } else if (Platform.isIOS) {
      final iosImpl = _notifications
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final granted = await iosImpl?.requestPermissions(
        alert: true,
        badge: false,
        sound: false,
      );
      return granted ?? false;
    }
    return false;
  }
}
