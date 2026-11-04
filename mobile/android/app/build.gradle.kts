import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Eigener Signaturschlüssel (android/key.properties, wird von GitHub Actions aus Secrets erzeugt).
// Ohne Schlüssel wird mit dem Debug-Schlüssel signiert – dann lassen sich Updates nicht über
// eine bestehende Installation spielen.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

android {
    namespace = "de.selfify.selfify"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Vom Update-Plugin (ota_update) verlangt: neuere Java-APIs auch auf älteren Android-Versionen
        isCoreLibraryDesugaringEnabled = true
    }

    signingConfigs {
        if (keyProperties.containsKey("storeFile")) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    // Zwei Versionen der App (Befehl: flutter build apk --flavor full / flutter build appbundle --flavor play):
    //  full – GitHub-Version (APK): alles, auch YouTube-Downloads und Selbst-Update.
    //  play – Google-Play-Version: ohne YouTube-Funktionen und ohne Selbst-Update (Play-Richtlinien),
    //         dafür mit Song-Wünschen, Premium und Werbung. Eigene Kennung, damit sie sich neben der
    //         GitHub-Version installieren lässt (die ist mit einem anderen Schlüssel signiert).
    flavorDimensions += "channel"
    productFlavors {
        create("full") {
            dimension = "channel"
        }
        create("play") {
            dimension = "channel"
            applicationIdSuffix = ".play"
        }
    }

    defaultConfig {
        applicationId = "de.selfify.selfify"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // AdMob-App-ID (aus dem AdMob-Konto, Form ca-app-pub-1234567890123456~1234567890). Ohne Angabe gilt die
        // Test-ID von Google – so zeigt die App nur gekennzeichnete Test-Anzeigen. Gesetzt wird sie beim Bauen
        // über die Umgebungsvariable ORG_GRADLE_PROJECT_admobAppId (siehe docs/PLAYSTORE.md).
        manifestPlaceholders["admobAppId"] =
            (project.findProperty("admobAppId") as String?)?.takeIf { it.isNotBlank() }
                ?: "ca-app-pub-3940256099942544~3347511713"
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
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

dependencies {
    // Gleiche Version wie im Update-Plugin (ota_update 7.1.0)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
