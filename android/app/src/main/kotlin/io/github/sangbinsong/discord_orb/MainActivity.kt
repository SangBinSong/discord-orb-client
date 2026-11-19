package io.github.sangbinsong.discord_orb

import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Main Flutter host activity wiring Android overlay window control
 * (`discord_orb/window`) and Discord OAuth callback deep links
 * (`discord_orb/auth_links`).
 */
class MainActivity : FlutterActivity() {
    private var windowChannel: MethodChannel? = null
    private var authLinksChannel: MethodChannel? = null
    private var pendingInitialAuthLink: String? = null
    private var screenOffReceiver: BroadcastReceiver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingInitialAuthLink = extractAuthCallbackUri(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val window = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WINDOW_CHANNEL_NAME,
        )
        window.setMethodCallHandler(::handleWindowCall)
        OrbOverlayBridge.attachWindowChannel(window)
        windowChannel = window

        val authLinks = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AUTH_LINKS_CHANNEL_NAME,
        )
        authLinks.setMethodCallHandler(::handleAuthLinkCall)
        authLinksChannel = authLinks

        registerActivityScreenOffWatcher()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        val uriString = extractAuthCallbackUri(intent) ?: return
        val channel = authLinksChannel
        if (channel != null) {
            channel.invokeMethod("onLink", uriString)
        } else {
            pendingInitialAuthLink = uriString
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        unregisterActivityScreenOffWatcher()

        windowChannel?.let { channel ->
            channel.setMethodCallHandler(null)
            OrbOverlayBridge.detachWindowChannel(channel)
        }
        windowChannel = null

        authLinksChannel?.setMethodCallHandler(null)
        authLinksChannel = null

        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun handleWindowCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasOverlayPermission" -> {
                result.success(OrbOverlayService.hasOverlayPermission(this))
            }
            "openOverlayPermissionSettings" -> {
                openOverlayPermissionSettings(result)
            }
            "showCollapsedOrb" -> {
                if (!OrbOverlayService.hasOverlayPermission(this)) {
                    result.error(
                        "OVERLAY_PERMISSION_DENIED",
                        "SYSTEM_ALERT_WINDOW permission is required to show the overlay.",
                        null,
                    )
                    return
                }
                OrbOverlayService.showCollapsedOrb(this)
                result.success(null)
            }
            "expandPanel" -> {
                if (!OrbOverlayService.hasOverlayPermission(this)) {
                    result.error(
                        "OVERLAY_PERMISSION_DENIED",
                        "SYSTEM_ALERT_WINDOW permission is required to expand the overlay.",
                        null,
                    )
                    return
                }
                val widthDp = call.argument<Number>("width")?.toDouble()
                val heightDp = call.argument<Number>("height")?.toDouble()
                if (widthDp == null ||
                    heightDp == null ||
                    !widthDp.isFinite() ||
                    !heightDp.isFinite() ||
                    widthDp <= 0.0 ||
                    heightDp <= 0.0
                ) {
                    result.error(
                        "INVALID_ARGUMENTS",
                        "expandPanel requires positive finite width and height.",
                        null,
                    )
                    return
                }
                OrbOverlayService.expandPanel(this, widthDp, heightDp)
                result.success(null)
            }
            "collapsePanel" -> {
                OrbOverlayService.collapsePanel(this)
                result.success(null)
            }
            "hideOrb" -> {
                OrbOverlayService.hideOrb(this)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleAuthLinkCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getInitialLink" -> {
                val initialLink = pendingInitialAuthLink
                pendingInitialAuthLink = null
                result.success(initialLink)
            }
            else -> result.notImplemented()
        }
    }

    private fun openOverlayPermissionSettings(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.success(null)
            return
        }

        val packageSpecificIntent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:$packageName"),
        )
        try {
            startActivity(packageSpecificIntent)
            result.success(null)
            return
        } catch (_: ActivityNotFoundException) {
            // Fall back to the generic overlay settings screen when OEMs reject package URIs.
        }

        try {
            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION))
            result.success(null)
        } catch (err: ActivityNotFoundException) {
            result.error(
                "SETTINGS_UNAVAILABLE",
                "Overlay permission settings screen is unavailable on this device.",
                err.message,
            )
        }
    }

    private fun registerActivityScreenOffWatcher() {
        if (screenOffReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == Intent.ACTION_SCREEN_OFF && !OrbOverlayService.isRunning) {
                    OrbOverlayBridge.notifyLockOrSleep()
                }
            }
        }
        screenOffReceiver = receiver
        OrbOverlayBridge.registerScreenOffReceiver(this, receiver)
    }

    private fun unregisterActivityScreenOffWatcher() {
        val receiver = screenOffReceiver ?: return
        try {
            unregisterReceiver(receiver)
        } catch (_: IllegalArgumentException) {
            // Already unregistered.
        } finally {
            screenOffReceiver = null
        }
    }

    private fun extractAuthCallbackUri(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val uri = intent.data ?: return null
        if (uri.scheme != AUTH_SCHEME) return null
        if (uri.host != AUTH_HOST) return null
        val path = uri.path ?: return null
        if (!path.startsWith(AUTH_CALLBACK_PATH_PREFIX)) return null
        return uri.toString()
    }

    companion object {
        private const val WINDOW_CHANNEL_NAME = "discord_orb/window"
        private const val AUTH_LINKS_CHANNEL_NAME = "discord_orb/auth_links"
        private const val AUTH_SCHEME = "discordorb"
        private const val AUTH_HOST = "auth"
        private const val AUTH_CALLBACK_PATH_PREFIX = "/callback"
    }
}
