package io.github.sangbinsong.discord_orb

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Foreground service owning the system-wide Discord Orb `TYPE_APPLICATION_OVERLAY`
 * window, collapsed/expanded hit-area updates, screen-off cleanup, and display
 * rotation/bounds clamping.
 */
class OrbOverlayService : Service() {
    private var windowManager: WindowManager? = null
    private var overlayContainer: FrameLayout? = null
    private var collapsedOrbView: View? = null
    private var expandedPanelView: View? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    private var isExpanded: Boolean = false
    private var hasInitializedPosition: Boolean = false
    private var collapsedX: Int = 0
    private var collapsedY: Int = 0
    private var requestedPanelWidthDp: Double = DEFAULT_PANEL_WIDTH_DP
    private var requestedPanelHeightDp: Double = DEFAULT_PANEL_HEIGHT_DP
    private var foregroundStarted: Boolean = false

    private var screenOffReceiver: BroadcastReceiver? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        registerScreenOffWatcher()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureForegroundStarted()

        if (!hasOverlayPermission(this)) {
            cleanupAndStop()
            return START_NOT_STICKY
        }

        when (intent?.action) {
            ACTION_SHOW_COLLAPSED_ORB -> showCollapsedOrbInternal()
            ACTION_EXPAND_PANEL -> {
                val widthDp = intent.getDoubleExtra(EXTRA_WIDTH_DP, DEFAULT_PANEL_WIDTH_DP)
                val heightDp = intent.getDoubleExtra(EXTRA_HEIGHT_DP, DEFAULT_PANEL_HEIGHT_DP)
                expandPanelInternal(widthDp, heightDp)
            }
            ACTION_COLLAPSE_PANEL -> collapsePanelInternal()
            ACTION_HIDE_ORB -> cleanupAndStop()
            else -> showCollapsedOrbInternal()
        }

        return START_NOT_STICKY
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        val wm = windowManager ?: return
        val display = OrbOverlayBounds.currentDisplaySize(this, wm)
        val orbSizePx = orbSizePx()

        if (hasInitializedPosition) {
            val (clampedOrbX, clampedOrbY) = OrbOverlayBounds.clampCoordinates(
                collapsedX,
                collapsedY,
                orbSizePx,
                orbSizePx,
                display,
            )
            collapsedX = clampedOrbX
            collapsedY = clampedOrbY
        }

        val view = overlayContainer ?: return
        val params = layoutParams ?: return
        if (!view.isAttachedToWindow) return

        if (isExpanded) {
            val density = resources.displayMetrics.density
            val requestedW = OrbOverlayBounds.dpToPx(requestedPanelWidthDp, density)
            val requestedH = OrbOverlayBounds.dpToPx(requestedPanelHeightDp, density)
            val rect = OrbOverlayBounds.clampRect(
                params.x,
                params.y,
                requestedW,
                requestedH,
                display,
            )
            params.width = rect.widthPx
            params.height = rect.heightPx
            params.x = rect.x
            params.y = rect.y
        } else {
            val rect = OrbOverlayBounds.clampRect(
                collapsedX,
                collapsedY,
                orbSizePx,
                orbSizePx,
                display,
            )
            params.width = rect.widthPx
            params.height = rect.heightPx
            params.x = rect.x
            params.y = rect.y
        }

        wm.updateViewLayout(view, params)
    }

    override fun onDestroy() {
        unregisterScreenOffWatcher()
        removeOverlayView()
        isRunning = false
        foregroundStarted = false
        super.onDestroy()
    }

    private fun ensureForegroundStarted() {
        if (foregroundStarted) return
        createNotificationChannelIfNeeded()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        foregroundStarted = true
    }

    private fun createNotificationChannelIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Discord Orb Overlay",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps the floating Discord Orb active over other apps."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val contentIntent = PendingIntent.getActivity(this, 0, launchIntent, pendingFlags)
        val iconRes = applicationInfo.icon.takeIf { it != 0 }
            ?: android.R.drawable.ic_dialog_info

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setSmallIcon(iconRes)
            .setContentTitle("Discord Orb")
            .setContentText("Floating orb overlay is active")
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .build()
    }

    private fun ensureOverlayCreated() {
        if (overlayContainer != null && layoutParams != null) return
        val wm = windowManager ?: return
        val display = OrbOverlayBounds.currentDisplaySize(this, wm)
        val orbSizePx = orbSizePx()

        if (!hasInitializedPosition) {
            val marginPx = OrbOverlayBounds.dpToPx(DEFAULT_EDGE_MARGIN_DP, resources.displayMetrics.density)
            val (startX, startY) = OrbOverlayBounds.defaultCollapsedPosition(
                orbSizePx,
                marginPx,
                display,
            )
            collapsedX = startX
            collapsedY = startY
            hasInitializedPosition = true
        }

        val container = FrameLayout(this)
        val orbView = buildCollapsedOrbView()
        val panelView = buildExpandedPanelView()
        panelView.visibility = View.GONE

        container.addView(
            orbView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        container.addView(
            panelView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        attachContainerTouchHandlers(container, orbView)

        val params = createBaseLayoutParams(orbSizePx, orbSizePx, collapsedX, collapsedY)
        wm.addView(container, params)

        overlayContainer = container
        collapsedOrbView = orbView
        expandedPanelView = panelView
        layoutParams = params
    }

    private fun createBaseLayoutParams(
        widthPx: Int,
        heightPx: Int,
        x: Int,
        y: Int,
    ): WindowManager.LayoutParams {
        val windowType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        val flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH

        return WindowManager.LayoutParams(
            widthPx,
            heightPx,
            x,
            y,
            windowType,
            flags,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun attachContainerTouchHandlers(container: FrameLayout, orbView: View) {
        val touchSlop = ViewConfiguration.get(this).scaledTouchSlop
        var downRawX = 0f
        var downRawY = 0f
        var startWindowX = 0
        var startWindowY = 0

        container.setOnTouchListener { _, event ->
            if (isExpanded && event.actionMasked == MotionEvent.ACTION_OUTSIDE) {
                OrbOverlayBridge.notifyPanelDismissRequested()
                return@setOnTouchListener true
            }
            false
        }

        orbView.setOnTouchListener { _, event ->
            if (isExpanded) return@setOnTouchListener false
            val wm = windowManager ?: return@setOnTouchListener false
            val params = layoutParams ?: return@setOnTouchListener false

            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = event.rawX
                    downRawY = event.rawY
                    startWindowX = params.x
                    startWindowY = params.y
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val deltaX = (event.rawX - downRawX).toInt()
                    val deltaY = (event.rawY - downRawY).toInt()
                    val display = OrbOverlayBounds.currentDisplaySize(this, wm)
                    val (clampedX, clampedY) = OrbOverlayBounds.clampCoordinates(
                        startWindowX + deltaX,
                        startWindowY + deltaY,
                        params.width,
                        params.height,
                        display,
                    )
                    params.x = clampedX
                    params.y = clampedY
                    collapsedX = clampedX
                    collapsedY = clampedY
                    wm.updateViewLayout(container, params)
                    true
                }
                MotionEvent.ACTION_UP -> {
                    val isClick = OrbOverlayBounds.isTap(
                        event.rawX - downRawX,
                        event.rawY - downRawY,
                        touchSlop,
                    )
                    if (isClick) {
                        expandPanelInternal(requestedPanelWidthDp, requestedPanelHeightDp)
                    }
                    true
                }
                else -> false
            }
        }
    }

    private fun buildCollapsedOrbView(): View {
        val density = resources.displayMetrics.density
        val orbBackground = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.parseColor("#5865F2"))
            setStroke((2f * density).toInt().coerceAtLeast(1), Color.parseColor("#E0E3FF"))
        }

        return TextView(this).apply {
            text = "O"
            textSize = 18f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            background = orbBackground
            contentDescription = "Discord Orb"
        }
    }

    private fun buildExpandedPanelView(): View {
        val density = resources.displayMetrics.density
        val paddingPx = (12f * density).toInt()
        val panelBackground = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = 16f * density
            setColor(Color.parseColor("#1E1F22"))
            setStroke((1f * density).toInt().coerceAtLeast(1), Color.parseColor("#3F4147"))
        }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = panelBackground
            setPadding(paddingPx, paddingPx, paddingPx, paddingPx)
        }

        val headerRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        val titleView = TextView(this).apply {
            text = "Discord Orb"
            textSize = 14f
            setTextColor(Color.WHITE)
            layoutParams = LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.WRAP_CONTENT,
                1f,
            )
        }

        val closeButton = TextView(this).apply {
            text = "Close"
            textSize = 12f
            setTextColor(Color.parseColor("#B5BAC1"))
            setPadding(paddingPx / 2, paddingPx / 4, paddingPx / 2, paddingPx / 4)
            setOnClickListener {
                OrbOverlayBridge.notifyPanelDismissRequested()
            }
        }

        headerRow.addView(titleView)
        headerRow.addView(closeButton)
        root.addView(
            headerRow,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ),
        )

        val bodyView = TextView(this).apply {
            text = "Overlay panel active"
            textSize = 12f
            setTextColor(Color.parseColor("#949BA4"))
            setPadding(0, paddingPx, 0, 0)
        }
        root.addView(bodyView)

        return root
    }

    private fun showCollapsedOrbInternal() {
        ensureOverlayCreated()
        collapsePanelInternal()
    }

    private fun expandPanelInternal(widthDp: Double, heightDp: Double) {
        if (widthDp.isFinite() && widthDp > 0.0) {
            requestedPanelWidthDp = widthDp
        }
        if (heightDp.isFinite() && heightDp > 0.0) {
            requestedPanelHeightDp = heightDp
        }

        ensureOverlayCreated()
        val wm = windowManager ?: return
        val container = overlayContainer ?: return
        val params = layoutParams ?: return

        isExpanded = true
        collapsedOrbView?.visibility = View.GONE
        expandedPanelView?.visibility = View.VISIBLE

        val density = resources.displayMetrics.density
        val display = OrbOverlayBounds.currentDisplaySize(this, wm)
        val requestedW = OrbOverlayBounds.dpToPx(requestedPanelWidthDp, density)
        val requestedH = OrbOverlayBounds.dpToPx(requestedPanelHeightDp, density)
        val rect = OrbOverlayBounds.clampRect(
            collapsedX,
            collapsedY,
            requestedW,
            requestedH,
            display,
        )

        params.width = rect.widthPx
        params.height = rect.heightPx
        params.x = rect.x
        params.y = rect.y

        if (container.isAttachedToWindow) {
            wm.updateViewLayout(container, params)
        }
    }

    private fun collapsePanelInternal() {
        val wm = windowManager ?: return
        val container = overlayContainer ?: return
        val params = layoutParams ?: return

        isExpanded = false
        expandedPanelView?.visibility = View.GONE
        collapsedOrbView?.visibility = View.VISIBLE

        val display = OrbOverlayBounds.currentDisplaySize(this, wm)
        val orbSizePx = orbSizePx()
        val rect = OrbOverlayBounds.clampRect(
            collapsedX,
            collapsedY,
            orbSizePx,
            orbSizePx,
            display,
        )

        collapsedX = rect.x
        collapsedY = rect.y
        params.width = rect.widthPx
        params.height = rect.heightPx
        params.x = rect.x
        params.y = rect.y

        if (container.isAttachedToWindow) {
            wm.updateViewLayout(container, params)
        }
    }

    private fun cleanupAndStop() {
        removeOverlayView()
        if (foregroundStarted) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            foregroundStarted = false
        }
        stopSelf()
    }

    private fun removeOverlayView() {
        val container = overlayContainer ?: return
        try {
            if (container.isAttachedToWindow) {
                windowManager?.removeViewImmediate(container)
            }
        } catch (_: IllegalArgumentException) {
            // View was already detached from WindowManager.
        } finally {
            overlayContainer = null
            collapsedOrbView = null
            expandedPanelView = null
            layoutParams = null
            isExpanded = false
        }
    }

    private fun registerScreenOffWatcher() {
        if (screenOffReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == Intent.ACTION_SCREEN_OFF) {
                    OrbOverlayBridge.notifyLockOrSleep()
                    cleanupAndStop()
                }
            }
        }
        screenOffReceiver = receiver
        OrbOverlayBridge.registerScreenOffReceiver(this, receiver)
    }

    private fun unregisterScreenOffWatcher() {
        val receiver = screenOffReceiver ?: return
        try {
            unregisterReceiver(receiver)
        } catch (_: IllegalArgumentException) {
            // Already unregistered.
        } finally {
            screenOffReceiver = null
        }
    }

    private fun orbSizePx(): Int {
        return OrbOverlayBounds.dpToPx(DEFAULT_ORB_SIZE_DP, resources.displayMetrics.density)
    }

    companion object {
        private const val ACTION_SHOW_COLLAPSED_ORB =
            "io.github.sangbinsong.discord_orb.action.SHOW_COLLAPSED_ORB"
        private const val ACTION_EXPAND_PANEL =
            "io.github.sangbinsong.discord_orb.action.EXPAND_PANEL"
        private const val ACTION_COLLAPSE_PANEL =
            "io.github.sangbinsong.discord_orb.action.COLLAPSE_PANEL"
        private const val ACTION_HIDE_ORB =
            "io.github.sangbinsong.discord_orb.action.HIDE_ORB"

        private const val EXTRA_WIDTH_DP = "extra_width_dp"
        private const val EXTRA_HEIGHT_DP = "extra_height_dp"

        private const val CHANNEL_ID = "discord_orb_overlay"
        private const val NOTIFICATION_ID = 4101

        private const val DEFAULT_ORB_SIZE_DP = 56.0
        private const val DEFAULT_EDGE_MARGIN_DP = 16.0
        private const val DEFAULT_PANEL_WIDTH_DP = 320.0
        private const val DEFAULT_PANEL_HEIGHT_DP = 420.0

        @Volatile
        var isRunning: Boolean = false
            private set

        fun hasOverlayPermission(context: Context): Boolean {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                Settings.canDrawOverlays(context)
            } else {
                true
            }
        }

        fun showCollapsedOrb(context: Context) {
            val intent = Intent(context, OrbOverlayService::class.java).apply {
                action = ACTION_SHOW_COLLAPSED_ORB
            }
            startServiceCompat(context, intent)
        }

        fun expandPanel(context: Context, widthDp: Double, heightDp: Double) {
            val intent = Intent(context, OrbOverlayService::class.java).apply {
                action = ACTION_EXPAND_PANEL
                putExtra(EXTRA_WIDTH_DP, widthDp)
                putExtra(EXTRA_HEIGHT_DP, heightDp)
            }
            startServiceCompat(context, intent)
        }

        fun collapsePanel(context: Context) {
            if (!isRunning) return
            val intent = Intent(context, OrbOverlayService::class.java).apply {
                action = ACTION_COLLAPSE_PANEL
            }
            startServiceCompat(context, intent)
        }

        fun hideOrb(context: Context) {
            if (!isRunning) return
            context.stopService(Intent(context, OrbOverlayService::class.java))
        }

        private fun startServiceCompat(context: Context, intent: Intent) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}
