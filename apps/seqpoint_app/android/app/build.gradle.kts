import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名配置。文件不入库（见 .gitignore），所以：
// - 本机有 key.properties 时，release 用正式签名；
// - 没有时（新克隆的仓库、CI 未注入密钥）回退到 debug 签名，
//   保证 `flutter run --release` 之类的命令仍然可用，只是产物不能上架。
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseSigning = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.seqpoint.seqpoint_app"
    // receive_sharing_intent 需要 37；compileSdk 向后兼容，取各插件的最高要求。
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 用到了 java.time 等新 API，
        // 在低版本 Android 上必须靠 desugaring 兜底，否则构建直接失败。
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.seqpoint.app"
        // 设计文档定的下限：Android 8.0。同时满足各插件要求
        // （flutter_local_notifications 24、flutter_secure_storage 23）。
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                // v1 是给 Android 7 以下用的旧方案，minSdk 26 用不到；
                // v2/v3 覆盖全部目标版本，v3 还支持将来轮换密钥。
                enableV1Signing = false
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                // 没有密钥时用 debug 签名，能构建但不能上架。
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
