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
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PlaybackProgressPolicyTest {
    private val minute = 60_000L

    @Test
    fun `does not save without duration or position`() {
        assertFalse(PlaybackProgressPolicy.shouldSave(positionMillis = 1000, durationMillis = 0))
        assertFalse(PlaybackProgressPolicy.shouldSave(positionMillis = 0, durationMillis = 24 * minute))
        assertTrue(PlaybackProgressPolicy.shouldSave(positionMillis = 1000, durationMillis = 24 * minute))
    }

    @Test
    fun `long episode is watched at 90 percent`() {
        val duration = 24 * minute // 90% = 1296 s, earlier than 100 s before the end
        assertFalse(PlaybackProgressPolicy.shouldMarkWatched(1_295_999, duration))
        assertTrue(PlaybackProgressPolicy.shouldMarkWatched(1_296_000, duration))
    }

    @Test
    fun `short video is watched 100 seconds before the end`() {
        val duration = 5 * minute // 100 s before the end = 200 s, earlier than 90%
        assertFalse(PlaybackProgressPolicy.shouldMarkWatched(199_999, duration))
        assertTrue(PlaybackProgressPolicy.shouldMarkWatched(200_000, duration))
    }

    @Test
    fun `video shorter than 10 seconds is never marked`() {
        assertFalse(PlaybackProgressPolicy.shouldMarkWatched(9_000, 9_000))
    }
}
