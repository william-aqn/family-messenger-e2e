package dev.familymessenger.family_messenger_e2e

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log

/**
 * What Android currently allows this app while it is not on the screen.
 *
 * The messenger holds a WebSocket open for messages and calls, and it has no
 * push service behind it: a phone that puts the app to sleep simply does not
 * ring. Two of the settings that decide this can be read, and both can be put
 * in front of the owner:
 *
 *   - battery optimisation (Doze and App Standby), off by default for every
 *     app, which suspends the socket minutes after the screen goes dark;
 *   - the per-app "Restricted" background setting of Android 9+, which stops
 *     the app outright as soon as it leaves the screen.
 *
 * What cannot be read is the rest: the autostart lists of Xiaomi, Huawei,
 * Oppo and the others live behind vendor screens with no public API. So the
 * app reports the two it knows and claims nothing beyond them.
 */
class BackgroundAccess(private val activity: Activity) {
    /** The two answers, for the settings screen to word. */
    fun state(): Map<String, Any> = mapOf(
        "unrestricted" to unrestricted(),
        "restricted" to restricted(),
    )

    /** Battery optimisation is off for this app, so the socket may stay open. */
    private fun unrestricted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val power = activity.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return true
        return power.isIgnoringBatteryOptimizations(activity.packageName)
    }

    /** The owner (or the phone's maker) set this app to "Restricted". */
    private fun restricted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        val manager = activity.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return false
        return manager.isBackgroundRestricted
    }

    /**
     * The system dialog that turns battery optimisation off for this app —
     * one tap rather than a hunt through a list. Some ROMs answer it with
     * nothing at all, so the list is the fallback.
     */
    fun requestUnrestricted() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || unrestricted()) return
        val ask = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${activity.packageName}"))
        if (!start(ask)) start(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
    }

    /**
     * This app's own page in the system settings, which is where "Restricted"
     * is undone; there is no dialog for that one.
     */
    fun openAppSettings() {
        start(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}")))
    }

    private fun start(intent: Intent): Boolean =
        try {
            activity.startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w(TAG, "no screen for ${intent.action}: $e")
            false
        }

    companion object {
        const val TAG = "BackgroundAccess"
    }
}
