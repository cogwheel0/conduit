#flutter_callkit_incoming
# Issue: https://github.com/hiennguyen92/flutter_callkit_incoming/issues/171
-keep class com.fasterxml.** { *; }
-dontwarn com.fasterxml.jackson.**

-keepattributes *Annotation*

-keepclassmembers class * {
    @com.fasterxml.jackson.annotation.* <fields>;
    @com.fasterxml.jackson.annotation.* <methods>;
}

-keepclassmembers class * {
    public <init>();
}

-keep class com.hiennv.flutter_callkit_incoming.** { *; }