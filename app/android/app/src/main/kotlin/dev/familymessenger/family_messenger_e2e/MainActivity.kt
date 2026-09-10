package dev.familymessenger.family_messenger_e2e

import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
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
