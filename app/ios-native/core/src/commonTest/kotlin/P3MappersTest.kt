/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.iosnative.core

import me.him188.ani.app.domain.media.cache.MediaCacheState
import me.him188.ani.app.domain.media.cache.engine.MediaCacheEngineKey
import me.him188.ani.app.domain.media.download.DownloadOperation
import me.him188.ani.app.domain.media.download.DownloadSnapshot
import me.him188.ani.app.tools.Progress
import me.him188.ani.datasources.api.EpisodeSort
import me.him188.ani.datasources.api.MediaCacheMetadata
import me.him188.ani.datasources.api.topic.FileSize.Companion.bytes
import kotlin.test.Test
import kotlin.test.assertEquals

class P3MappersTest {
    @Test
    fun `bbcode formatting is stripped`() {
        assertEquals("hello world", bbcodeToPlainText("[b]hello[/b] [i]world[/i]"))
    }

    @Test
    fun `images and stickers become placeholders`() {
        assertEquals("看 [图片] [表情]", bbcodeToPlainText("看 [img]https://example.com/a.png[/img] (bgm38)"))
    }

    @Test
    fun `quote is prefixed`() {
        assertEquals("> 原文\n回复", bbcodeToPlainText("[quote]原文[/quote]回复"))
    }

    @Test
    fun `download snapshot maps metadata and progress`() {
        val snapshot = DownloadSnapshot(
            id = "d1",
            metadata = MediaCacheMetadata(
                subjectId = "100",
                episodeId = "200",
                subjectNameCN = "番剧",
                subjectNames = listOf("Anime"),
                episodeSort = EpisodeSort(3),
                episodeName = "第三话",
            ),
            status = MediaCacheState.IN_PROGRESS,
            progress = Progress.fromZeroToOne(0.5f),
            totalSize = 1000L.bytes,
            downloadSpeed = 10L.bytes,
            canPlay = false,
            mediaSourceId = "source",
            engineKey = MediaCacheEngineKey("http"),
            operation = DownloadOperation.Pause,
        )
        val download = snapshot.toAniDownload()
        assertEquals(100, download.subjectId)
        assertEquals("番剧", download.subjectName)
        assertEquals(200, download.episodeId)
        assertEquals("03", download.episodeSort)
        assertEquals("IN_PROGRESS", download.state)
        assertEquals(0.5f, download.progress)
        assertEquals(1000L, download.totalBytes)
        assertEquals(true, download.busy)
    }
}
