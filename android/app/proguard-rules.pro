# No app-wide keep rules are required. Android components are retained from
# the merged manifest, Flutter plugins are referenced by the generated plugin
# registrant, and libraries supply their own consumer rules where needed.
#
# Keep additions here narrowly scoped to code reached through reflection or
# JNI. Package-wide rules prevent R8 from shrinking, optimizing, or obfuscating
# otherwise eligible release code.

# Phonon C ABI mapping and callback fields are accessed by JNA reflection.
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class app.cogwheel.conduit.phonon.PhononTTS$Result { *; }
-dontwarn java.awt.**
