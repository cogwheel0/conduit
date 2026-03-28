# Flutter ProGuard rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }
-dontwarn io.flutter.embedding.**

# Keep your app's classes
-keep class app.cogwheel.qonduit.** { *; }

# Keep Gson and JSON serialization
-keepattributes Signature
-keepattributes *Annotation*
-keep class sun.misc.Unsafe { *; }
-keep class com.google.gson.stream.** { *; }

# Keep WebSocket functionality
-keep class org.java_websocket.** { *; }
-dontwarn org.java_websocket.**

# Keep Flutter CallKit Incoming classes
-keep class com.hiennv.flutter_callkit_incoming.** { *; }
