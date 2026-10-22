# Build the custom Hermes Android app

Use the normal `lib/main.dart` entry point. The compact Hermes interface and local-call voice are part of that app. Development preview and test harness entry points are separate tools.

The local call voice uses pinned Phonon 31M English q8 and the Zoey voice. Model assets and the native inference library are generated locally rather than committed. Install Rust stable, cargo-ndk 4.1.2, and Android NDK 29, then run:

```sh
export ANDROID_NDK_HOME=/path/to/android/ndk/29.0.14206865
bash scripts/voice/build_phonon_android.sh
```

The script builds the pinned native runtime and prepares the model/voice pack. Gradle validates the required pack before building. Android ARM64 is the tested target.

With Flutter dependencies and generated localization sources prepared, build the app with:

```sh
flutter pub get
flutter gen-l10n
flutter build apk --profile --target lib/main.dart --target-platform android-arm64
```

For a deliberate local verification build that updates an existing `app.cogwheel.conduit.debug` installation, set `ORG_GRADLE_PROJECT_conduitProfileExistingInstall=true` for the build and preserve data with `adb install -r`. Otherwise, profile/release builds retain the normal package identity.

The current Auto rename verification and known baseline test failures are described in [the restoration notes](auto-rename-restoration-2026-10-22.md).
