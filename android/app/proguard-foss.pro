# Release rules for the foss build only (-P conduitPushVariant=foss).
#
# The foss build excludes Google Play services. geolocator_android still
# references its fused location client, but checks for the classes at runtime
# and falls back to the platform LocationManager, so the references are never
# reached.
-dontwarn com.google.android.gms.**
