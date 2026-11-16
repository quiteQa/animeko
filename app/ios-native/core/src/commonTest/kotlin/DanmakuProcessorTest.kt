/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.iosnative.core

import kotlinx.coroutines.test.runTest
import me.him188.ani.app.domain.danmaku.DanmakuTextConversionSettings
import me.him188.ani.danmaku.api.DanmakuContent
import me.him188.ani.danmaku.api.DanmakuInfo
import me.him188.ani.danmaku.api.DanmakuLocation
import me.him188.ani.danmaku.api.DanmakuServiceId
import me.him188.ani.danmaku.api.provider.DanmakuFetchResult
import me.him188.ani.danmaku.api.provider.DanmakuMatchInfo
import me.him188.ani.danmaku.api.provider.DanmakuMatchMethod
import me.him188.ani.danmaku.api.provider.DanmakuProviderId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class DanmakuProcessorTest {
    private val serviceId = DanmakuServiceId("test")

    private fun danmaku(id: String, time: Long, text: String) = DanmakuInfo(
        id = id,
        serviceId = serviceId,
        senderId = "sender",
        content = DanmakuContent(playTimeMillis = time, color = 0xFFFFFF, text = text, location = DanmakuLocation.NORMAL),
    )

    private fun result(vararg list: DanmakuInfo) = DanmakuFetchResult(
        providerId = DanmakuProviderId("test"),
        matchInfo = DanmakuMatchInfo(serviceId, list.size, DanmakuMatchMethod.NoMatch),
        list = list.toList(),
    )

    @Test
    fun `sanitize trims whitespace and control characters`() {
        assertEquals("hello", sanitizeDanmakuText("  hel\u0007lo \n"))
        assertNull(sanitizeDanmakuText(" \u0000 "))
        assertNull(sanitizeDanmakuText(""))
    }

    @Test
    fun `process drops blank danmaku applies regex filters and sorts by time`() = runTest {
        val processed = DanmakuProcessor().process(
            results = listOf(
                result(danmaku("1", 3000, "third"), danmaku("2", 1000, "  first  ")),
                result(danmaku("3", 2000, "spoiler alert"), danmaku("4", 1500, "   ")),
            ),
            textConversion = DanmakuTextConversionSettings.Default,
            regexFilters = listOf("SPOILER"),
        )
        assertEquals(listOf("first", "third"), processed.map { it.text })
    }
}
