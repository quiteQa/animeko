/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.iosnative.core

import me.him188.ani.client.models.AniWatchTogetherMember
import me.him188.ani.client.models.AniWatchTogetherMemberState
import me.him188.ani.client.models.AniWatchTogetherWatchingInfo
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class WatchTogetherMappingTest {
    @Test
    fun `resync message describes direction`() {
        assertEquals("已与房主同步", resyncMessage(300))
        assertEquals("已与房主同步 (快进 5 秒)", resyncMessage(5_200))
        assertEquals("已与房主同步 (后退 4 秒)", resyncMessage(-4_400))
    }

    @Test
    fun `member maps online state and watching`() {
        val watching = AniWatchTogetherWatchingInfo(
            subjectId = 1, episodeId = 2, subjectName = "S", episodeSort = "3", episodeName = "E",
            positionMillis = 0, positionAtMillis = 0, durationMillis = 0, paused = true,
            buffering = false, loading = false, playbackRate = 1f,
        )
        val member = AniWatchTogetherMember(
            userId = "u", nickname = "n", isHost = true, following = false,
            state = AniWatchTogetherMemberState.DISCONNECTED, lastSeenAt = 0, watching = watching,
        ).toAniMember()
        assertFalse(member.online)
        assertTrue(member.isHost)
        assertEquals("", member.avatarUrl)
        assertEquals(AniWatchTogetherWatching(1, 2, "S", "3", "E", paused = true), member.watching)
    }
}
