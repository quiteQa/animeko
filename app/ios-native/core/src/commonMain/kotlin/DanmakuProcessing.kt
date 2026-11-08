/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.iosnative.core

import me.him188.ani.app.domain.danmaku.DanmakuTextConversionSettings
import me.him188.ani.app.domain.danmaku.DanmakuTextConverter
import me.him188.ani.danmaku.api.DanmakuInfo
import me.him188.ani.danmaku.api.TimeBasedDanmakuSession
import me.him188.ani.danmaku.api.provider.DanmakuFetchResult

/**
 * 把各弹幕源的结果整理为可显示的弹幕, 步骤与上游播放页 (`EpisodeDanmakuLoader`) 相同:
 * 清理文本, 按设置做简繁转换, 应用用户的正则屏蔽词, 最后按时间排序.
 */
internal class DanmakuProcessor(
    private val converter: DanmakuTextConverter = DanmakuTextConverter(),
) {
    suspend fun process(
        results: List<DanmakuFetchResult>,
        textConversion: DanmakuTextConversionSettings,
        regexFilters: List<String>,
    ): List<DanmakuInfo> {
        val converted = results.flatMap { result ->
            val sanitized = result.list.mapNotNull { danmaku ->
                val text = sanitizeDanmakuText(danmaku.text) ?: return@mapNotNull null
                danmaku.copy(content = danmaku.content.copy(text = text))
            }
            converter.convertDanmakuInfos(sanitized, result.matchInfo.serviceId, textConversion)
        }
        return TimeBasedDanmakuSession.filterList(converted, regexFilters)
            .sortedBy { it.playTimeMillis }
    }
}

/**
 * 去掉首尾空白与控制字符; 结果为空时返回 `null` (这条弹幕不显示). 与上游 `EpisodeDanmakuLoader` 的规则相同.
 */
internal fun sanitizeDanmakuText(text: String): String? {
    if (text.isEmpty()) return null
    val result = text
        .trim { it.isWhitespace() || it.isISOControl() }
        .filterNot { it.isISOControl() }
    return result.ifEmpty { null }
}
