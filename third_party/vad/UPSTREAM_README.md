# VAD
[![pub package](https://img.shields.io/pub/v/vad.svg)](https://pub.dev/packages/vad)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![GitHub Repo](https://img.shields.io/badge/GitHub-Repo-blue.svg)](https://github.com/keyur2maru/vad)
<p align="center">
  <img src="https://raw.githubusercontent.com/keyur2maru/vad/master/img/vad.svg" max-height="100" alt="VAD" />
</p>


VAD is a Flutter library for Voice Activity Detection (VAD) across **iOS**, **Android**, **Web**, **macOS**, **Windows**, and **Linux** platforms. This package allows applications to start and stop VAD-based listening and handle various VAD events seamlessly.

Under the hood, the VAD Package uses direct FFI bindings to ONNX Runtime for native platforms (iOS, Android, macOS, Windows, Linux) and `dart:js_interop` for Web. All platforms utilize the Silero VAD models with full-feature parity across platforms.

The package provides a simple API to start and stop VAD listening, configure VAD parameters, and handle VAD events such as speech start, speech end, errors, and misfires.

**Note:** Echo cancellation is not available on Windows and Linux platforms due to limitations in the underlying audio capture library.

<p align="center">
  <img src="https://raw.githubusercontent.com/keyur2maru/vad/master/img/screenshot-1.png" alt="Screenshot 1" />
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/keyur2maru/vad/master/img/screenshot-2.png" alt="Screenshot 2" />
</p>

## Table of Contents
<!-- TOC start (generated with https://github.com/derlin/bitdowntoc) -->

- [VAD](#vad)
    * [Table of Contents](#table-of-contents)
    * [Live Demo](#live-demo)
    * [Features](#features)
    * [Getting Started](#getting-started)
        + [Prerequisites](#prerequisites)
            - [Web](#web)
            - [iOS](#ios)
            - [Android](#android)
    * [Installation](#installation)
    * [Usage](#usage)
        + [Example](#example)
            - [Explanation of the Example](#explanation-of-the-example)
    * [VadHandler API](#vadhandler-api)
        + [Methods](#methods)
            - [`create`](#create)
            - [`startListening`](#startlistening)
            - [`stopListening`](#stoplistening)
            - [`pauseListening`](#pauselistening)
            - [`dispose`](#dispose)
        +  [Events](#events)
            - [`onSpeechEnd`](#onspeechend)
            - [`onSpeechStart`](#onspeechstart)
            - [`onRealSpeechStart`](#onrealspeechstart)
            - [`onVADMisfire`](#onvadmisfire)
            - [`onFrameProcessed`](#onframeprocessed)
            - [`onError`](#onerror)
    * [Permissions](#permissions)
        + [iOS](#ios-1)
        + [Android](#android-1)
        + [Web](#web-1)
    * [Cleaning Up](#cleaning-up)
    * [Troubleshooting](#troubleshooting)
        + [Reporting Issues](#reporting-issues)
            - [Capturing logcat on Android](#capturing-logcat-on-android)
            - [Routing logs to your crash reporter (`onLog`)](#routing-logs-to-your-crash-reporter-onlog)
        + [iOS Issues](#ios-issues)
            - [TestFlight Build Error: "Failed to lookup symbol 'OrtGetApiBase'"](#testflight-build-error-failed-to-lookup-symbol-ortgetapibase)
        + [Android Issues](#android-issues)
            - [Echo Cancellation Not Working on Some Android Devices](#echo-cancellation-not-working-on-some-android-devices)
    * [Tested Platforms](#tested-platforms)
    * [Contributing](#contributing)
    * [Acknowledgements](#acknowledgements)
    * [License](#license)

<!-- TOC end -->

## Live Demo
Check out the [VAD Package Example App](https://keyur2maru.github.io/vad/) to see the VAD Package in action on the Web platform.

## Features

- **Cross-Platform Support:**  Works seamlessly on iOS, Android, Web, macOS, Windows, and Linux.

- **Event Streams:**  Listen to events such as speech start, real speech start, speech end, speech misfire, frame processed, and errors.

- **Silero V4 and V5 Models:**  Supports both Silero VAD v4 and v5 models.

- **16KB Page Size Support:**  Native Android libraries are properly aligned for 16KB page sizes, meeting Google Play requirements for Android 15+ devices.

- **Custom Audio Streams:**  Provide your own audio stream for advanced use cases like custom recording configurations or processing audio from non-microphone sources.

## Getting Started

### Prerequisites

Before integrating the VAD Package into your Flutter application, ensure that you have the necessary configurations for each target platform.

#### Web
To use VAD on the web, include the following scripts within the head and body tags respectively in the `web/index.html` file to load the necessary VAD libraries:

**Option 1: Using CDN (Default)**
```html
<head>
  ...
  <script src="https://cdn.jsdelivr.net/npm/onnxruntime-web@1.22.0/dist/ort.wasm.min.js"></script>
  ...
</head>
```

**Option 2: Using Local Assets (Offline/Self-hosted)**
If you prefer to bundle all assets locally instead of using CDN:

1. Download the required files to your `assets/` directory:
   - [ort.wasm.min.js](https://cdn.jsdelivr.net/npm/onnxruntime-web@1.22.0/dist/ort.wasm.min.js)
   - [ort-wasm-simd-threaded.wasm](https://cdn.jsdelivr.net/npm/onnxruntime-web@1.22.0/dist/ort-wasm-simd-threaded.wasm)
   - [ort-wasm-simd-threaded.mjs](https://cdn.jsdelivr.net/npm/onnxruntime-web@1.22.0/dist/ort-wasm-simd-threaded.mjs)
   - [silero_vad_v5.onnx](https://cdn.jsdelivr.net/npm/@keyurmaru/vad@0.0.1/silero_vad_v5.onnx) and/or [silero_vad_legacy.onnx](https://cdn.jsdelivr.net/npm/@keyurmaru/vad@0.0.1/silero_vad_legacy.onnx)

2. Update your `web/index.html`:
```html
<head>
  ...
  <script src="assets/ort.wasm.min.js"></script>
  ...
</head>
```

3. Configure your VAD handler to use local assets:
```dart
await vadHandler.startListening(
  baseAssetPath: '/assets/',        // For VAD model files
  onnxWASMBasePath: '/assets/',     // For ONNX Runtime WASM files
  // ... other parameters
);
```

You can also refer to the [VAD Example App](https://github.com/keyur2maru/vad/blob/master/example/web/index.html) for a complete example.

**Tip: Enable WASM multithreading ([SharedArrayBuffer](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/SharedArrayBuffer)) for performance improvements**

* For Production, send the following headers in your server response:
  ```html
  Cross-Origin-Embedder-Policy: require-corp
  Cross-Origin-Opener-Policy: same-origin
  ```

* For Local, refer to the workaround applied in the GitHub Pages demo page for the example app. It is achieved with the inclusion of [enable-threads.js](https://github.com/keyur2maru/vad/blob/master/example/web/enable-threads.js) and loading it in the [web/index.html#L24](https://github.com/keyur2maru/vad/blob/master/example/web/index.html#L24) file in the example app.


#### iOS
For iOS, you need to configure microphone permissions and other settings in your `Info.plist` file.
1. **Add Microphone Usage Description:** Open `ios/Runner/Info.plist` and add the following entries to request microphone access:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs access to the microphone for Voice Activity Detection.</string>
```

2. **Configure Build Settings:** Ensure that your `Podfile` includes the necessary build settings for microphone permissions:

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= [
        '$(inherited)',
        'PERMISSION_MICROPHONE=1',
      ]
    end
  end
end
```

#### Android
For Android, configure the required permissions and build settings in your `AndroidManifest.xml` and `build.gradle` files.
1. **Add Permissions:** Open `android/app/src/main/AndroidManifest.xml` and add the following permissions:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>
```

2. **Configure Build Settings:** Open `android/app/build.gradle` and add the following settings:
```gradle
android {
    compileSdkVersion 34
    ...
}
```


## Installation
Add the VAD Package to your `pubspec.yaml` dependencies:
```yaml
dependencies:
  flutter:
    sdk: flutter
  vad: ^0.0.5
  permission_handler: ^11.3.1
```
Then, run `flutter pub get` to fetch the packages.
## Usage

### Example

Below is a simple example demonstrating how to integrate and use the VAD Package in a Flutter application.
For a more detailed example, check out the [VAD Example App](https://github.com/keyur2maru/vad/tree/master/example) in the GitHub repository.


```dart
// main.dart
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vad/vad.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text("VAD Example")),
        body: const MyHomePage(),
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final _vadHandler = VadHandler.create(isDebug: true);
  bool isListening = false;
  final List<String> receivedEvents = [];

  @override
  void initState() {
    super.initState();
    _setupVadHandler();
  }

  void _setupVadHandler() {
    _vadHandler.onSpeechStart.listen((_) {
      debugPrint('Speech detected.');
      setState(() {
        receivedEvents.add('Speech detected.');
      });
    });

    _vadHandler.onRealSpeechStart.listen((_) {
      debugPrint('Real speech start detected (not a misfire).');
      setState(() {
        receivedEvents.add('Real speech start detected (not a misfire).');
      });
    });

    _vadHandler.onSpeechEnd.listen((List<double> samples) {
      debugPrint('Speech ended, first 10 samples: ${samples.take(10).toList()}');
      setState(() {
        receivedEvents.add('Speech ended, first 10 samples: ${samples.take(10).toList()}');
      });
    });

    _vadHandler.onFrameProcessed.listen((frameData) {
      final isSpeech = frameData.isSpeech;
      final notSpeech = frameData.notSpeech;
      final firstFewSamples = frameData.frame.take(5).toList();

      debugPrint('Frame processed - Speech probability: $isSpeech, Not speech: $notSpeech');
      debugPrint('First few audio samples: $firstFewSamples');

      // You can use this for real-time audio processing
    });

    _vadHandler.onVADMisfire.listen((_) {
      debugPrint('VAD misfire detected.');
      setState(() {
        receivedEvents.add('VAD misfire detected.');
      });
    });

    _vadHandler.onError.listen((String message) {
      debugPrint('Error: $message');
      setState(() {
        receivedEvents.add('Error: $message');
      });
    });
  }

  @override
  void dispose() {
    _vadHandler.dispose(); // Note: dispose() is called without await in Widget.dispose()
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ElevatedButton.icon(
            onPressed: () async {
              if (isListening) {
                await _vadHandler.stopListening();
              } else {
                await _vadHandler.startListening();
              }
              setState(() {
                isListening = !isListening;
              });
            },
            icon: Icon(isListening ? Icons.stop : Icons.mic),
            label: Text(isListening ? "Stop Listening" : "Start Listening"),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () async {
              final status = await Permission.microphone.request();
              debugPrint("Microphone permission status: $status");
            },
            icon: const Icon(Icons.settings_voice),
            label: const Text("Request Microphone Permission"),
            style: TextButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.builder(
              itemCount: receivedEvents.length,
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(receivedEvents[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
```
#### Explanation of the Example
1. **Initialization:**
- Initializes the `VadHandler` with debugging enabled.

- Sets up listeners for various VAD events (`onSpeechStart`, `onRealSpeechStart`, `onSpeechEnd`, `onFrameProcessed`, `onVADMisfire`, `onError`).

2.  **Permissions:**
- Requests microphone permission when the "Request Microphone Permission" button is pressed.

3. **Listening Controls:**
- Toggles listening on and off with the "Start Listening"/"Stop Listening" button.

- Configures the audio player to mix with other audio sources on iOS.

4. **Event Handling:**
- Displays received events in a list view.

- Updates the UI based on the received events.

**Note: For Real-time Audio Processing, listen to the onFrameProcessed events to access raw audio frames and speech probabilities as they're processed.**
## VadHandler API

### Methods


#### `create`
Creates a new instance of the `VadHandler`.

```dart
static VadHandler create({
  bool isDebug = false,
  VadLogCallback? onLog,
});
```

- `isDebug` — enables verbose `print` logging of internal state transitions. Useful while developing; leave off in production.
- `onLog` — optional callback `void Function(String message)` invoked for all production (non-debug) log lines the plugin emits. This includes the model-init breadcrumb (`VadModel: creating OrtSession (...)`), session-creation errors on native and web, frame-processing and inference errors from `VadIterator`, and audio-stream / permission failures from `VadHandler`. When provided, these lines are routed through your callback instead of `print` — wire it to your crash reporter (Crashlytics, Sentry, etc.) so the breadcrumbs land in crash reports. Verbose state-transition logs gated behind `isDebug` continue to go to `print` and are **not** routed through `onLog`. See [Routing logs to your crash reporter](#routing-logs-to-your-crash-reporter-onlog).

Model files are loaded from CDN by default but can be customized using the `baseAssetPath` parameter in `startListening`.

#### `startListening`
Starts the VAD with configurable parameters. Returns a `Future<void>` that completes when the VAD session has started.
Notes:
- The sample rate is fixed at 16kHz, which means when using legacy model with default frameSamples value, one frame is equal to 1536 samples or 96ms.
- For Silero VAD v5 model, frameSamples must be set to 512 samples unlike the previous version, so one frame is equal to 32ms.
- `model` parameter can be set to 'legacy' or 'v5' to use the respective VAD model. Default is 'legacy'.
- `baseAssetPath` specifies the base URL/path for VAD model files (.onnx). Defaults to CDN (`https://cdn.jsdelivr.net/npm/@keyurmaru/vad@0.0.1/`) but can be overridden for custom hosting. **<u>Applicable for all platforms.</u>**
- `onnxWASMBasePath` specifies the base URL/path for onnxruntime WASM files. Defaults to CDN (`https://cdn.jsdelivr.net/npm/onnxruntime-web@1.22.0/dist/`) but can be overridden for custom hosting. **<u>Only applicable for the Web platform.</u>**
- `recordConfig` allows you to provide custom recording configuration for native platforms (iOS, Android, macOS, Windows, Linux). If not provided, default configuration with 16kHz sample rate, PCM16 encoding, echo cancellation, auto gain, and noise suppression will be used. **<u>Only applicable for native platforms. Note: Echo cancellation is not available on Windows and Linux.</u>**

```dart
Future<void> startListening({
  double positiveSpeechThreshold = 0.5,
  double negativeSpeechThreshold = 0.35,
  int preSpeechPadFrames = 1,
  int redemptionFrames = 8,
  int frameSamples = 1536,
  int minSpeechFrames = 3,
  bool submitUserSpeechOnPause = false,
  String model = 'legacy',
  String baseAssetPath = 'https://cdn.jsdelivr.net/npm/@keyurmaru/vad@0.0.1/',
  String onnxWASMBasePath = 'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.22.0/dist/',
  RecordConfig? recordConfig,
  Stream<Uint8List>? audioStream,
});
```

**Custom Audio Stream:**
- `audioStream` allows you to provide your own audio stream instead of using the built-in recorder. When provided, VadHandler will process audio from this stream instead of creating its own AudioRecorder. The stream should provide PCM16 audio data at 16kHz sample rate, mono channel. This is useful for:
  - Custom recording configurations not supported by the default recorder
  - Processing audio from non-microphone sources (files, network streams, etc.)
  - Integration with existing audio pipelines in your application

Example usage with custom audio stream:
```dart
import 'dart:typed_data';
import 'package:record/record.dart';

// Create your custom audio stream provider
class CustomAudioProvider {
  AudioRecorder? _recorder;
  Stream<Uint8List>? _stream;

  Future<void> initialize() async {
    _recorder = AudioRecorder();
    const config = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
    );
    _stream = await _recorder!.startStream(config);
  }

  Stream<Uint8List>? get audioStream => _stream;

  Future<void> dispose() async {
    await _recorder?.dispose();
  }
}

// Use it with VadHandler
final provider = CustomAudioProvider();
await provider.initialize();

await vadHandler.startListening(
  audioStream: provider.audioStream,  // Pass your custom stream
  // ... other parameters
);
```

See the [example app's CustomAudioStreamProvider](https://github.com/keyur2maru/vad/blob/master/example/lib/custom_audio_stream_provider.dart) for a complete implementation.

#### `stopListening`
Stops the VAD session. Returns a `Future<void>` that completes when the VAD session has stopped.


```dart
Future<void> stopListening();
```

#### `pauseListening`
Pauses VAD-based listening without fully stopping the audio stream. Returns a `Future<void>` that completes when the VAD session has been paused.

Note: If `submitUserSpeechOnPause` was enabled, any in-flight speech will immediately be submitted (`forceEndSpeech()`).

```dart
Future<void> pauseListening();
```

#### `dispose`
Disposes the VADHandler and closes all streams. Returns a `Future<void>` that completes when all resources have been disposed.


```dart
Future<void> dispose();
```

## Events
Available event streams to listen to various VAD events:

#### `onSpeechEnd`
Emitted when speech end is detected, providing audio samples.

#### `onSpeechStart`
Emitted when speech start is detected.

#### `onRealSpeechStart`
Emitted when actual speech is confirmed (exceeds minimum frames threshold).

#### `onVADMisfire`
Emitted when speech was initially detected but didn't meet the minimum speech frames threshold.

#### `onFrameProcessed`
Emitted after each audio frame is processed, providing speech probabilities and raw audio data.

#### `onError`
Emitted when an error occurs.


## Permissions

Proper handling of microphone permissions is crucial for the VAD Package to function correctly on all platforms.

### iOS

- **Configuration:** Ensure that `NSMicrophoneUsageDescription` is added to your `Info.plist` with a descriptive message explaining why the app requires microphone access.

- **Runtime Permission:** Request microphone permission at runtime using the `permission_handler` package.

### Android

- **Configuration:** Add the `RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS`, and `INTERNET` permissions to your `AndroidManifest.xml`.

- **Runtime Permission:** Request microphone permission at runtime using the `permission_handler` package.

### Web

- **Browser Permissions:**
  Microphone access is managed by the browser. Users will be prompted to grant microphone access when the VAD starts listening.

## Cleaning Up

To prevent memory leaks and ensure that all resources are properly released, always call the `dispose` method on the `VadHandler` instance when it's no longer needed. Since `dispose()` is now async, use `await` when possible:

```dart
// When called from an async context
await vadHandler.dispose();

// In Widget.dispose() (synchronous context), call without await
vadHandler.dispose();
```

## Troubleshooting

### Reporting Issues

If the VAD package crashes or misbehaves on a specific device, please include logs with your GitHub issue. The package emits a one-line breadcrumb immediately before every ONNX Runtime session creation — it looks like:

```
VadModel: creating OrtSession (model=v5 path=... bytes=2113665 sampleRate=16000 intraOp=2 interOp=2 os=android osVersion="...")
```

When the native session creation succeeds this line is informational; when it crashes the process (e.g. a `SIGSEGV` inside `libonnxruntime.so`) this is the **last** thing logged before the crash and tells us exactly what triggered it. There are two ways to capture it:

#### Capturing logcat on Android

For local repros, plug in the device and run:

```bash
adb logcat -s flutter:*
```

Reproduce the crash, then copy the surrounding lines (especially anything containing `VadModel:`, `tombstone`, or `libonnxruntime.so`) into your issue. For production crashes, ask the affected user to install the debug build of your app and capture logcat the same way, or use a vendor crash reporter (see below).

#### Routing logs to your crash reporter (`onLog`)

`VadHandler.create` accepts an optional `onLog` callback that receives every non-debug log line the plugin emits — the model-init breadcrumb, native/web session-creation errors, frame and inference errors from `VadIterator`, and audio-stream / permission failures from `VadHandler`. Wire it to whatever telemetry your app already uses so the lines land automatically in crash reports — no per-user logcat capture needed. (Verbose `if (isDebug) print(...)` state-transition logs continue to go to `print` and are not routed through the callback.)

Example with Firebase Crashlytics:

```dart
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:vad/vad.dart';

final vad = VadHandler.create(
  isDebug: false,
  onLog: (message) => FirebaseCrashlytics.instance.log(message),
);
```

Equivalent patterns work for Sentry (`Sentry.addBreadcrumb(Breadcrumb(message: message))`), Bugsnag (`Bugsnag.leaveBreadcrumb(message)`), or any other reporter. The callback is fully optional — when omitted, breadcrumbs continue to go to `print`/logcat as before.

When opening a GitHub issue, please include:

- The `VadModel: creating OrtSession (...)` breadcrumb (or full logcat if you have it)
- Device model, Android/iOS version, and ABI (`armeabi-v7a` vs `arm64-v8a` is especially important on Android)
- The exact `vad` package version and whether the failure is on first init or after several sessions

### iOS Issues

#### TestFlight Build Error: "Failed to lookup symbol 'OrtGetApiBase'"

If you encounter this error when uploading to TestFlight:
```
flutter: VAD model initialization failed: Invalid argument(s): Failed to lookup symbol 'OrtGetApiBase': dlsym(RTLD_DEFAULT, OrtGetApiBase): symbol not found
```

**Fix:** Configure Xcode build settings to prevent symbol stripping:
1. Open Xcode → Runner.xcodeproj
2. Select "Targets-Runner" → Build Settings Tab
3. Navigate to the Deployment category
4. Set "Strip Linked Product" to **"No"**
5. Set "Strip Style" to **"Non-Global-Symbols"**

*Solution found at: https://github.com/gtbluesky/onnxruntime_flutter/issues/24#issuecomment-2419096341*

### Android Issues

#### Echo Cancellation Not Working on Some Android Devices

Some Android devices, particularly Samsung devices (e.g., Samsung S20), may experience issues with echo cancellation not functioning properly, while the same code works fine on other devices (e.g., Lenovo Tab M8).

**Fix:** Configure Android-specific audio settings in the RecordConfig. The VAD package uses improved audio configuration by default, but you can also customize it:

```dart
await _vadHandler.startListening(
  recordConfig: const RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 16000,
    numChannels: 1,
    echoCancel: true,
    noiseSuppress: true,
    autoGain: true,
    androidConfig: AndroidRecordConfig(
      audioSource: AndroidAudioSource.voiceCommunication,
      audioManagerMode: AudioManagerMode.modeInCommunication,
      speakerphone: true,
      manageBluetooth: true,
    ),
  ),
);
```

This configuration leverages `AudioManager.MODE_IN_COMMUNICATION` and speakerphone mode along with the `android.permission.MODIFY_AUDIO_SETTINGS` permission to resolve echo cancellation issues. The VAD package uses these settings by default.

## Tested Platforms
The VAD Package has been tested on the following platforms:

- **iOS:**  Tested on iPhone 15 Pro Max running iOS 18.1.
- **Android:**  Tested on Lenovo Tab M8 running Android 10, Samsung S20 running Android 15.
- **Web:**  Tested on Chrome Mac/Windows/Android/iOS, Safari Mac/iOS.
- **macOS:**  Tested on macOS Sequoia 15.1.
- **Windows:**  Tested on Windows 11.
- **Linux:**  Tested on Ubuntu 24.04.

## Contributing
Contributions are welcome! Please feel free to submit a pull request or open an issue if you encounter any problems or have suggestions for improvements.

## Acknowledgements
Special thanks to [Ricky0123](https://github.com/ricky0123) for creating the [VAD JavaScript library](https://github.com/ricky0123/vad), the Silero Team for the [VAD model](https://github.com/snakers4/silero-vad) used in the library, and Microsoft for the [ONNX Runtime](https://github.com/microsoft/onnxruntime) that powers the model inference.


## License
This project is licensed under the [MIT License](https://opensource.org/license/mit). See the [LICENSE](https://github.com/keyur2maru/vad/blob/master/LICENSE)  file for details.

---

For any issues or contributions, please visit the [GitHub repository](https://github.com/keyur2maru/vad).