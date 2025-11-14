import java.util.Properties
import java.io.File

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android") version "2.1.0"
    id("com.google.gms.google-services")
    id("dev.flutter.flutter-gradle-plugin")
}

repositories {
    // 필요시 유지 (일부 플러그인/로컬 aar)
    google()
    mavenCentral()
    jcenter()
}

android {
    namespace = "com.shimbox.app"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    // (선택) jniLibs 위치
    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("libs")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
    kotlinOptions { jvmTarget = "21" }

    defaultConfig {
        applicationId = "com.shimbox.app"
        minSdk = 26
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        // ✅ 기본으로 존재하는 debug를 "수정"만 합니다 (이름을 새로 만들지 않음!)
        getByName("debug") {
            storeFile = file("C:/Users/txtlo/shimbox_frontend_app/android/app/upload-keystore.jks")
            storePassword = "947264"
            keyAlias = "upload"
            keyPassword = "947264"
        }
        // ✅ release만 새로 생성 (key.properties 사용)
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
        getByName("debug") {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
        }
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

repositories {
    // 로컬 AAR 등 사용할 때
    flatDir { dirs("libs") }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("org.jetbrains.kotlin:kotlin-stdlib:2.1.0")
    implementation("androidx.fragment:fragment:1.6.2")

    // Firebase BOM & modules
    implementation(platform("com.google.firebase:firebase-bom:32.7.0"))
    implementation("com.google.firebase:firebase-auth")
    implementation("com.google.firebase:firebase-analytics")
    implementation("com.google.firebase:firebase-storage")

    // Health Connect
    implementation("androidx.health.connect:connect-client:1.2.0-alpha02")

    // lifecycleScope
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")

    // Wear Data Layer (폰 수신 리스너용)
    implementation("com.google.android.gms:play-services-wearable:18.2.0")
}
