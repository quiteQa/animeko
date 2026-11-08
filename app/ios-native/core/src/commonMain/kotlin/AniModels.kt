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

/**
 * @param collectionType 当前用户对条目的收藏状态.
 * @param nextEpisodeId 下一集要看的剧集, 没有时为 `null`.
 */
data class AniSubjectDetail(
    val subject: AniSubject,
    val episodes: List<AniEpisode>,
    val collectionType: AniCollectionType,
    val nextEpisodeId: Int?,
)

enum class AniCollectionType {
    WISH,
    DOING,
    DONE,
    ON_HOLD,
    DROPPED,
    NOT_COLLECTED,
}

/**
 * 收藏列表中的一项.
 *
 * @param continueKind 续看状态, 决定 [continueEpisode] 的含义.
 * @param continueEpisode [AniContinueKind.IN_PROGRESS] 时为下一集序号, [AniContinueKind.CAUGHT_UP] 时为看到的序号,
 * [AniContinueKind.NOT_ON_AIR] 时为开播日期, 其他为空字符串.
 */
data class AniCollectionItem(
    val subject: AniSubject,
    val collectionType: AniCollectionType,
    val nextEpisodeId: Int?,
    val continueKind: AniContinueKind,
    val continueEpisode: String,
)

// 枚举名避开 Swift / Objective-C 关键字 (如 continue), 否则导出时会被改名.
enum class AniContinueKind {
    /** 还没看过任何一集 */
    NOT_STARTED,

    /** 尚未开播 */
    NOT_ON_AIR,

    /** 看到一半, 还有已播出的下一集 */
    IN_PROGRESS,

    /** 已看完全部已播出的剧集, 等待更新 */
    CAUGHT_UP,

    /** 全部看完 */
    COMPLETED,
}

/**
 * 登录状态.
 *
 * @param loggedIn 是否已登录 Ani 账号.
 * @param bangumiConnected 是否已绑定 Bangumi, 收藏与进度同步需要绑定.
 */
data class AniSession(
    val loggedIn: Boolean,
    val bangumiConnected: Boolean,
    val nickname: String,
    val avatarUrl: String,
)

/**
 * 一个数据源在本次查询中的状态.
 *
 * @param state `IDLE`, `WORKING`, `SUCCEED`, `FAILED`, `DISABLED`, `CAPTCHA_REQUIRED`, `RATE_LIMITED`, `ABANDONED`.
 * @param resultCount 该数据源为本条目找到的资源数 (不按剧集筛选).
 */
data class AniMediaSourceStatus(
    val instanceId: String,
    val mediaSourceId: String,
    val displayName: String,
    val kind: String,
    val state: String,
    val resultCount: Int,
)

/**
 * 选源偏好的一个维度.
 *
 * @param key [AniPreferenceKeys] 中的常量.
 * @param available 当前候选资源中出现过的取值.
 * @param selected 生效的取值 (用户选择或默认偏好), 没有时为 `null`.
 */
data class AniPreference(
    val key: String,
    val available: List<String>,
    val selected: String?,
)

object AniPreferenceKeys {
    const val ALLIANCE = "alliance"
    const val RESOLUTION = "resolution"
    const val SUBTITLE_LANGUAGE = "subtitleLanguage"
    const val MEDIA_SOURCE = "mediaSource"
}

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

// region P3: 探索, 评论, 设置, 缓存

/**
 * 时间表中的一天.
 *
 * @param date `yyyy-MM-dd`, 用户所在时区.
 */
data class AniScheduleDay(
    val date: String,
    val items: List<AniScheduleItem>,
)

/**
 * @param airingTimeMillis 放送时刻 (epoch 毫秒). [timeKnown] 为 `false` 时只有日期准确.
 */
data class AniScheduleItem(
    val subjectId: Int,
    val subjectName: String,
    val imageUrl: String,
    val episodeId: Int,
    val episodeSort: String,
    val episodeName: String,
    val airingTimeMillis: Long,
    val timeKnown: Boolean,
)

/**
 * 一条评论或评价. [text] 是由 BBCode 转换的纯文本: 图片显示为 `[图片]`, 表情显示为 `[表情]`, 引用以 `> ` 开头.
 *
 * @param rating 条目评价的评分 (1-10), 剧集评论或未评分为 0.
 */
data class AniComment(
    val id: String,
    val authorName: String,
    val authorAvatarUrl: String,
    val createdAtMillis: Long,
    val text: String,
    val rating: Int,
    val replies: List<AniComment>,
    val replyCount: Int,
)

/**
 * @param nextCursor 下一页的游标 (剧集评论) 或偏移 (条目评价, 十进制字符串); 没有更多时为 `null`.
 */
data class AniCommentPage(
    val items: List<AniComment>,
    val nextCursor: String?,
)

/**
 * iOS 客户端提供的设置项. 写入通过 [AniSettingsStore] 的对应方法.
 *
 * @param hlsAdFiltering `ALL`, `SMART` 或 `OFF`.
 * @param danmakuTextConversion `ORIGINAL`, `SIMPLIFIED`, `TRADITIONAL`, `TAIWAN` 或 `HONG_KONG`.
 * @param nsfwMode `HIDE`, `BLUR` 或 `DISPLAY`.
 * @param opEdSkipSeconds 手动跳过 OP/ED 按钮一次跳过的秒数, 也是长视频自动跳过片段的长度.
 * @param rememberManualSelection 手动查找点选剧集时是否 "记住选择", 之后每集按记住的线路自动选择.
 */
data class AniSettings(
    val preferWebSources: Boolean,
    val fastSelectWeb: Boolean,
    val autoEnableLastSelected: Boolean,
    val hlsAdFiltering: String,
    val autoMarkDone: Boolean,
    val danmakuEnabled: Boolean,
    val danmakuShowTop: Boolean,
    val danmakuShowBottom: Boolean,
    val danmakuShowFloating: Boolean,
    val danmakuShowColor: Boolean,
    val danmakuTextConversion: String,
    val nsfwMode: String,
    val autoSkipOpEd: Boolean,
    val opEdSkipSeconds: Int,
    val autoPlayNext: Boolean,
    val rememberManualSelection: Boolean,
)

/**
 * 一个已配置的数据源实例.
 */
data class AniMediaSourceItem(
    val instanceId: String,
    val mediaSourceId: String,
    val displayName: String,
    val kind: String,
    val enabled: Boolean,
)

data class AniDanmakuFilter(
    val id: String,
    val name: String,
    val regex: String,
    val enabled: Boolean,
)

/**
 * 一个缓存 (下载) 任务.
 *
 * @param state `IN_PROGRESS`, `PAUSED`, `FAILED` 或 `COMPLETED`.
 * @param progress 0 到 1, 未知时为 -1.
 * @param busy 是否有暂停, 继续或删除操作正在执行.
 */
data class AniDownload(
    val id: String,
    val subjectId: Int,
    val subjectName: String,
    val episodeId: Int,
    val episodeSort: String,
    val episodeName: String,
    val mediaSourceId: String,
    val state: String,
    val progress: Float,
    val totalBytes: Long,
    val speedBytesPerSecond: Long,
    val canPlay: Boolean,
    val busy: Boolean,
)

// endregion

// region 手动查找

/**
 * 支持浏览的数据源.
 */
data class AniBrowseSource(
    val instanceId: String,
    val mediaSourceId: String,
    val displayName: String,
)

/**
 * @param defaultInstanceId 默认选中的数据源: 本条目浏览记忆的源, 其次是本条目记忆的 Web 源, 否则第一个. 没有数据源时为 `null`.
 * @param defaultKeyword 默认搜索关键字 (条目名).
 */
data class AniBrowseSources(
    val sources: List<AniBrowseSource>,
    val defaultInstanceId: String?,
    val defaultKeyword: String,
)

/**
 * 站点上的一个条目. [url] 是它的稳定标识.
 */
data class AniBrowseSubject(
    val name: String,
    val url: String,
)

/**
 * 条目的一条线路. 线路按位置 ([index]) 区分, 名字可以重复或为空.
 *
 * @param preselectedEpisodeIndex 默认预选的剧集 (对应正在观看的一集), 只是提示; 没有时为 -1.
 */
data class AniBrowseChannel(
    val index: Int,
    val label: String,
    val episodes: List<AniBrowseEpisode>,
    val preselectedEpisodeIndex: Int,
)

/**
 * @param sortHint 数据源从名称解析出的集号, 仅供展示; 解析不出为空字符串.
 */
data class AniBrowseEpisode(
    val index: Int,
    val name: String,
    val sortHint: String,
)

/**
 * 浏览请求失败.
 *
 * @param reason [REASON_CAPTCHA_UNSUPPORTED]: 站点要求验证码, iOS 无法交互验证; [REASON_FAILED]: 其他错误.
 */
class AniBrowseException(
    val reason: String,
    message: String?,
    cause: Throwable? = null,
) : Exception(message, cause) {
    companion object {
        const val REASON_CAPTCHA_UNSUPPORTED = "CAPTCHA_UNSUPPORTED"
        const val REASON_FAILED = "FAILED"
    }
}

// endregion
