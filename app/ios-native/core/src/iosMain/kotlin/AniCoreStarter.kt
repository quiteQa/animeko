/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.iosnative.core

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.coroutines.Dispatchers
import kotlinx.io.files.SystemFileSystem
import me.him188.ani.app.ios.getIosModules
import me.him188.ani.app.platform.IosContext
import me.him188.ani.app.platform.IosContextFiles
import me.him188.ani.app.platform.createAppRootCoroutineScope
import me.him188.ani.app.platform.getCommonKoinModule
import me.him188.ani.app.platform.startCommonKoinModule
import me.him188.ani.utils.io.SystemCacheDir
import me.him188.ani.utils.io.SystemSupportDir
import me.him188.ani.utils.io.createDirectories
import me.him188.ani.utils.io.resolve
import me.him188.ani.utils.logging.IosLoggingConfigurator
import org.koin.core.context.startKoin
import platform.Foundation.NSCachesDirectory
import platform.Foundation.NSSearchPathForDirectoriesInDomains
import platform.Foundation.NSUserDomainMask
import platform.posix.fclose
import platform.posix.fopen
import platform.posix.fputs
import kotlin.experimental.ExperimentalNativeApi
import kotlin.native.setUnhandledExceptionHook

private var instance: AniClient? = null

/**
 * 启动 Kotlin 侧并返回 [AniClient]. 由 Swift 在 App 启动时于主线程调用一次; 重复调用返回同一实例.
 *
 * Koin 装配复用上游的 `getCommonKoinModule` 与 `getIosModules`, 与 Compose 版 iOS 客户端的数据层完全相同,
 * 但不创建任何 Compose 界面. 音频会话 (`AVAudioSession`) 由 Swift 侧的播放器配置.
 */
fun startAniCore(): AniClient {
    instance?.let { return it }
    installCrashLogHook()

    val scope = createAppRootCoroutineScope()
    val context = IosContext(
        IosContextFiles(
            cacheDir = SystemCacheDir.apply { createDirectories() },
            dataDir = SystemSupportDir.apply { createDirectories() },
        ),
    )
    IosLoggingConfigurator.configure(context.files.logsDir.path, SystemFileSystem)

    val koin = startKoin {
        modules(getCommonKoinModule({ context }, scope))
        modules(getIosModules(context, context.files.dataDir.resolve("torrent"), scope))
    }.startCommonKoinModule(context, scope).koin

    return AniClient(koin, scope, Dispatchers.Main).also { instance = it }
}

/**
 * 未处理的 Kotlin 异常会结束进程. 结束前把异常写入 Swift 侧的诊断日志 (缓存目录的 `diagnostics.log`),
 * 系统没有生成崩溃报告时也能看到原因.
 */
@OptIn(ExperimentalNativeApi::class, ExperimentalForeignApi::class)
private fun installCrashLogHook() {
    val cacheDir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, true).firstOrNull() as? String
        ?: return
    val path = "$cacheDir/diagnostics.log"
    setUnhandledExceptionHook { throwable ->
        val file = fopen(path, "a") ?: return@setUnhandledExceptionHook
        fputs("\n!!! 未处理的 Kotlin 异常\n${throwable.stackTraceToString()}\n", file)
        fclose(file)
    }
}
