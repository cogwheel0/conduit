import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "app.cogwheel.conduit"
    compileSdk = 37
    ndkVersion = "29.0.14206865"

    defaultConfig {
        applicationId = "app.cogwheel.conduit"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Flutter adds x86_64 by default for non-split builds. Ship only ARM ABIs.
        // Split builds set their ABIs through --target-platform instead.
        if (providers.gradleProperty("split-per-abi").orNull != "true") {
            ndk {
                abiFilters.clear()
                abiFilters.addAll(listOf("armeabi-v7a", "arm64-v8a"))
            }
        }
    }

    compileOptions {
        // Align with modern Android Gradle Plugin requirements
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Enable core library desugaring for flutter_local_notifications
        isCoreLibraryDesugaringEnabled = true
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        getByName("release") {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        // Explicit measurement builds can update the existing debug install
        // without creating a second app/account or changing shipped identity.
        getByName("profile") {
            if (providers.gradleProperty("conduitProfileExistingInstall").orNull == "true") {
                applicationIdSuffix = ".debug"
            }
        }
        getByName("debug") {
            // signingConfig = signingConfigs.getByName("debug")
            applicationIdSuffix = ".debug"
        }
    }
}

kotlin {
    compilerOptions {
        // Generate JVM bytecode targeting Java 17.
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("net.java.dev.jna:jna:5.17.0@aar")
    // Core library desugaring for flutter_local_notifications
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.activity:activity:1.12.4")
    implementation("com.google.mlkit:genai-speech-recognition:1.0.0-alpha1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.17")
    // Real org.json for JVM unit tests; the mockable android.jar only stubs it.
    testImplementation("org.json:json:20240303")
}

// Never package a local-voice call with missing native/model assets.
val verifyPhononPack by tasks.registering {
    group = "verification"
    description = "Verifies the pinned local Zoey voice assets before packaging"
    doLast {
        val required = listOf(
            "src/main/jniLibs/arm64-v8a/libptts_ffi.so",
            "src/main/assets/phonon/model.q8.gguf",
            "src/main/assets/phonon/config.json",
            "src/main/assets/phonon/tokenizer.json",
            "src/main/assets/phonon/voices/NbpkqMVS3CJeq2j8.safetensors",
            "src/main/assets/phonon/LICENSE-APACHE",
            "src/main/assets/phonon/ATTRIBUTION.txt",
        )
        check(required.all { file(it).isFile }) {
            "Phonon Zoey assets are missing. Run scripts/voice/build_phonon_android.sh from the project root."
        }
    }
}
tasks.named("preBuild").configure { dependsOn(verifyPhononPack) }

flutter {
    source = "../.."
}
