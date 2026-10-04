/*
 * Copyright (C) 2026 OpenAni and contributors.
 * Use of this source code is governed by the GNU AGPLv3 license.
 */

package me.him188.ani.app.ui.foundation.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** iOS 风格的中性分层表面, 保留用户选择的强调色和系统动态配色. */
fun iosColorScheme(base: ColorScheme, isDark: Boolean, useBlackBackground: Boolean): ColorScheme {
    val background = when {
        isDark && useBlackBackground -> Color.Black
        isDark -> Color(0xFF0C0C0E)
        else -> Color(0xFFF2F2F7)
    }
    val surface = if (isDark) Color(0xFF1C1C1E) else Color.White
    val secondarySurface = if (isDark) Color(0xFF2C2C2E) else Color(0xFFE5E5EA)
    val foreground = if (isDark) Color(0xFFF5F5F7) else Color(0xFF1C1C1E)
    val secondaryForeground = if (isDark) Color(0xFFAEAEB2) else Color(0xFF636366)
    return base.copy(
        background = background,
        onBackground = foreground,
        surface = surface,
        onSurface = foreground,
        surfaceVariant = secondarySurface,
        onSurfaceVariant = secondaryForeground,
        surfaceContainerLowest = background,
        surfaceContainerLow = surface,
        surfaceContainer = surface,
        surfaceContainerHigh = secondarySurface,
        surfaceContainerHighest = if (isDark) Color(0xFF3A3A3C) else Color(0xFFD1D1D6),
        surfaceBright = if (isDark) secondarySurface else surface,
        surfaceDim = background,
        surfaceTint = Color.Transparent,
        outline = if (isDark) Color(0xFF636366) else Color(0xFF8E8E93),
        outlineVariant = if (isDark) Color(0xFF38383A) else Color(0xFFC6C6C8),
    )
}

val IosShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(16.dp),
    large = RoundedCornerShape(24.dp),
    extraLarge = RoundedCornerShape(32.dp),
)

/** 保留平台字体, 让中文、动态字号和辅助功能沿用 Compose 的字体缩放. */
fun Typography.withIosTypeScale(): Typography = copy(
    headlineLarge = headlineLarge.copy(fontSize = 34.sp, lineHeight = 41.sp, fontWeight = FontWeight.Bold),
    headlineMedium = headlineMedium.copy(fontSize = 28.sp, lineHeight = 34.sp, fontWeight = FontWeight.Bold),
    headlineSmall = headlineSmall.copy(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.Bold),
    titleLarge = titleLarge.copy(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.Bold),
    titleMedium = titleMedium.copy(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold),
    bodyLarge = bodyLarge.copy(fontSize = 17.sp, lineHeight = 24.sp),
    bodyMedium = bodyMedium.copy(fontSize = 15.sp, lineHeight = 22.sp),
    labelLarge = labelLarge.copy(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold),
    labelSmall = labelSmall.copy(fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.Medium),
)
