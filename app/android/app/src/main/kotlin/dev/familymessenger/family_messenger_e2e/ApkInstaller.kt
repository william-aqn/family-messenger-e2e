package dev.familymessenger.family_messenger_e2e

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

/**
 * Installs a release the Dart updater has already downloaded, replacing this
 * very package. Windows and Linux swap their files in behind a script and
 * start the app again; on Android only the package manager may touch an
 * installed app, so the work here is to hand it the APK and to explain what it
 * answers.
 *
 * The failure that will actually happen is a signing key mismatch: an app is
 * replaced only by a build carrying the same key, and the release APK is
 * signed with whatever keystore built it (app/build.gradle.kts still points
 * the release build at the "debug" config). The certificates are therefore
 * compared here, before a session is opened, so the owner reads "signed with a
 * different key" instead of the system's bare "App not installed".
 */
class ApkInstaller(private val activity: Activity) {
    private val main = Handler(Looper.getMainLooper())

    /** Answers the pending Dart call exactly once; a null code means success. */
    private var done: ((String?, String?) -> Unit)? = null

    /** The system's confirmation screen, held until the app is in front again. */
    private var confirmation: Intent? = null
    private var resumed = false

    /**
     * The session this install is waiting on, and the ones an earlier attempt
     * left behind. Both are needed because a status broadcast says which
     * session it is about, and more than one of ours can speak: abandoning a
     * stale session makes the package manager report it as aborted, and that
     * verdict would otherwise land on the install running now and end it
     * halfway through its own copy. Written on the worker thread, read on the
     * main one.
     */
    @Volatile private var awaited = -1

    @Volatile private var abandoned: Set<Int> = emptySet()

    /**
     * Android 8+ asks per app instead of through one global switch, and the
     * answer can change while the app runs, so it is read afresh every time.
     */
    fun canInstall(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return activity.packageManager.canRequestPackageInstalls()
    }

    /**
     * Opens the screen that grants it. Nothing comes back from there, not even
     * through startActivityForResult, so the app asks [canInstall] again when
     * the user returns and taps Install once more.
     */
    fun openInstallSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))
        } else {
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }
        try {
            activity.startActivity(intent)
        } catch (e: Exception) {
            // A few ROMs ship no per-app screen; the general security settings
            // still carry the switch.
            Log.w(TAG, "no per-app install-sources screen: $e")
            try {
                activity.startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
            } catch (e2: Exception) {
                Log.w(TAG, "no security settings either: $e2")
            }
        }
    }

    /**
     * Checks the download and hands it over. [answer] is called once: with two
     * nulls when the package manager reported success, otherwise with one of
     * the codes the Dart side turns into a sentence. On success the answer
     * usually never arrives — installing an update of the running package
     * kills its processes — which is why Dart must treat a call that never
     * returns as the happy path rather than wait for it.
     */
    fun install(path: String, answer: (String?, String?) -> Unit) {
        // A hand-over whose verdict never arrived — the broadcast can go
        // missing when the process is restarted under the confirmation screen —
        // used to refuse every later attempt for the life of the process, which
        // is the one state the user cannot get out of. Somebody asking again is
        // the answer: let the old wait go and start over.
        if (done != null) {
            Log.w(TAG, "a previous hand-over never reported; starting over")
            finish(ERR_ABORTED, "superseded by another attempt")
        }
        done = answer
        onStatus = { status -> handle(status) }
        // Parsing and verifying a hundred-megabyte APK, then copying it into
        // the session, must not sit on the main thread.
        Thread {
            val refusal = try {
                hand(File(path))
            } catch (e: Exception) {
                Log.w(TAG, "could not hand the update over: $e")
                Pair(ERR_FAILED, "could not hand the update to the package manager: ${e.message ?: e}")
            }
            if (refusal != null) main.post { finish(refusal.first, refusal.second) }
        }.start()
    }

    /** The activity is in front again: a held confirmation screen can open. */
    fun onResumed() {
        resumed = true
        showConfirmation()
    }

    fun onPaused() {
        resumed = false
    }

    /**
     * Runs off the main thread. Returns the refusal to report, or null when the
     * session was committed and the verdict now comes over the broadcast.
     */
    private fun hand(apk: File): Pair<String, String>? {
        if (!canInstall()) return Pair(ERR_NOT_ALLOWED, "this app is not allowed to install packages")
        if (!apk.isFile || apk.length() <= 0L) return Pair(ERR_FAILED, "the downloaded update is missing")
        // The download belongs in the app's own cache — that is where
        // getTemporaryDirectory points on Android — which no other app can
        // reach, so nothing can swap the file between the checks below and the
        // copy into the session.
        val cache = activity.cacheDir.canonicalPath + File.separator
        if (!apk.canonicalPath.startsWith(cache)) return Pair(ERR_FAILED, "the update must sit in the app's own cache")

        // Parsing with the signing flag verifies the APK's own signature too, so
        // a truncated or tampered download is caught right here.
        val incoming = archiveInfo(apk.absolutePath)
            ?: return Pair(ERR_FAILED, "the download is not a readable, correctly signed APK")
        if (incoming.packageName != activity.packageName) {
            return Pair(ERR_FAILED, "the download is ${incoming.packageName}, not ${activity.packageName}")
        }
        val current = installedInfo()
        if (current != null && versionCode(incoming) < versionCode(current)) {
            return Pair(
                ERR_FAILED,
                "the release carries version code ${versionCode(incoming)}, older than the installed ${versionCode(current)}",
            )
        }
        val mine = fingerprints(current)
        val theirs = fingerprints(incoming)
        if (mine.isNotEmpty() && theirs.isNotEmpty() && mine.intersect(theirs).isEmpty()) {
            Log.w(TAG, "signing keys differ: installed ${short(mine)}, release ${short(theirs)}")
            return Pair(ERR_SIGNATURE, "installed ${short(mine)}, release ${short(theirs)}")
        }

        val installer = activity.packageManager.packageInstaller
        // A crash between createSession and commit parks a copy of the APK on
        // disk for good. Nothing else in this app opens sessions, so every one
        // of ours still around is dead.
        val stale = installer.mySessions.map { it.sessionId }
        // Noted before they are abandoned, not after: abandoning a committed
        // one reports it aborted straight away, and that answer must already be
        // recognisable as somebody else's when it arrives.
        abandoned = stale.toSet()
        for (old in stale) {
            try {
                installer.abandonSession(old)
            } catch (e: Exception) {
                Log.w(TAG, "stale session $old survives: $e")
            }
        }

        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(activity.packageName)
        // Declaring the size lets the installer refuse a full phone before the
        // copy rather than halfway through it.
        params.setSize(apk.length())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) params.setInstallReason(PackageManager.INSTALL_REASON_USER)
        val id = installer.createSession(params)
        awaited = id
        abandoned = abandoned - id
        try {
            installer.openSession(id).use { session ->
                session.openWrite(ENTRY, 0, apk.length()).use { out ->
                    FileInputStream(apk).use { input ->
                        val buffer = ByteArray(256 * 1024)
                        while (true) {
                            val read = input.read(buffer)
                            if (read < 0) break
                            out.write(buffer, 0, read)
                        }
                    }
                    // Closing the stream does not promise the bytes reached the
                    // installer's storage, and a commit over unflushed data
                    // fails as a corrupt APK.
                    session.fsync(out)
                }
                session.commit(statusSender(id))
            }
        } catch (e: Exception) {
            try {
                installer.abandonSession(id)
            } catch (e2: Exception) {
                Log.w(TAG, "could not abandon session $id: $e2")
            }
            throw e
        }
        Log.i(TAG, "session $id committed, ${apk.length()} bytes")
        return null
    }

    /**
     * The package manager fills the status, the failure message and, for the
     * confirmation step, the screen to show into this intent, and only a
     * mutable PendingIntent lets it: an immutable one arrives with no extras at
     * all, so the install looks like it silently did nothing.
     */
    private fun statusSender(id: Int): IntentSender {
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags = flags or PendingIntent.FLAG_MUTABLE
        val intent = Intent(activity, ApkInstallReceiver::class.java)
        return PendingIntent.getBroadcast(activity, id, intent, flags).intentSender
    }

    /** Runs on the main thread: the receiver is a component of this process. */
    private fun handle(status: Intent) {
        val message = status.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        val code = status.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val id = status.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        Log.i(TAG, "install status $code for session $id: $message")
        if (id != -1 && (id in abandoned || (awaited != -1 && id != awaited))) {
            Log.i(TAG, "status for session $id ignored, waiting on $awaited")
            return
        }
        when {
            code == PackageInstaller.STATUS_PENDING_USER_ACTION -> confirm(status)
            code == PackageInstaller.STATUS_SUCCESS -> finish(null, null)
            code == PackageInstaller.STATUS_FAILURE_ABORTED -> finish(ERR_ABORTED, message)
            // What a mismatched signing key comes back as when the comparison
            // above let it through — an older platform, or a key our parser
            // could not read.
            code == PackageInstaller.STATUS_FAILURE_CONFLICT || saysSignature(message) -> finish(ERR_SIGNATURE, message)
            else -> finish(ERR_FAILED, message ?: "the package manager refused the update")
        }
    }

    private fun saysSignature(message: String?): Boolean {
        val m = message ?: return false
        return m.contains("UPDATE_INCOMPATIBLE") || m.contains("signatures do not match")
    }

    @Suppress("DEPRECATION")
    private fun confirm(status: Intent) {
        val screen = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            status.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        } else {
            status.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
        }
        if (screen == null) {
            finish(ERR_FAILED, "the system offered no confirmation screen")
            return
        }
        confirmation = screen
        showConfirmation()
    }

    private fun showConfirmation() {
        // Android 10+ drops an activity started from the background without a
        // word, and a download of this size may well have taken the app out of
        // view, so the screen waits for the next onResume.
        if (!resumed) return
        val screen = confirmation ?: return
        confirmation = null
        try {
            // No FLAG_ACTIVITY_NEW_TASK: the confirmation belongs on top of the
            // app's own task, so declining it lands back in the app.
            activity.startActivity(screen)
        } catch (e: Exception) {
            finish(ERR_FAILED, "could not open the system installer: $e")
        }
    }

    private fun finish(code: String?, message: String?) {
        val answer = done ?: return
        done = null
        confirmation = null
        awaited = -1
        onStatus = null
        answer(code, message)
    }

    // ───── package facts ─────────────────────────────────────────────────

    private fun signatureFlag(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }

    private fun installedInfo(): PackageInfo? =
        try {
            val pm = activity.packageManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(activity.packageName, PackageManager.PackageInfoFlags.of(signatureFlag().toLong()))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(activity.packageName, signatureFlag())
            }
        } catch (e: PackageManager.NameNotFoundException) {
            null
        }

    private fun archiveInfo(path: String): PackageInfo? {
        val pm = activity.packageManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageArchiveInfo(path, PackageManager.PackageInfoFlags.of(signatureFlag().toLong()))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageArchiveInfo(path, signatureFlag())
        }
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()

    /**
     * SHA-256 of every certificate a package is, or ever was, signed with. The
     * history matters because a key rotated with apksigner still marks the same
     * app, and an update carrying the new key must not be called foreign.
     */
    @Suppress("DEPRECATION")
    private fun fingerprints(info: PackageInfo?): Set<String> {
        if (info == null) return emptySet()
        val out = LinkedHashSet<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signing = info.signingInfo ?: return out
            for (s in signing.apkContentsSigners ?: emptyArray()) out.add(sha256(s))
            // signingCertificateHistory is the rotation lineage, and it is empty
            // rather than the current signer when an APK has several signers.
            if (!signing.hasMultipleSigners()) {
                for (s in signing.signingCertificateHistory ?: emptyArray()) out.add(sha256(s))
            }
        } else {
            for (s in info.signatures ?: emptyArray()) {
                if (s != null) out.add(sha256(s))
            }
        }
        return out
    }

    private fun sha256(signature: Signature): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
        val out = StringBuilder(digest.size * 2)
        for (b in digest) out.append(HEX[(b.toInt() shr 4) and 0xf]).append(HEX[b.toInt() and 0xf])
        return out.toString()
    }

    /** Enough of a fingerprint to tell two keys apart in one line of a message. */
    private fun short(fingerprints: Set<String>): String = fingerprints.joinToString(", ") { it.take(16) }

    companion object {
        const val TAG = "ApkInstaller"

        /** The codes Updater.messageFor turns into a sentence. */
        const val ERR_NOT_ALLOWED = "install_not_allowed"
        const val ERR_SIGNATURE = "install_signature_mismatch"
        const val ERR_ABORTED = "install_aborted"
        const val ERR_FAILED = "install_failed"

        /** Name of the only entry of a single-APK session. */
        private const val ENTRY = "base.apk"
        private val HEX = "0123456789abcdef".toCharArray()

        /** Set while an install runs; [ApkInstallReceiver] routes into it. */
        var onStatus: ((Intent) -> Unit)? = null
    }
}

/**
 * Carries the package manager's verdict on an update back into the app. It is
 * declared in the manifest rather than registered at runtime because
 * exported="false" then keeps the broadcast inside this package for good,
 * without the dance around Context.RECEIVER_NOT_EXPORTED that Android 13+
 * demands of every runtime registration; the intent is explicit, so it is our
 * own uid that sends it.
 */
class ApkInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val handler = ApkInstaller.onStatus
        if (handler == null) {
            // The process was restarted, or the install already ended: with
            // nothing listening the verdict has nowhere to go.
            Log.w(ApkInstaller.TAG, "install status ${intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)} with nobody listening")
            return
        }
        handler(intent)
    }
}
