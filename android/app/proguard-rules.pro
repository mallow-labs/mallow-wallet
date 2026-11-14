# Flutter engine + plugin entry points
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Google Play Core — referenced reflectively by the deferred-components shim
# even when the app does not use dynamic delivery. Without these rules R8
# strips the classes and the build fails with "missing class" errors.
-keep class com.google.android.play.core.** { *; }
-dontwarn com.google.android.play.core.**

# Release builds write no debug or verbose lines to the system log.
#
# This is not tidiness. The deep-link plugin logs every link it hands to Dart
# at debug level, whole — and links carry secrets: the ID token in the
# fragment of the Sign in with Apple return, the X connect completion token, a
# WalletConnect pairing key. DeepLinkService takes those before anything in
# Dart can log them, which is worth nothing if the plugin already wrote them
# to logcat on the way in (and from there into any bug report).
#
# R8 drops calls to methods declared free of side effects, in every library it
# compiles into the app. Debug builds are not minified and still log.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
}
