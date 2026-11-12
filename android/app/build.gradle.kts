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

// Which push build this is. "play" (the default) delivers push through
// Firebase Cloud Messaging and keeps ML Kit speech recognition. "foss" has no
// Google Play services or Firebase code at all, for F-Droid and IzzyOnDroid.
// Both ship UnifiedPush. A Gradle property rather than product flavors keeps
// `flutter run` and every existing build command working unchanged:
//   flutter build apk -P conduitPushVariant=foss
val conduitPushVariant: String =
    providers.gradleProperty("conduitPushVariant").orNull?.trim()?.lowercase()?.ifEmpty { null }
        ?: "play"
require(conduitPushVariant == "play" || conduitPushVariant == "foss") {
    "conduitPushVariant must be play or foss, not '$conduitPushVariant'"
}
val isPlayBuild = conduitPushVariant == "play"

// The Firebase project the play build registers with. There is no
// google-services.json and no google-services plugin: these four values build
// FirebaseOptions at runtime. Pass them as Gradle properties (-P or
// ~/.gradle/gradle.properties) or environment variables. When any is missing
// the build still succeeds and FCM simply reports itself unavailable.
fun pushSetting(name: String): String =
    (providers.gradleProperty(name).orNull ?: providers.environmentVariable(name).orNull)
        ?.trim()
        .orEmpty()

fun buildConfigString(value: String): String =
    "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

val fcmSettingNames = listOf(
    "CONDUIT_FCM_PROJECT_ID",
    "CONDUIT_FCM_APP_ID",
    "CONDUIT_FCM_API_KEY",
    "CONDUIT_FCM_SENDER_ID",
)

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
        fcmSettingNames.forEach { name ->
            val value = if (isPlayBuild) pushSetting(name) else ""
            buildConfigField("String", name, buildConfigString(value))
        }
        // Flutter adds x86_64 by default for non-split builds. Ship only ARM ABIs.
        // Split builds set their ABIs through --target-platform instead.
        if (providers.gradleProperty("split-per-abi").orNull != "true") {
            ndk {
                abiFilters.clear()
                abiFilters.addAll(listOf("armeabi-v7a", "arm64-v8a"))
            }
        }
    }

    buildFeatures {
        buildConfig = true
    }

    sourceSets {
        getByName("main") {
            // FCM, ML Kit, or the stand-ins that report them unavailable.
            kotlin.srcDir("src/$conduitPushVariant/kotlin")
        }
        getByName("test") {
            // The shared push test vectors (docs/push/PROTOCOL.md).
            resources.srcDir("../../push/test-vectors")
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
            if (!isPlayBuild) {
                proguardFile("proguard-foss.pro")
            }
        }
        getByName("debug") {
            // signingConfig = signingConfigs.getByName("debug")
            applicationIdSuffix = ".debug"
        }
    }
}

// The play build adds the FCM service and switches Firebase's automatic
// start-up off through a manifest of its own, so the foss manifest never
// mentions Firebase.
androidComponents {
    onVariants { variant ->
        if (isPlayBuild) {
            variant.sources.manifests.addStaticManifestFile("src/play/AndroidManifest.xml")
        }
    }
}

kotlin {
    compilerOptions {
        // Generate JVM bytecode targeting Java 17.
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

configurations.configureEach {
    resolutionStrategy.dependencySubstitution {
        // The UnifiedPush connector depends on plain Tink while
        // flutter_secure_storage brings tink-android; both carry the same
        // classes, so keep only the Android artifact.
        substitute(module("com.google.crypto.tink:tink"))
            .using(module("com.google.crypto.tink:tink-android:1.23.0"))
            .because("tink and tink-android define the same classes")
    }
    if (!isPlayBuild) {
        // Nothing may bring Play services or Firebase into the foss build.
        // geolocator_android declares play-services-location, but checks
        // for it at runtime and falls back to the platform LocationManager.
        exclude(group = "com.google.android.gms")
        exclude(group = "com.google.firebase")
    }
}

dependencies {
    // Core library desugaring for flutter_local_notifications
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.activity:activity:1.12.4")
    implementation("androidx.lifecycle:lifecycle-process:2.10.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    // UnifiedPush ships in both builds. Messages arrive as the raw aes128gcm
    // body; Conduit decrypts them with its own keys.
    implementation("org.unifiedpush.android:connector:3.3.5")
    if (isPlayBuild) {
        implementation("com.google.mlkit:genai-speech-recognition:1.0.0-alpha1")
        // Only Cloud Messaging: no Analytics, no google-services plugin.
        implementation(platform("com.google.firebase:firebase-bom:34.19.0"))
        implementation("com.google.firebase:firebase-messaging")
    }
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.17")
    // Real org.json for JVM unit tests; the mockable android.jar only stubs it.
    testImplementation("org.json:json:20240303")
}

flutter {
    source = "../.."
}
