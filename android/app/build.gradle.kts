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

// The dApp Store artifact is signed with its OWN key, never the Play upload
// key. Solana Mobile's publishing docs require it: "You cannot use the same
// signing key for both Google Play and the dApp Store." Play App Signing means
// our upload key is already not the certificate Play distributes, so reusing it
// would arguably satisfy the intent — but the rule is written against the key
// you hold, and a rejected review costs a multi-day round trip. Two keys, no
// argument.
//
// Losing this keystore means the dApp Store listing can never be updated again:
// the store matches the App NFT to the package name AND the signing cert.
val dappstoreKeystorePropertiesFile = rootProject.file("dappstore-key.properties")
val dappstoreKeystoreProperties = Properties().apply {
    if (dappstoreKeystorePropertiesFile.exists()) {
        load(FileInputStream(dappstoreKeystorePropertiesFile))
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

    // Two distribution channels, two package names.
    //
    // `dappstore` targets the Solana dApp Store (Seeker). It reuses the legacy
    // `art.mallow.twa` id because the dApp Store App NFT is keyed to the
    // package name and we update that listing rather than mint a new one.
    //
    // A separate id — not an `applicationIdSuffix` — is load-bearing. The dApp
    // Store cannot take the Play-distributed certificate (Play App Signing
    // holds it; ours is the upload key), so the two artifacts are signed
    // differently. Under one shared id that would make them mutually
    // uninstallable, and for a wallet "uninstall to continue" destroys the
    // Keychain/Keystore entries behind MnemonicVault with `allowBackup=false`
    // and no restore path. Two ids let both builds coexist.
    //
    // `namespace` above stays `com.mallow.wallet.android` on purpose:
    // namespace is the R/BuildConfig package and the resolution root for the
    // manifest's relative class names, and it is independent of applicationId.
    // Changing it would move every Kotlin source file for no benefit.
    //
    // google-services.json at android/app/ registers BOTH packages, so one
    // file serves both flavours and no per-flavour copy is needed.
    flavorDimensions += "store"

    // Declared BEFORE productFlavors on purpose: the Kotlin DSL evaluates these
    // blocks top-to-bottom, and the dappstore flavour resolves its signing
    // config by name. Move this below and the build dies with
    // "SigningConfig with name 'dappstore' not found".
    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
        create("dappstore") {
            if (dappstoreKeystorePropertiesFile.exists()) {
                keyAlias = dappstoreKeystoreProperties["keyAlias"] as String
                keyPassword = dappstoreKeystoreProperties["keyPassword"] as String
                storeFile = file(dappstoreKeystoreProperties["storeFile"] as String)
                storePassword = dappstoreKeystoreProperties["storePassword"] as String
            }
        }
    }

    // Release signing is chosen HERE, per flavour, not in buildTypes.release.
    //
    // AGP resolves a variant's signing config from the build type FIRST and only
    // falls back to the flavour, so a `signingConfig` set on buildTypes.release
    // silently wins over anything a flavour asks for — the dApp Store artifact
    // would go out signed with the Play upload key and nothing would say so.
    // The debug build type keeps its own implicit debug config, which by that
    // same precedence still wins for debug builds of either flavour. That is
    // what we want: debug stays debug-signed, release takes the flavour's key.
    productFlavors {
        create("play") {
            dimension = "store"
            // applicationId inherited from defaultConfig.
            // Falls back to debug signing when key.properties is absent so a
            // local `flutter run --release` still works without the upload key.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
        create("dappstore") {
            dimension = "store"
            applicationId = "art.mallow.twa"
            // Its OWN key, never the Play upload key — see the keystore comment
            // at the top of this file.
            signingConfig = if (dappstoreKeystorePropertiesFile.exists())
                signingConfigs.getByName("dappstore")
            else
                signingConfigs.getByName("debug")
        }
    }

    buildTypes {
        release {
            // No signingConfig here on purpose — it is set per flavour above,
            // because a build type's config takes precedence over a flavour's
            // and would override the dApp Store key.
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
    // Solana Mobile Seed Vault. Ships in BOTH flavours on purpose: the feature
    // is gated at runtime on SeedVault.isAvailable(), so the play and dappstore
    // artifacts differ only in identity and signing and store QA transfers
    // between them. The AAR contributes its own <queries> block and the
    // ACCESS_SEED_VAULT uses-permission through manifest merging.
    implementation("com.solanamobile:seedvault-wallet-sdk:0.4.0")
}
