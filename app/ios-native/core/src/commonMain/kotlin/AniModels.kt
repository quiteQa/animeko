/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.iosnative.core

// 跨越 Swift 边界的值类型. 只使用 String / Int / Long / Boolean / List / Map 与本文件中的类型,
// 不暴露 app-data 的任何类型, 以便上游改动时只需调整 Mappers.kt.

/**
 * 条目摘要, 用于搜索结果与条目详情头部.
 *
 * @param airDate `yyyy-M-d`, 未知时为空字符串.
 */
data class AniSubject(
    val id: Int,
    val name: String,
    val nameCn: String,
    val displayName: String,
    val imageUrl: String,
    val summary: String,
    val airDate: String,
    val totalEpisodes: Int,
    val nsfw: Boolean,
)

/**
 * @param sort 剧集在条目中的序号, 如 `1`, `12.5`, `SP1`.
 * @param watched 当前用户是否已看过 (未登录时为 `false`).
 */
data class AniEpisode(
    val id: Int,
    val sort: String,
    val displayName: String,
    val airDate: String,
    val watched: Boolean,
)

data class AniSubjectDetail(
    val subject: AniSubject,
    val episodes: List<AniEpisode>,
)

/**
 * 一个可供选择的资源.
 *
 * @param kind `WEB`, `BitTorrent` 或 `LocalCache`.
 * @param playable iOS 端能否解析播放. BT 资源在 iOS 上没有本地引擎, 只有配置了云离线时才可播放.
 */
data class AniMediaCandidate(
    val mediaId: String,
    val mediaSourceId: String,
    val title: String,
    val episodeName: String,
    val resolution: String,
    val alliance: String,
    val subtitleLanguages: List<String>,
    val kind: String,
    val playable: Boolean,
)

/**
 * 数据源查询进度.
 *
 * @param completed 已结束查询 (成功, 失败或被放弃) 的数据源数量.
 * @param total 已启用的数据源数量.
 */
data class AniFetchProgress(
    val completed: Int,
    val total: Int,
    val candidateCount: Int,
)

data class AniSubtitle(
    val url: String,
    val language: String?,
    val mimeType: String?,
)

/**
 * 已解析的可播放地址. Swift 侧用它创建 `AVURLAsset`, [headers] 通过 `AVURLAssetHTTPHeaderFieldsKey` 传入.
 */
data class AniPlayable(
    val url: String,
    val headers: Map<String, String>,
    val subtitles: List<AniSubtitle>,
    val title: String,
)

enum class AniDanmakuLocation {
    NORMAL,
    TOP,
    BOTTOM,
}

/**
 * @param color `0xRRGGBB`.
 */
data class AniDanmaku(
    val id: String,
    val timeMillis: Long,
    val text: String,
    val color: Int,
    val location: AniDanmakuLocation,
)
