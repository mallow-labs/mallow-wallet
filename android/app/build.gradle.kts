import java.util.Properties
import java.io.FileInputStream
import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The Cast receiver id, out of the same `--dart-define` Dart reads.
//
// Android cannot take it from Dart the way iOS does: the Cast SDK instantiates
// `CastOptionsProvider` itself, from the class name in AndroidManifest.xml,
// before any Dart has run. So the value has to be in the manifest by the time
// the APK is assembled — hence a placeholder resolved here.
//
// Flutter hands Gradle every `--dart-define` as the `dart-defines` property: a
// comma-joined list of base64 `KEY=VALUE` pairs. Decoding it keeps ONE source
// of configuration (.env) rather than adding a second Gradle-only mechanism a
// fork would have to discover.
//
// Keep the fallback in step with `kDefaultCastReceiverAppId` in
// lib/core/config/environment.dart — two languages, one value, and no build
// step that can check them against each other.
val castReceiverAppId: String = run {
    val fallback = "3B14DCF8"
    if (!project.hasProperty("dart-defines")) return@run fallback
    project.property("dart-defines").toString()
        .split(",")
        .asSequence()
        .mapNotNull { entry ->
            // A malformed entry must not fail the build for an optional knob.
            runCatching { String(Base64.getDecoder().decode(entry.trim())) }.getOrNull()
        }
        .firstOrNull { it.startsWith("CAST_RECEIVER_APP_ID=") }
        ?.substringAfter("=")
        ?.takeIf { it.isNotBlank() }
        ?: fallback
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        load(FileInputStream(keystorePropertiesFile))
    }
}

android {
    namespace = "com.mallow.wallet.android"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.mallow.wallet.android"
        // web3auth_flutter (social sign-in) requires API 26 (Android 8.0);
        // Flutter's default floor is 24.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["castReceiverAppId"] = castReceiverAppId
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Falls back to debug signing when key.properties is absent so
            // local `flutter run --release` still works without the upload key.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Flutter ≥3.29 verifies the release AAB carries libflutter.so.sym
            // (or .dbg) under BUNDLE-METADATA/com.android.tools.build.debugsymbols/
            // and aborts with "Release app bundle failed to strip debug symbols
            // from native libraries" otherwise. AGP only emits those files when
            // debugSymbolLevel is set explicitly — opt in here.
            ndk {
                debugSymbolLevel = "SYMBOL_TABLE"
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.biometric:biometric:1.1.0")
    // Google Cast SDK — required for Chromecast support
    implementation("com.google.android.gms:play-services-cast-framework:21.5.0")
}
