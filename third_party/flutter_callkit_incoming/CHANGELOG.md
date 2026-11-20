## 3.1.6

Hotfix release. Low-risk corrections only — no API changes.

**Behaviour changes to be aware of**
* Android: `${applicationId}.PERMISSION_CALL` is now `signature` instead of `normal`. Any app could previously request it and forge incoming/accept/decline broadcasts. Only affects setups where a separately-signed companion app sends these broadcasts.
* Android: the incoming and ongoing notifications now use the app's own icon as the small icon. Previously an internal drawable always won, so the app icon could never appear.
* Android: the ringtone now respects silent and vibrate ringer modes. It previously played in silent mode.
* iOS: **minimum deployment target raised to 15.0** (podspec was 10.0, `Package.swift` was 13.0). Xcode 26/27 refuse any target below 15.0 outright, so 3.1.5 could not be built with current Xcode at all. Apps still on an older Xcode that need iOS 13/14 should stay on 3.1.5.
  If your own `Podfile`/Xcode project is still below 15.0 you must raise it too, and you may need a `post_install` hook forcing `IPHONEOS_DEPLOYMENT_TARGET` for dependencies that declare very old targets — the example app's `Podfile` shows the pattern.

**Fixes**
* iOS: `ACTION_CALL_DECLINE` stopped being emitted, and incoming calls stopped timing out, after the first outgoing call in a process. The internal call-state slots were never cleared.
* iOS: `timedOutPerforming` resolved the call by the action's own identifier instead of `CXCallAction.callUUID`, so it never matched and `onTimeOut` never fired. It also fulfilled/failed a timed-out action, which `CXProvider` forbids.
* iOS: the ringtone condition used `||` where `&&` was meant, setting an empty `ringtoneSound` on the provider configuration.
* iOS: removed 2602 trailing NUL bytes from `SwiftFlutterCallkitIncomingPlugin.swift`, which made `grep`/`rg` treat the file as binary and skip it. Line endings normalised to LF.
* iOS: the podspec pinned `VALID_ARCHS` to `x86_64` for the simulator, breaking arm64 simulator builds on Apple Silicon. Now uses `EXCLUDED_ARCHS`.
* iOS: added `PrivacyInfo.xcprivacy` declaring the `UserDefaults` required-reason API (`CA92.1`). Verified to ship on both integration paths — inside `flutter_callkit_incoming.framework` under CocoaPods, and as a resource bundle under Swift Package Manager.
* iOS: podspec version now tracks the package version instead of being pinned at `0.0.1`.
* Android: an unknown method channel call returned without submitting a result, leaving the Dart `Future` pending forever. Replies are now routed through a guard so a throw after a successful reply can no longer raise `Reply already submitted`.
* Android: `registerPhoneAccount` could throw on the plugin-attach path and crash the host app at startup.
* Android: the incoming-call screen acquired a wake lock and never released it, keeping the screen on for the full ring duration even after the call was answered or declined.
* Android: `incomingChannelEnabled()` had an operator-precedence bug that reported channels as enabled on pre-Android-8 devices even when notifications were disabled.
* Android: the accept action's label fell back to the default when `textDecline` was empty rather than `textAccept`.
* Android: the incoming-call screen's dynamic receiver was registered as `RECEIVER_EXPORTED` for an app-private action.
* Android: `unregisterReceiver` is now guarded against `IllegalArgumentException`.
* Android: added `android:showWhenLocked` to the incoming-call activity; several OEMs honour only the manifest attribute.
* Android: dropped the unused `androidx.localbroadcastmanager` dependency.

## 3.1.5
* Fix Android: resolve build errors introduced in 3.1.4.
* Fix Android: always call `startForeground` to prevent `ForegroundServiceDidNotStartInTimeException`, thank @AAkira https://github.com/hiennguyen92/flutter_callkit_incoming/pull/857
* Fix Android: remove automatic launch of full screen intent settings that crashes `CallkitIncomingActivity` on Android 14+, thank @AAkira https://github.com/hiennguyen92/flutter_callkit_incoming/pull/856
* Fix Android: stop incoming ringtone from silencing itself, and silence it correctly on volume-key press, thank @AAkira https://github.com/hiennguyen92/flutter_callkit_incoming/pull/855
* Fix Android: native `OnDecline` callback not running when app is in terminated state, thank @salamay https://github.com/hiennguyen92/flutter_callkit_incoming/pull/854
* Fix Android: complete Telecom hold integration for self-managed calls, thank @m-lhb https://github.com/hiennguyen92/flutter_callkit_incoming/pull/852
* Fix Android: only add `MICROPHONE`/`CAMERA` foreground service types when permission is granted, thank @m-lhb https://github.com/hiennguyen92/flutter_callkit_incoming/pull/848
* Fix Android: restore foreground service on OS restart to prevent microphone loss in background, thank @skutimechanic https://github.com/hiennguyen92/flutter_callkit_incoming/pull/842
* Fix Android: `ActionCallToggleAudioSession` key name `isActivate` inconsistency, thank @skutimechanic https://github.com/hiennguyen92/flutter_callkit_incoming/pull/836
* Fix iOS: send `isActive` (not `isActivate`) in `ACTION_CALL_TOGGLE_AUDIO_SESSION` events, thank @m-lhb https://github.com/hiennguyen92/flutter_callkit_incoming/pull/853
* Fix iOS: audio session ordering and end-call action handling for edge cases, thank @m-lhb https://github.com/hiennguyen92/flutter_callkit_incoming/pull/850
* Fix iOS: don't re-answer an already-connected call in `connectedCall`, thank @m-lhb https://github.com/hiennguyen92/flutter_callkit_incoming/pull/849
* Fix iOS: crash on `ACTION_CALL_CUSTOM` — convert event body instead of unsafe cast, thank @andrei-uni https://github.com/hiennguyen92/flutter_callkit_incoming/pull/847

## 3.1.4

* Fix Android: always call `startForeground` to prevent `ForegroundServiceDidNotStartInTimeException`, thank @AAkira https://github.com/hiennguyen92/flutter_callkit_incoming/pull/857
* Fix Android: remove automatic launch of full screen intent settings that crashes `CallkitIncomingActivity` on Android 14+, thank @AAkira https://github.com/hiennguyen92/flutter_callkit_incoming/pull/856
* Fix Android: stop incoming ringtone from silencing itself, and silence it correctly on volume-key press, thank @AAkira https://github.com/hiennguyen92/flutter_callkit_incoming/pull/855
* Fix Android: native `OnDecline` callback not running when app is in terminated state, thank @salamay https://github.com/hiennguyen92/flutter_callkit_incoming/pull/854
* Fix Android: complete Telecom hold integration for self-managed calls, thank @m-lhb https://github.com/hiennguyen92/flutter_callkit_incoming/pull/852
* Fix Android: only add `MICROPHONE`/`CAMERA` foreground service types when permission is granted, thank @m-lhb https://github.com/hiennguyen92/flutter_callkit_incoming/pull/848
* Fix Android: restore foreground service on OS restart to prevent microphone loss in background, thank @skutimechanic https://github.com/hiennguyen92/flutter_callkit_incoming/pull/842
* Fix Android: `ActionCallToggleAudioSession` key name `isActivate` inconsistency, thank @skutimechanic https://github.com/hiennguyen92/flutter_callkit_incoming/pull/836
* Fix iOS: send `isActive` (not `isActivate`) in `ACTION_CALL_TOGGLE_AUDIO_SESSION` events, thank @m-lhb https://github.com/hiennguyen92/flutter_callkit_incoming/pull/853
* Fix iOS: audio session ordering and end-call action handling for edge cases, thank @m-lhb https://github.com/hiennguyen92/flutter_callkit_incoming/pull/850
* Fix iOS: don't re-answer an already-connected call in `connectedCall`, thank @m-lhb https://github.com/hiennguyen92/flutter_callkit_incoming/pull/849
* Fix iOS: crash on `ACTION_CALL_CUSTOM` — convert event body instead of unsafe cast, thank @andrei-uni https://github.com/hiennguyen92/flutter_callkit_incoming/pull/847

## 3.1.3
* Fix Android: do not launch app when call is declined from self-managed Telecom connection, thank @iboogey https://github.com/hiennguyen92/flutter_callkit_incoming/pull/829

## 3.1.2
* Fix pack mapped data to expose call event, thank @skutimechanic https://github.com/hiennguyen92/flutter_callkit_incoming/pull/823
* Fix iOS: restore maximumCallGroups config, hold handler, holdCall event, thank @md-riaz https://github.com/hiennguyen92/flutter_callkit_incoming/pull/825

## 3.1.1
* Reorganize iOS native source directory to support Swift Package Manager (SPM) by placing all source files inside the package root (`ios/flutter_callkit_incoming/Classes/`).
* Resolve SPM mixed-language constraint by removing Objective-C wrappers and implementing a pure-Swift registrar class `@objc(FlutterCallkitIncomingPlugin)` to ensure seamless CocoaPods backward compatibility.
* Modernize example app's Objective-C imports in `AppDelegate.m` using Clang module import syntax `@import flutter_callkit_incoming;`.

## 3.1.0
* Add native **Swift Package Manager (SPM)** support for iOS with auto-linked `CryptoSwift` dependency.
* Add explicit Objective-C compatible overload `showCallkitIncoming(_:fromPushKit:)` in `SwiftFlutterCallkitIncomingPlugin` to fix compilation issues in native Objective-C runner.
* Conform `AppDelegate` in example project to `CallkitIncomingAppDelegate` by implementing the missing `providerDidReset()` method.
* Update environment constraints in `pubspec.yaml` to require Dart SDK `>=3.0.0` and Flutter `>=3.10.0`.
* Add optional `onError` completion handler to `showCallkitIncoming` for iOS, thank @nukeolay https://github.com/hiennguyen92/flutter_callkit_incoming/pull/803
* Implement self-managed Telecom ConnectionService on Android, thank @kennss https://github.com/hiennguyen92/flutter_callkit_incoming/pull/809
* Add Background Message Handler and Enhanced Android Foreground Service Support, thank @fedehsq https://github.com/hiennguyen92/flutter_callkit_incoming/pull/800
* Fix Android duplicated notification on call connected event, thank @skutimechanic https://github.com/hiennguyen92/flutter_callkit_incoming/pull/764
* Refactor and improve type safety, thank @AAkira https://github.com/hiennguyen92/flutter_callkit_incoming/pull/772
* Implement volume key handling to mute incoming call sound on key press, thank @jawad1257 https://github.com/hiennguyen92/flutter_callkit_incoming/pull/781
* Fix ongoing ringtone and vibrations on the action call connected, thank @skutimechanic https://github.com/hiennguyen92/flutter_callkit_incoming/pull/783
* Add custom color option for accept and decline buttons for Android, thank @baldarama https://github.com/hiennguyen92/flutter_callkit_incoming/pull/790
* Fix Android ringtone/vibration stopping on auto lock, thank @phildupuis https://github.com/hiennguyen92/flutter_callkit_incoming/pull/792
* Dynamically update CXProvider configuration for subsequent calls on iOS, thank @MS-Rex https://github.com/hiennguyen92/flutter_callkit_incoming/pull/805
* Fix Android showCallkitIncoming silently dropping calls when host process is kept alive, thank @sherzodkamoldinov https://github.com/hiennguyen92/flutter_callkit_incoming/pull/808
* Refactor notification and sound management: Updated incoming notification, thank @AbdurahmanAlmehdi https://github.com/hiennguyen92/flutter_callkit_incoming/pull/812
* Fix iOS outgoing call actionCallAccept emitting default/empty Data instead of original call params, thank @mechtech-mind https://github.com/hiennguyen92/flutter_callkit_incoming/pull/813
* Fix and handle null intent.action in TransparentActivity, thank @AlexBacich https://github.com/hiennguyen92/flutter_callkit_incoming/pull/814

## 3.0.0
* Using Plugin DSL for Android, thank @AAkira https://github.com/hiennguyen92/flutter_callkit_incoming/pull/743
* Add Android native callback, thank @joshoconnor89 https://github.com/hiennguyen92/flutter_callkit_incoming/pull/736
* Improve plugin lifecycle, thank @lohzi97 https://github.com/hiennguyen92/flutter_callkit_incoming/pull/746
* Fixed some bugs.

## 2.5.8
* Fix OnGoing notification Android
* Add missed call notification for iOS(notification/callback action - need to setup more in AppDelegate.swift)
* Add `requestNotificationPermission` for iOS

## 2.5.7
* Fix build Android
* Fix stop sound notification when screen off Android

## 2.5.6
* Fix bug duplicate permission Android
* Replaces MediaPlayer with Ringtone Android
* Fix bug notification channel Android
* Stop sound notification when screen off Android

## 2.5.5
* Fix bug duplicate permission Android

## 2.5.4
* Fix bug custom permission Android
* Remove calling notification when task remove
* Fixed calling notification show
* Fixed some bugs.

## 2.5.3
* Update Android 14+ compatibility(force CallStyle/`FOREGROUND_SERVICE_PHONE_CALL` for https://developer.android.com/about/versions/14/behavior-changes-all#non-dismissable-notifications)
* Change structure Notification/Sound on Android
* Update get avatar from assets(Android), thanks @Ricky-yu https://github.com/hiennguyen92/flutter_callkit_incoming/pull/674
* Add `isAccepted` properties for iOS and only show facetime button if support video, thank @td2thinh https://github.com/hiennguyen92/flutter_callkit_incoming/pull/673
* Fixed some bugs.

## 2.5.3-alpha
* Update Android 14+ compatibility(force CallStyle/`FOREGROUND_SERVICE_PHONE_CALL` for https://developer.android.com/about/versions/14/behavior-changes-all#non-dismissable-notifications)
* Fixed some bugs.

## 2.5.2
* Add notification calling for Android `callingNotification`, thank @ebsangam https://github.com/hiennguyen92/flutter_callkit_incoming/pull/662
* Add `logoUrl` properties (inside android prop) 
* Fixed issue DMTF IOS, thank @minn-ee https://github.com/hiennguyen92/flutter_callkit_incoming/issues/577
* Fixed issue duplicate missing notification Android
* Fixed some bugs.

## 2.5.1
* Fix issue security Android, thanks @datpt11 https://github.com/hiennguyen92/flutter_callkit_incoming/issues/651

## 2.5.0
* update jvmToolchain(17) for Android

## 2.0.4+2
* add func `requestFullIntentPermission` (Android 14+) thank @Spyspyspy https://github.com/hiennguyen92/flutter_callkit_incoming/pull/584
* set Notification call style (Android) thank @AAkira https://github.com/hiennguyen92/flutter_callkit_incoming/pull/553
* Many other issues
    1. add prop `accepted` in activeCalls (iOS) thank @vasilich6107

## 2.0.4+1
* Removed `Telecom Framework` (Android)

## 2.0.4
* Removed `Telecom Framework` (Android)
* Fixed hide notification for action `CallBack` (Android)

## 2.0.3
* Fixed linked func `hideCallkitIncoming`

## 2.0.2+2
* Fixed linked func `hideCallkitIncoming`

## 2.0.2+1
* Fixed linked func `hideCallkitIncoming`

## 2.0.2
* Add func `hideCallkitIncoming` clear the incoming notification/ring (after accept/decline/timeout)
* Add props `isShowFullLockedScreen` on Android
* Fixed example/Fixed update android 14

## 2.0.1+2
* Add Action for onDecline
* Add Action for onEnd
* add android props `isShowCallID`

## 2.0.1+1
* Add Callback AVAudioSession for WebRTC setup
* Fix issue no audio for using WebRTC

## 2.0.1-dev.2
* Add Action for onAccept

## 2.0.1-dev.1
* Add AVAudioSession Appdelegate(iOS)

## 2.0.1-dev
* Add AVAudioSession Appdelegate(iOS)

## 2.0.1

* Fixed some bugs.
* `Android` using Telecom Framework
* Add `silenceEvents`
* Add `normalHandle` props https://github.com/hiennguyen92/flutter_callkit_incoming/pull/403
* Android add `textColor` props https://github.com/hiennguyen92/flutter_callkit_incoming/pull/398
* Android invisible avatar for default https://github.com/hiennguyen92/flutter_callkit_incoming/pull/393
* Add Method for call API when accept/decline/end/timeout

## 2.0.0+2

* Fixed some bugs.
* Support request permission for Android 13+ `requestNotificationPermission`

## 2.0.0+1

* Fixed some bugs.
* Add `landscape` for tablet
* Fix issue head-up for redmi / xiaomi devices

## 2.0.0

* Fixed some bugs.
* Adapt flutter_lints and use lowerCamelCase to Event enum
* Rename properties 
        `textMisssedCall` -> `subtitle`,
        `textCallback` -> `callbackText`,
        `isShowMissedCallNotification` -> `showNotification`,
* Move inside properties `missedCallNotification {showNotification, isShowCallback, subtitle, callbackText}`
* Add setCallConnected option iOS `await FlutterCallkitIncoming.setCallConnected(this._currentUuid)`
* Add hold option iOS
* Add mute call option iOS
* Many other issues
    1. Thank @ryojiro
    https://github.com/hiennguyen92/flutter_callkit_incoming/pull/263
    https://github.com/hiennguyen92/flutter_callkit_incoming/pull/264
    https://github.com/hiennguyen92/flutter_callkit_incoming/pull/262
    2. Many Thank @mouEsam
    https://github.com/hiennguyen92/flutter_callkit_incoming/pull/227
    3. ...


## 1.0.3+3

* Update README.md
* Fixed some bugs.

## 1.0.3+2

* REMOVED

## 1.0.3+1

* Dart class models instead using dynamic types and Maps (thank @icodelifee - https://github.com/hiennguyen92/flutter_callkit_incoming/pull/180)
* Allow to call from native Android (thank @fabiocody - https://github.com/hiennguyen92/flutter_callkit_incoming/pull/185)
* Add android notification channel name `incomingCallNotificationChannelName` `missedCallNotificationChannelName` (thank @AAkira - https://github.com/hiennguyen92/flutter_callkit_incoming/pull/177)
* Adding the feature to change template of notification to small `isCustomSmallExNotification` (thank @anocean2 - https://github.com/hiennguyen92/flutter_callkit_incoming/pull/196)
* Fixed ringtone sound not playing in Release mode on Android (thank @mschudt - https://github.com/hiennguyen92/flutter_callkit_incoming/pull/204)
* Fixed some bugs.

## 1.0.3

* REMOVED

## 1.0.2+2

* Fix notification Android 12
* Fix sound notification
* Support `backgroundUrl` using path assets
* Fixed some bugs.

## 1.0.2+1

* Issue no audio when Accept(iOS)
* Duplicate sound notification(Android)
* Support Flutter 3
* Fixed some bugs.

## 1.0.2

* Fixed issue open app(terminated/background state - Android).
* Completed Example  
* Fixed some bugs.

## 1.0.1+8

* Add props `isShowMissedCallNotification` using show Missed call notification(Android)
* Fixed issue decline(terminated/background state - there will be about 3 seconds to call the api before the app is closed.)
* Fixed some bugs.

## 1.0.1+7

* Fixed issue open app(terminated/background state).
* Fixed some bugs.

## 1.0.1+6

* Add props for text
* Fixed issue open app(terminated/background state).
* Fixed some bugs.

## 1.0.1+5

* Update custom miss call notification
* Fixed issue open app(terminated/background state).

## 1.0.1+4

* add `showMissCallNotification` only for Android, using show miss call notification 
* Fixed some bugs.

## 1.0.1+3

* add props `isShowCallback` using show Callback for miss call(Android)
* public props data call for Object-C/Swift
* Example using FCM(Android)
* Fixed some bugs.

## 1.0.1+2

* Fixed issue default ringtone(Android)
* Fixed issue vibration(Android)
* Fixed issue sound play type ringtone volumn system(Android)
* Fixed flow incomming screen(Android)
* Fixed some bugs.

## 1.0.1+1

* Switch using Service for Ringtone(Android)
* Fixed issue vibration(Android)
* Add `getDevicePushTokenVoIP()` feature
* Fixed some bugs.

## 1.0.1

* Pustkit and VoIP setup instructions (PUSHKIT.md)
* Callback from Recent History IOS
* Using System ringtone for default
* Fixed func `endAllCalls()` Android
* Bugs Android 12.
* Fixed some bugs.

## 1.0.0+8

* Share func call from native(iOS)

## 1.0.0+7

* Add custom `headers` using for avatar/background image (only for Android)

## 1.0.0+6

* Fixed func `activeCalls()` Get active calls

## 1.0.0+5

* Fixed endCall
* Bugs Targeting Android 12 (Android).
* Bugs `audio session` (iOS)
* Fixed some bugs.

## 1.0.0+4

* Update README.md.
* Add func `activeCalls()` Get active calls
* Remove notification when click action `Call back` (Android).
* Bugs `no activation of the audio session` (iOS)
* Fixed some bugs.

## 1.0.0+3

* Update README.md.
* Add props android `isShowLogo`.
* Fixed some bugs.

## 1.0.0+2

* Update README.md.
* Update documentation.

## 1.0.0+1

* Update README.md.
* Fixed some bugs.

## 1.0.0

* Initial release.
