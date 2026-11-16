/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.iosnative.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class OpEdSkipTest {
    private val minute = 60_000L

    @Test
    fun `two points become OP and ED for long video`() {
        val segments = buildSkipSegments(listOf(1_300_000, 90_000), videoLengthMillis = 24 * minute, opEdSkipMillis = 85_000)
        assertEquals(
            listOf(AniSkipSegment("ED", 1_300_000, 85_000), AniSkipSegment("OP", 90_000, 85_000)),
            segments,
        )
    }

    @Test
    fun `medium video uses 55 seconds and other counts are numbered`() {
        val segments = buildSkipSegments(listOf(10_000, 20_000, 30_000), videoLengthMillis = 15 * minute, opEdSkipMillis = 85_000)
        assertEquals(listOf("Ch 1", "Ch 2", "Ch 3"), segments.map { it.name })
        assertEquals(setOf(55_000L), segments.map { it.durationMillis }.toSet())
    }

    @Test
    fun `short video has no segments`() {
        assertEquals(emptyList(), buildSkipSegments(listOf(10_000), videoLengthMillis = 9 * minute, opEdSkipMillis = 85_000))
    }

    @Test
    fun `tracker shows tip before segment and skips at its start`() {
        val tracker = AniSkipTracker(listOf(AniSkipSegment("OP", 90_000, 85_000)))
        assertEquals(-1, tracker.update(80_000))
        assertNull(tracker.pendingSegment)
        assertEquals(-1, tracker.update(86_000)) // 开始前 4 秒: 提示
        assertEquals("OP", tracker.pendingSegment?.name)
        assertEquals(175_000, tracker.update(90_000))
        assertNull(tracker.pendingSegment)
    }

    @Test
    fun `cancelled segment is not skipped`() {
        val tracker = AniSkipTracker(listOf(AniSkipSegment("OP", 90_000, 85_000)))
        tracker.update(86_000)
        tracker.cancel()
        assertNull(tracker.pendingSegment)
        assertEquals(-1, tracker.update(90_000))
    }

    @Test
    fun `segment is skipped only once after seeking back`() {
        val tracker = AniSkipTracker(listOf(AniSkipSegment("OP", 90_000, 85_000)))
        tracker.update(86_000)
        assertEquals(175_000, tracker.update(90_000))
        tracker.update(176_000)
        tracker.update(86_000) // 拖回片段之前
        assertEquals(-1, tracker.update(90_000))
    }
}
