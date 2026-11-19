package io.github.sangbinsong.discord_orb

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * Thread-safe bridge for delivering native overlay lifecycle events back to
 * the Flutter `discord_orb/window` MethodChannel on the main thread.
 */
internal object OrbOverlayBridge {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var windowChannel: MethodChannel? = null

    fun attachWindowChannel(channel: MethodChannel) {
        windowChannel = channel
    }

    fun detachWindowChannel(channel: MethodChannel) {
        if (windowChannel === channel) {
            windowChannel = null
        }
    }

    fun notifyLockOrSleep() {
        invokeOnMain("onLockOrSleep")
    }

    fun notifyPanelDismissRequested() {
        invokeOnMain("onPanelDismissRequested")
    }

    private fun invokeOnMain(method: String) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            windowChannel?.invokeMethod(method, null)
        } else {
            mainHandler.post {
                windowChannel?.invokeMethod(method, null)
            }
        }
    }

    fun registerScreenOffReceiver(context: Context, receiver: BroadcastReceiver) {
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
    }
}
