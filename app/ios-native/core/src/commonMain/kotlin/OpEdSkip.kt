/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.iosnative.core

import kotlin.time.Duration.Companion.minutes

/**
 * 一段可跳过的 OP/ED.
 *
 * @param name `OP`, `ED`, 或 `Ch n` (片段多于两个时).
 */
data class AniSkipSegment(
    val name: String,
    val startMillis: Long,
    val durationMillis: Long,
) {
    val endMillis: Long get() = startMillis + durationMillis
}

/**
 * 由服务器汇总的跳过点 (用户手动跳过的上报统计) 生成跳过片段, 规则与上游播放页相同:
 * 长于 20 分钟的视频每段长 [opEdSkipMillis], 10 到 20 分钟的视频每段 55 秒, 更短的视频不跳过.
 * 恰好两个跳过点时, 较早的是 OP, 较晚的是 ED.
 */
internal fun buildSkipSegments(
    startTimesMillis: List<Long>,
    videoLengthMillis: Long,
    opEdSkipMillis: Long,
): List<AniSkipSegment> {
    val durationMillis = when {
        videoLengthMillis > 20.minutes.inWholeMilliseconds -> opEdSkipMillis
        videoLengthMillis > 10.minutes.inWholeMilliseconds -> 55_000L
        else -> 0L
    }
    if (durationMillis <= 0L) return emptyList()
    return startTimesMillis.mapIndexed { index, start ->
        val name = if (startTimesMillis.size == 2) {
            if (start <= startTimesMillis[1 - index]) "OP" else "ED"
        } else {
            "Ch ${index + 1}"
        }
        AniSkipSegment(name, durationMillis = durationMillis, startMillis = start)
    }
}

/**
 * 播放中自动跳过 OP/ED 的状态机, 与上游 `PlayerSkipOpEdState` 的行为相同 (不含预缓存).
 *
 * Swift 侧约每秒调用一次 [update]: 片段开始前 5 秒起显示提示 ([pendingSegment]), 用户可 [cancel];
 * 播放到片段开头 (1 秒容差内) 时 [update] 返回跳转目标. 每个片段最多自动跳过一次; 离开提示范围后,
 * 未跳过的片段视为已处理, 不会在倒退后再次跳过.
 */
class AniSkipTracker(segments: List<AniSkipSegment>) {
    private class Entry(val segment: AniSkipSegment, var handled: Boolean = false)

    private val entries = segments.map { Entry(it) }
    private var current: Entry? = null

    /** 即将自动跳过的片段; 没有或已取消时为 `null`. */
    val pendingSegment: AniSkipSegment?
        get() = current?.takeUnless { it.handled }?.segment

    /** 取消即将进行的自动跳过. */
    fun cancel() {
        current?.handled = true
    }

    /**
     * @return 需要跳转到的位置 (毫秒); 不需要跳转时为 -1.
     */
    fun update(positionMillis: Long): Long {
        if (entries.isEmpty()) return -1
        val inTipRange = entries.find { it.segment.startMillis in positionMillis - 1000..positionMillis + 5000 }
        if (inTipRange != null) {
            if (current == null) current = inTipRange
        } else {
            current?.handled = true
            current = null
        }
        val entry = current ?: return -1
        if (entry.handled || entry.segment.startMillis !in positionMillis - 1000..positionMillis) return -1
        entry.handled = true
        current = null
        return entry.segment.endMillis
    }
}
