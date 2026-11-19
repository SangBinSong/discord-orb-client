package io.github.sangbinsong.discord_orb

import android.content.Context
import android.os.Build
import android.util.DisplayMetrics
import android.view.WindowManager
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Pure geometry helpers for clamping floating orb and panel bounds within the
 * active display area across configuration and orientation changes.
 */
internal object OrbOverlayBounds {
    data class DisplaySize(val widthPx: Int, val heightPx: Int)
    data class OverlayRect(val x: Int, val y: Int, val widthPx: Int, val heightPx: Int)

    fun dpToPx(dp: Double, density: Float): Int {
        if (!dp.isFinite() || dp <= 0.0) return 1
        return (dp * density).roundToInt().coerceAtLeast(1)
    }

    fun currentDisplaySize(context: Context, windowManager: WindowManager): DisplaySize {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = windowManager.currentWindowMetrics.bounds
            val width = bounds.width().coerceAtLeast(1)
            val height = bounds.height().coerceAtLeast(1)
            return DisplaySize(width, height)
        }
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        windowManager.defaultDisplay?.getRealMetrics(metrics)
        val width = if (metrics.widthPixels > 0) {
            metrics.widthPixels
        } else {
            context.resources.displayMetrics.widthPixels.coerceAtLeast(1)
        }
        val height = if (metrics.heightPixels > 0) {
            metrics.heightPixels
        } else {
            context.resources.displayMetrics.heightPixels.coerceAtLeast(1)
        }
        return DisplaySize(width, height)
    }

    fun clampDimensions(
        requestedWidthPx: Int,
        requestedHeightPx: Int,
        display: DisplaySize,
    ): Pair<Int, Int> {
        val maxWidth = display.widthPx.coerceAtLeast(1)
        val maxHeight = display.heightPx.coerceAtLeast(1)
        val width = requestedWidthPx.coerceIn(1, maxWidth)
        val height = requestedHeightPx.coerceIn(1, maxHeight)
        return width to height
    }

    fun clampCoordinates(
        x: Int,
        y: Int,
        overlayWidthPx: Int,
        overlayHeightPx: Int,
        display: DisplaySize,
    ): Pair<Int, Int> {
        val maxX = (display.widthPx - overlayWidthPx).coerceAtLeast(0)
        val maxY = (display.heightPx - overlayHeightPx).coerceAtLeast(0)
        return x.coerceIn(0, maxX) to y.coerceIn(0, maxY)
    }

    fun clampRect(
        x: Int,
        y: Int,
        requestedWidthPx: Int,
        requestedHeightPx: Int,
        display: DisplaySize,
    ): OverlayRect {
        val (clampedW, clampedH) = clampDimensions(requestedWidthPx, requestedHeightPx, display)
        val (clampedX, clampedY) = clampCoordinates(x, y, clampedW, clampedH, display)
        return OverlayRect(clampedX, clampedY, clampedW, clampedH)
    }

    fun defaultCollapsedPosition(
        orbSizePx: Int,
        marginPx: Int,
        display: DisplaySize,
    ): Pair<Int, Int> {
        val rawX = display.widthPx - orbSizePx - marginPx
        val rawY = (display.heightPx * 0.25).roundToInt()
        return clampCoordinates(rawX, rawY, orbSizePx, orbSizePx, display)
    }

    fun isTap(deltaX: Float, deltaY: Float, touchSlop: Int): Boolean {
        return abs(deltaX) < touchSlop && abs(deltaY) < touchSlop
    }
}
