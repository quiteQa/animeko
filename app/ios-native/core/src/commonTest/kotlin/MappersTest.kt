/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.iosnative.core

import me.him188.ani.danmaku.api.DanmakuContent
import me.him188.ani.danmaku.api.DanmakuInfo
import me.him188.ani.danmaku.api.DanmakuLocation
import me.him188.ani.danmaku.api.DanmakuServiceId
import me.him188.ani.datasources.api.PackedDate
import org.openani.mediamp.source.MediaExtraFiles
import org.openani.mediamp.source.Subtitle
import org.openani.mediamp.source.UriMediaData
import kotlin.test.Test
import kotlin.test.assertEquals

class MappersTest {
    @Test
    fun `valid date is formatted as year-month-day`() {
        assertEquals("2024-4-7", PackedDate(2024, 4, 7).toAniDateString())
    }

    @Test
    fun `invalid date is empty`() {
        assertEquals("", PackedDate.Invalid.toAniDateString())
    }

    @Test
    fun `danmaku keeps time text color and location`() {
        val info = DanmakuInfo(
            id = "1",
            serviceId = DanmakuServiceId("test"),
            senderId = "sender",
            content = DanmakuContent(
                playTimeMillis = 12_345,
                color = 0xFF0000,
                text = "hello",
                location = DanmakuLocation.TOP,
            ),
        )
        assertEquals(
            AniDanmaku(
                id = "1",
                timeMillis = 12_345,
                text = "hello",
                color = 0xFF0000,
                location = AniDanmakuLocation.TOP,
            ),
            info.toAniDanmaku(),
        )
    }

    @Test
    fun `uri media data carries headers and subtitles`() {
        val data = UriMediaData(
            uri = "https://example.com/video.m3u8",
            headers = mapOf("Referer" to "https://example.com/"),
            extraFiles = MediaExtraFiles(
                subtitles = listOf(Subtitle(uri = "https://example.com/zh.ass", mimeType = null, language = "CHS")),
            ),
        )
        assertEquals(
            AniPlayable(
                url = "https://example.com/video.m3u8",
                headers = mapOf("Referer" to "https://example.com/"),
                subtitles = listOf(AniSubtitle(url = "https://example.com/zh.ass", language = "CHS", mimeType = null)),
                title = "title",
            ),
            data.toAniPlayable("title"),
        )
    }
}
