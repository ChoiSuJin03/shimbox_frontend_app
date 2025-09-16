import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android") version "2.1.0"
    id("com.google.gms.google-services") // ✅ 여기에만 있어야 함
    id("dev.flutter.flutter-gradle-plugin")
}

repositories {
    google()
    mavenCentral()
    jcenter()
}

android {
    namespace = "com.shimbox.app"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("libs")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = "11"
    }

    defaultConfig {
        applicationId = "com.shimbox.app"
        minSdk = 24
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        create("release") {
            val keystoreProperties = Properties().apply {
                load(File(rootDir, "key.properties").inputStream())
            }
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
        }
    }

    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

repositories {
    flatDir {
        dirs("libs")
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("org.jetbrains.kotlin:kotlin-stdlib:2.1.0")
    implementation ("androidx.fragment:fragment:1.6.2")


    // ✅ Firebase BOM
    implementation(platform("com.google.firebase:firebase-bom:32.7.0"))

    // ✅ Firebase modules
    implementation("com.google.firebase:firebase-auth")
    implementation("com.google.firebase:firebase-analytics")
    implementation("com.google.firebase:firebase-storage")

    // ✅ TMap SDK AAR 연동
    implementation(files("libs/tmap-sdk-2.4.aar"))
    implementation(files("libs/vsm-tmap-sdk-v2-android-1.7.251.aar"))
    implementation("com.google.android.material:material:1.11.0")

    implementation("com.google.android.gms:play-services-location:21.0.1")

}
