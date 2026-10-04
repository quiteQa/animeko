/*
 * Copyright (C) 2026 OpenAni and contributors.
 * Use of this source code is governed by the GNU AGPLv3 license.
 */

package me.him188.ani.app.ui.adaptive.navigation

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import me.him188.ani.app.ui.foundation.layout.AniWindowInsets
import me.him188.ani.app.ui.foundation.theme.appChromeFrostedGlass

/** 悬浮标签栏, 外层包含安全区域, 其完整高度供页面计算滚动避让. */
@Composable
internal fun IosNavigationBar(
    provider: NavigationSuiteItemProvider,
    glassActive: Boolean,
    containerColor: Color,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(36.dp)
    Box(
        modifier.fillMaxWidth()
            .windowInsetsPadding(AniWindowInsets.forNavigationBar())
            .padding(horizontal = 16.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            Modifier.widthIn(max = 600.dp).fillMaxWidth()
                .shadow(10.dp, shape)
                .clip(shape)
                .appChromeFrostedGlass(glassActive, containerColor)
                .background(if (glassActive) Color.Transparent else containerColor)
                .border(
                    0.5.dp,
                    Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.65f), Color.White.copy(alpha = 0.08f))),
                    shape,
                )
                .selectableGroup()
                .padding(5.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            provider.itemList.forEach { item -> IosNavigationItem(item) }
        }
    }
}

@Composable
private fun RowScope.IosNavigationItem(item: NavigationSuiteItem) {
    val pressed by item.interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.94f else 1f, spring(stiffness = 700f))
    val haptic = LocalHapticFeedback.current
    val foreground = when {
        !item.enabled -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
        item.selected -> MaterialTheme.colorScheme.primary
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    val background by animateColorAsState(
        if (item.selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.12f) else Color.Transparent,
    )
    Column(
        item.modifier.weight(1f)
            .graphicsLayer { scaleX = scale; scaleY = scale }
            .clip(RoundedCornerShape(30.dp))
            .background(background)
            .selectable(
                selected = item.selected,
                enabled = item.enabled,
                role = Role.Tab,
                interactionSource = item.interactionSource,
                indication = null,
                onClick = {
                    if (!item.selected) {
                        haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    }
                    item.activate()
                },
            )
            .heightIn(min = 56.dp)
            .padding(horizontal = 8.dp, vertical = 7.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically),
    ) {
        CompositionLocalProvider(LocalContentColor provides foreground) {
            if (item.badge != null) {
                BadgedBox(badge = { item.badge.invoke() }) { item.icon() }
            } else {
                item.icon()
            }
            if (item.alwaysShowLabel || item.selected) {
                ProvideTextStyle(MaterialTheme.typography.labelSmall) { item.label?.invoke() }
            }
        }
    }
}
