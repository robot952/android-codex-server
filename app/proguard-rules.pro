-keep class com.jcraft.jsch.** { *; }
-dontwarn org.bouncycastle.**
-keepattributes Signature,*Annotation*

# JSch and AndroidX Security share artifacts with optional desktop integrations. These classes are
# not used by the SSH/password/private-key paths in this app (GSS, Pageant/JNA, desktop logging),
# but R8 still sees their references in the common jars.
-dontwarn com.google.errorprone.annotations.**
-dontwarn com.sun.jna.**
-dontwarn javax.annotation.**
-dontwarn org.apache.logging.log4j.**
-dontwarn org.ietf.jgss.**
-dontwarn org.newsclub.net.unix.**
-dontwarn org.slf4j.**
