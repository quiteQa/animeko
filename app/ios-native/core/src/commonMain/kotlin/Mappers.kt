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
import me.him188.ani.app.data.models.subject.ContinueWatchingStatus
import me.him188.ani.app.data.models.subject.SubjectCollectionInfo
import me.him188.ani.app.data.models.subject.SubjectInfo
import me.him188.ani.app.domain.media.fetch.MediaSourceFetchState
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

internal fun UnifiedCollectionType.toAni(): AniCollectionType = when (this) {
    UnifiedCollectionType.WISH -> AniCollectionType.WISH
    UnifiedCollectionType.DOING -> AniCollectionType.DOING
    UnifiedCollectionType.DONE -> AniCollectionType.DONE
    UnifiedCollectionType.ON_HOLD -> AniCollectionType.ON_HOLD
    UnifiedCollectionType.DROPPED -> AniCollectionType.DROPPED
    UnifiedCollectionType.NOT_COLLECTED -> AniCollectionType.NOT_COLLECTED
}

internal fun AniCollectionType.toUnified(): UnifiedCollectionType = when (this) {
    AniCollectionType.WISH -> UnifiedCollectionType.WISH
    AniCollectionType.DOING -> UnifiedCollectionType.DOING
    AniCollectionType.DONE -> UnifiedCollectionType.DONE
    AniCollectionType.ON_HOLD -> UnifiedCollectionType.ON_HOLD
    AniCollectionType.DROPPED -> UnifiedCollectionType.DROPPED
    AniCollectionType.NOT_COLLECTED -> UnifiedCollectionType.NOT_COLLECTED
}

internal fun SubjectCollectionInfo.toAniSubjectDetail(): AniSubjectDetail = AniSubjectDetail(
    subject = subjectInfo.toAniSubject(),
    episodes = episodes.map { it.toAniEpisode() },
    collectionType = collectionType.toAni(),
    nextEpisodeId = progressInfo.nextEpisodeIdToPlay,
)

internal fun SubjectCollectionInfo.toAniCollectionItem(): AniCollectionItem {
    val (kind, episode) = when (val status = progressInfo.continueWatchingStatus) {
        is ContinueWatchingStatus.Start -> AniContinueKind.NOT_STARTED to ""
        is ContinueWatchingStatus.NotOnAir -> AniContinueKind.NOT_ON_AIR to status.airDate.toAniDateString()
        is ContinueWatchingStatus.Continue -> AniContinueKind.IN_PROGRESS to (status.episodeSort?.toString() ?: "")
        is ContinueWatchingStatus.Watched -> AniContinueKind.CAUGHT_UP to (status.episodeSort?.toString() ?: "")
        is ContinueWatchingStatus.Done -> AniContinueKind.COMPLETED to ""
    }
    return AniCollectionItem(
        subject = subjectInfo.toAniSubject(),
        collectionType = collectionType.toAni(),
        nextEpisodeId = progressInfo.nextEpisodeIdToPlay,
        continueKind = kind,
        continueEpisode = episode,
    )
}

internal fun MediaSourceFetchState.toAniStateName(): String = when (this) {
    MediaSourceFetchState.Idle -> "IDLE"
    MediaSourceFetchState.Working -> "WORKING"
    MediaSourceFetchState.Disabled -> "DISABLED"
    is MediaSourceFetchState.Succeed -> "SUCCEED"
    is MediaSourceFetchState.Failed -> "FAILED"
    is MediaSourceFetchState.CaptchaRequired -> "CAPTCHA_REQUIRED"
    is MediaSourceFetchState.RateLimited -> "RATE_LIMITED"
    is MediaSourceFetchState.Abandoned -> "ABANDONED"
    else -> this::class.simpleName.orEmpty().uppercase()
}
