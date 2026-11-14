/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.iosnative.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import me.him188.ani.app.domain.media.download.DownloadOperation
import me.him188.ani.app.domain.media.download.DownloadOperations
import me.him188.ani.app.domain.media.download.DownloadSnapshot
import me.him188.ani.app.domain.media.download.MediaDownloadManager
import org.koin.core.Koin
import kotlin.coroutines.CoroutineContext

/**
 * 缓存 (下载) 管理. 缓存完成的剧集在播放时以本地缓存数据源出现, 自动选择会优先使用它.
 *
 * 暂停, 继续与删除由上游的 [DownloadOperations] 在应用作用域串行执行, 页面关闭不会中断.
 */
class AniDownloads internal constructor(
    koin: Koin,
    private val scope: CoroutineScope,
    private val callbackContext: CoroutineContext,
) {
    private val manager: MediaDownloadManager = koin.get()
    private val operations: DownloadOperations = koin.get()

    /**
     * 缓存列表. [subjectId] 为 0 时包含所有条目.
     */
    fun downloadUpdates(subjectId: Int): Flow<List<AniDownload>> =
        manager.snapshots(subjectId.takeIf { it != 0 }).map { list -> list.map { it.toAniDownload() } }.forSwift()

    fun pause(ids: List<String>) {
        operations.submit(ids.toSet(), DownloadOperation.Pause)
    }

    fun resume(ids: List<String>) {
        operations.submit(ids.toSet(), DownloadOperation.Resume)
    }

    fun delete(ids: List<String>) {
        operations.submit(ids.toSet(), DownloadOperation.Delete)
    }
}

internal fun DownloadSnapshot.toAniDownload(): AniDownload = AniDownload(
    id = id,
    subjectId = metadata.subjectId.toIntOrNull() ?: 0,
    subjectName = metadata.subjectNameCN?.takeIf { it.isNotBlank() } ?: metadata.subjectNames.firstOrNull().orEmpty(),
    episodeId = metadata.episodeId.toIntOrNull() ?: 0,
    episodeSort = metadata.episodeSort.toString(),
    episodeName = metadata.episodeName,
    mediaSourceId = mediaSourceId,
    state = status.name,
    progress = progress.getOrNull() ?: -1f,
    totalBytes = totalSize.inBytes,
    speedBytesPerSecond = downloadSpeed.inBytes,
    canPlay = canPlay,
    busy = isBusy,
)
