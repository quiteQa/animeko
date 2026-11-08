/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

import org.jetbrains.kotlin.gradle.ExperimentalKotlinGradlePluginApi
import org.jetbrains.kotlin.gradle.plugin.cocoapods.CocoapodsExtension

// SwiftUI 原生客户端的 Kotlin facade, 以 CocoaPods 产出 AniCore.framework.
// Swift 只能看到本模块的公开 API (transitiveExport = false), 上游 app-data 的 API 变动只影响这里.
// 结构与边界见 app/ios-native/README.md.

plugins {
    id("ani.kmp-library")
}

kotlin {
    android {
        namespace = "me.him188.ani.app.iosnative.core"
    }
    sourceSets.commonMain.dependencies {
        // Koin 装配 (getCommonKoinModule / getIosModules) 位于 application 模块, 直接复用而不复制.
        implementation(projects.app.shared.application)
        implementation(projects.app.shared.appData)
        implementation(projects.app.shared.appPlatform)
        implementation(projects.utils.bbcode)
        implementation(libs.kotlinx.coroutines.core)
        implementation(libs.koin.core)
    }
    sourceSets.commonTest.dependencies {
        implementation(libs.kotlinx.coroutines.test)
    }
}

// 原生依赖与 :app:shared:application 的 iOS framework 相同: application 的 klib 引用了 Sentry, onnxruntime
// 与 MediampFFmpegKit, 链接 AniCore 时必须提供它们. cinterop 已由上游模块生成, 这里只链接 (linkOnly).
kotlin {
    if (enableIos && buildIosFramework && getOs() == Os.MacOS) {
        extensions.configure<CocoapodsExtension> {
            name = "AniCore"
            summary = "Kotlin facade for the Animeko SwiftUI client"
            framework {
                baseName = "AniCore"
                isStatic = false
                @OptIn(ExperimentalKotlinGradlePluginApi::class)
                transitiveExport = false
            }
            pod("Sentry") {
                version = "~> 8.49.0"
                linkOnly = true
            }
            pod("onnxruntime-objc") {
                version = libs.versions.onnxruntime.get()
                linkOnly = true
            }
        }

        val httpDownloaderProject = project(":utils:http-downloader")
        listOf(iosArm64(), iosSimulatorArm64()).forEach { target ->
            val capitalizedTargetName = target.name.replaceFirstChar { it.uppercase() }
            val sliceName = when (target.name) {
                "iosArm64" -> "ios-arm64"
                "iosSimulatorArm64" -> "ios-arm64-simulator"
                else -> error("Unsupported Apple target: ${target.name}")
            }
            val ffmpegSearchPath = httpDownloaderProject.layout.buildDirectory
                .dir("mediamp-ffmpeg/apple-runtime/MediampFFmpegKit.xcframework/$sliceName")
                .get().asFile.absolutePath
            val onnxSliceName = when (target.name) {
                "iosArm64" -> "ios-arm64"
                "iosSimulatorArm64" -> "ios-arm64_x86_64-simulator"
                else -> error("Unsupported Apple target: ${target.name}")
            }
            val onnxSearchPath = layout.buildDirectory
                .dir("cocoapods/synthetic/ios/Pods/onnxruntime-c/onnxruntime.xcframework/$onnxSliceName")
                .get().asFile.absolutePath

            target.binaries.configureEach {
                linkerOpts("-F$ffmpegSearchPath", "-framework", "MediampFFmpegKit")
                linkerOpts(
                    "-F$onnxSearchPath", "-framework", "onnxruntime",
                    "-lc++", "-weak_framework", "CoreML",
                )
            }

            tasks.matching { task ->
                task.name.startsWith("link") && task.name.endsWith(capitalizedTargetName)
            }.configureEach {
                dependsOn(":utils:http-downloader:extractMediampFfmpegAppleRuntime")
                dependsOn("podInstallSyntheticIos")
            }
        }
    }
}
