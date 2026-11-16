/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.iosnative.core

import me.him188.ani.app.data.models.UserInfo
import me.him188.ani.app.data.models.episode.EpisodeComment
import me.him188.ani.app.data.models.subject.SubjectReview
import me.him188.ani.utils.bbcode.BBCode
import me.him188.ani.utils.bbcode.RichElement
import me.him188.ani.utils.bbcode.RichText

/**
 * 把 Bangumi / Ani 评论的 BBCode 转为纯文本. 解析失败时返回原文.
 */
internal fun bbcodeToPlainText(bbcode: String): String {
    val rich = try {
        BBCode.parse(bbcode)
    } catch (e: Exception) {
        return bbcode
    }
    return rich.toPlainText().trim()
}

private fun RichText.toPlainText(): String = buildString {
    for (element in elements) {
        when (element) {
            is RichElement.Text -> append(element.value)
            is RichElement.Image -> append("[图片]")
            is RichElement.BangumiSticker -> append("[表情]")
            is RichElement.Kanmoji -> append(element.id)
            is RichElement.Quote -> {
                val quoted = element.contents.toPlainText().trim()
                if (quoted.isNotEmpty()) {
                    if (isNotEmpty() && !endsWith('\n')) append('\n')
                    quoted.lineSequence().forEach { append("> ").append(it).append('\n') }
                }
            }
        }
    }
}

private val UserInfo?.displayName: String
    get() = this?.nickname?.takeIf { it.isNotBlank() } ?: this?.username.orEmpty()

internal fun EpisodeComment.toAniComment(): AniComment = AniComment(
    id = stableId,
    authorName = author.displayName,
    authorAvatarUrl = author?.avatarUrl.orEmpty(),
    createdAtMillis = createdAt,
    text = bbcodeToPlainText(content),
    rating = 0,
    replies = replies.map { it.toAniComment() },
    replyCount = replyCount,
)

internal fun SubjectReview.toAniComment(): AniComment = AniComment(
    id = id.toString(),
    authorName = creator.displayName,
    authorAvatarUrl = creator?.avatarUrl.orEmpty(),
    createdAtMillis = updatedAt,
    text = bbcodeToPlainText(content),
    rating = rating,
    replies = emptyList(),
    replyCount = 0,
)
