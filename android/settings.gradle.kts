pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")

val fontAsset = file("../assets/fonts/MiSans-VF.ttf")
if (!fontAsset.isFile) {
    val localFont = System.getenv("MISANS_FONT_PATH")?.let { file(it) }
    require(localFont != null && localFont.isFile) {
        "请从 https://hyperos.mi.com/font/download 获取 MiSans 可变 TTF，并通过 MISANS_FONT_PATH 指定字体文件。"
    }
    localFont.copyTo(fontAsset)
}
