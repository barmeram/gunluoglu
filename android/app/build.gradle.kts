// key.properties dosyasını okumak için GEREKLİ importlar
import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// android/key.properties içeriğini oku (yoksa sorun çıkarmaz)
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.omerb.gunluogluproje"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Sende olduğu gibi Java 11 bırakıyoruz
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.omerb.gunluogluproje"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // --- YENİ: RELEASE imzalama ayarı (key.properties'ten okur) ---
    signingConfigs {
        create("release") {
            // key.properties DOSYANDA şunlar olacak:
            // storePassword=189018
            // keyPassword=189018
            // keyAlias=my-key-alias
            // storeFile=C:/Users/omerb/my-release-key.jks
            keyAlias = (keystoreProperties["keyAlias"] as String?)
            keyPassword = (keystoreProperties["keyPassword"] as String?)
            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = (keystoreProperties["storePassword"] as String?)
        }
    }

    buildTypes {
        getByName("release") {
            // Eskiden debug anahtarı vardı; şimdi gerçek release imzasını kullan
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
        // debug tipine dokunmuyoruz
    }
}

flutter {
    source = "../.."
}
