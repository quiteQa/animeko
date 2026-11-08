/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.iosnative.core

import me.him188.ani.app.data.models.episode.EpisodeCollectionInfo
import me.him188.ani.app.data.models.episode.displayName
import me.him188.ani.app.data.models.subject.SubjectInfo
import me.him188.ani.danmaku.api.DanmakuInfo
import me.him188.ani.danmaku.api.DanmakuLocation
import me.him188.ani.datasources.api.Media
import me.him188.ani.datasources.api.PackedDate
import me.him188.ani.datasources.api.topic.UnifiedCollectionType
import org.openani.mediamp.source.UriMediaData

// app-data 类型到 facade 值类型的映射. 上游改动数据模型时, 只需要改这个文件.

internal fun SubjectInfo.toAniSubject(): AniSubject = AniSubject(
    id = subjectId,
    name = name,
    nameCn = nameCn,
    displayName = displayName,
    imageUrl = imageLarge,
    summary = summary,
    airDate = airDate.toAniDateString(),
    totalEpisodes = totalEpisodes,
    nsfw = nsfw,
)

internal fun EpisodeCollectionInfo.toAniEpisode(): AniEpisode = AniEpisode(
    id = episodeId,
    sort = episodeInfo.sort.toString(),
    displayName = episodeInfo.displayName,
    airDate = episodeInfo.airDate.toAniDateString(),
    watched = collectionType == UnifiedCollectionType.DONE,
)

internal fun Media.toAniMediaCandidate(playable: Boolean): AniMediaCandidate = AniMediaCandidate(
    mediaId = mediaId,
    mediaSourceId = mediaSourceId,
    title = originalTitle,
    episodeName = properties.episodeName.orEmpty(),
    resolution = properties.resolution,
    alliance = properties.alliance,
    subtitleLanguages = properties.subtitleLanguageIds,
    kind = kind.name,
    playable = playable,
)

internal fun UriMediaData.toAniPlayable(title: String): AniPlayable = AniPlayable(
    url = uri,
    headers = headers,
    subtitles = extraFiles.subtitles.map {
        AniSubtitle(url = it.uri, language = it.language, mimeType = it.mimeType)
    },
    title = title,
)

internal fun DanmakuInfo.toAniDanmaku(): AniDanmaku = AniDanmaku(
    id = id,
    timeMillis = playTimeMillis,
    text = text,
    color = color,
    location = when (location) {
        DanmakuLocation.TOP -> AniDanmakuLocation.TOP
        DanmakuLocation.BOTTOM -> AniDanmakuLocation.BOTTOM
        DanmakuLocation.NORMAL -> AniDanmakuLocation.NORMAL
    },
)

internal fun PackedDate.toAniDateString(): String = if (isValid) "$year-$month-$day" else ""
