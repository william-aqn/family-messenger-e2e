package dev.familymessenger.family_messenger_e2e

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Foreground service of type mediaProjection. Android 14+ allows screen
 * capture only while one runs, and allows starting it only after the user
 * agreed to the capture, so the Dart side starts it between the consent and
 * getDisplayMedia and stops it when sharing ends. [onReady] tells the
 * activity when the service really is in the foreground: the capture must
 * not start before that.
 */
class ScreenShareService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    @Suppress("DEPRECATION")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Screen sharing", NotificationManager.IMPORTANCE_LOW))
            Notification.Builder(this, CHANNEL)
        } else {
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle(intent?.getStringExtra(EXTRA_TITLE) ?: "Screen sharing")
            .setContentText(intent?.getStringExtra(EXTRA_TEXT) ?: "Family Messenger is sharing your screen")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .build()
        val ready = onReady
        onReady = null
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            ready?.invoke(true)
        } catch (e: Exception) {
            // Without the user's consent Android 14+ refuses the type; the app
            // reports the failure instead of crashing.
            Log.w(TAG, "cannot run as a foreground service: $e")
            ready?.invoke(false)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    companion object {
        const val TAG = "ScreenShareService"
        const val CHANNEL = "screen_share"
        const val NOTIFICATION_ID = 7
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"

        /** Invoked on the main thread once startForeground succeeded (true) or failed (false). */
        var onReady: ((Boolean) -> Unit)? = null
    }
}
