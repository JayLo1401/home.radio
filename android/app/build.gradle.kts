import java.util.Properties

// Release-Signatur: android/key.properties (z. B. in CI aus Secrets erzeugt), sonst der
// gemeinsame Schluessel aller jaycloud-Apps im Ordner "keystore" neben dem Projekt
// (D:\github_private\keystore, nicht im Git), sonst der Debug-Schluessel.
val signingProps = listOf(
    rootProject.file("key.properties"),
    rootProject.file("../../keystore/signing.properties"),
).firstOrNull { it.exists() }?.let { f -> Properties().apply { f.inputStream().use { load(it) } } }

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "at.jaycloud.home.radio"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "at.jaycloud.home.radio"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
            }
        }
    }

    // Our own DAB+ receiver (src/main/cpp/hrdab).
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    signingConfigs {
        if (signingProps != null) {
            create("release") {
                storeFile = file(signingProps.getProperty("storeFile"))
                storePassword = signingProps.getProperty("storePassword")
                keyAlias = signingProps.getProperty("keyAlias")
                keyPassword = signingProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (signingProps != null) "release" else "debug")
            // Explicit, so the JNI callback keep rule in proguard-rules.pro
            // is clearly needed (without it R8 strips the callbacks and DAB+
            // playback dies with NoSuchMethodError).
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

