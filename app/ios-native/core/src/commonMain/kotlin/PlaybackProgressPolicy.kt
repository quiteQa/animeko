/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.iosnative.core

import kotlin.math.min
import kotlin.time.Duration.Companion.seconds

/**
 * 播放进度的保存与自动标记看过的规则, 与上游 `RememberPlayProgressExtension` / `MarkAsWatchedExtension` 相同.
 */
internal object PlaybackProgressPolicy {
    /** 时长未知或位置无效时不保存. */
    fun shouldSave(positionMillis: Long, durationMillis: Long): Boolean =
        durationMillis > 0 && positionMillis > 0

    /**
     * 播放位置达到 90% 与结尾前 100 秒中较早的一个时标记看过. 时长不足 10 秒视为数据不正确.
     */
    fun shouldMarkWatched(positionMillis: Long, durationMillis: Long): Boolean {
        if (durationMillis < 10.seconds.inWholeMilliseconds) return false
        val threshold = min(
            (durationMillis.toFloat() * 0.9).toLong(),
            durationMillis - 100.seconds.inWholeMilliseconds,
        )
        return positionMillis >= threshold
    }
}
