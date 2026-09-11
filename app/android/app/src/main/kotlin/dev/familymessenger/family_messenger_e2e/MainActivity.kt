package dev.familymessenger.family_messenger_e2e

import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /** Owns an update install; the activity feeds it the lifecycle it needs. */
    private val updates by lazy { ApkInstaller(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Starts and stops the foreground service that screen sharing needs
        // (see ScreenShareService); the Dart side owns the order of the steps.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "family_messenger/screen_share").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> startScreenShareService(call.argument<String>("title"), call.argument<String>("text"), result)
                "stop" -> {
                    ScreenShareService.onReady = null
                    stopService(Intent(this, ScreenShareService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // Installs the release the Dart updater downloaded. Windows and Linux
        // replace their own files; here only the package manager may, so the
        // APK is handed to it (see ApkInstaller).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "family_messenger/updater").setMethodCallHandler { call, result ->
            when (call.method) {
                "canInstall" -> result.success(updates.canInstall())
                "openInstallSettings" -> {
                    updates.openInstallSettings()
                    result.success(null)
                }
                "installApk" -> installUpdate(call.argument<String>("path"), result)
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Answers only when the package manager has spoken, which can be minutes
     * later: the user reads its confirmation screen in between. A confirmed
     * install kills this process first, so the Dart side simply never sees the
     * call return.
     */
    private fun installUpdate(path: String?, result: MethodChannel.Result) {
        if (path == null) {
            result.error(ApkInstaller.ERR_FAILED, "no file to install", null)
            return
        }
        var answered = false
        updates.install(path) { code, message ->
            if (!answered) {
                answered = true
                try {
                    if (code == null) result.success(null) else result.error(code, message, null)
                } catch (e: Exception) {
                    // The engine can be gone by now, and an answer to nobody throws.
                    Log.w(ApkInstaller.TAG, "nobody left to hear the install verdict: $e")
                }
            }
        }
    }

    // The system's install confirmation is an activity, and Android 10+ drops
    // one started from the background, so the installer opens it only while
    // this activity is in front.
    override fun onResume() {
        super.onResume()
        updates.onResumed()
    }

    override fun onPause() {
        updates.onPaused()
        super.onPause()
    }

    /**
     * Answers only once the service runs in the foreground: startForegroundService
     * returns before that, and a capture started in between is refused.
     */
    private fun startScreenShareService(title: String?, text: String?, result: MethodChannel.Result) {
        val handler = Handler(Looper.getMainLooper())
        var answered = false
        val finish = { ok: Boolean ->
            if (!answered) {
                answered = true
                ScreenShareService.onReady = null
                if (ok) result.success(null) else result.error("screen_share_service", "the screen sharing service did not start", null)
            }
        }
        ScreenShareService.onReady = { ok -> finish(ok) }
        handler.postDelayed({ finish(false) }, 5000)
        val intent = Intent(this, ScreenShareService::class.java)
            .putExtra(ScreenShareService.EXTRA_TITLE, title)
            .putExtra(ScreenShareService.EXTRA_TEXT, text)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
        } catch (e: Exception) {
            finish(false)
        }
    }
}
