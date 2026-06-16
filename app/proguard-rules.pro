# Add project specific ProGuard rules here.
# By default, the flags in this file are appended to flags specified
# in proguard-android-optimize.txt (referenced from app/build.gradle.kts).

# Keep our own code intact (it's small) so R8 only shrinks the big libraries.
# This avoids the launch crash caused by R8 stripping app classes (e.g. the
# ViewModel's Application constructor).
-keep class com.tekz.watermark.** { *; }

# Be safe with AndroidX ViewModels created via reflection.
-keepclassmembers class * extends androidx.lifecycle.ViewModel {
    <init>(...);
}
