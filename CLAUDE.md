# Family Messenger (E2E)

Go server + web client (Vite/Preact) + Flutter app. The protocol is in
`protocol/PROTOCOL.md`; the user writes in Russian, repository artifacts stay
in English.

## Verifying app changes: the full flow on a real APK

Any change that touches `app/` must be verified as a complete user flow on an
actual APK, at the UI level, before it is reported as done:

1. Build the APK (`flutter build apk --debug` or `--release`) and install it on
   the Android emulator (AVD `pixel`, start with
   `emulator -avd pixel -camera-front emulated -camera-back environment`) or a
   phone.
2. Drive the app the way a person would: sign in through the login screen,
   open the chat, send/edit/delete messages, make and answer calls. Use
   `adb shell input tap/text` and `adb exec-out screencap -p` and look at the
   screenshots of every state (ringing, connected, ended, errors).
3. For calls, run a real peer: `web/tests/peer/live-peer.mjs` (a browser with a
   fake camera that signs in, answers and screenshots what it sees) or a
   second device. Check both sides.
4. Read `adb logcat` for `flutter`, `FlutterWebRTCPlugin` and crashes
   (`DEBUG`, `System.err`).

State-level checks are not enough: the integration test in
`app/integration_test` reported "VIDEO OK" while the call screen stayed frozen
on "Calling…" (a const widget that never rebuilt), which is exactly what the
user saw on their phone. `scripts/app-video-call-test.ps1 -Device emulator-5554`
runs the rig on a device, but it complements the manual flow, it does not
replace it.

## Local tooling notes

- Android SDK: `C:\tools\android-sdk`; JDK: `C:\tools\jdk-21` (set `JAVA_HOME`
  and put its `bin` first on `PATH` for Gradle). Flutter: `C:\tools\flutter`.
- Gradle on this machine needs `kotlin.incremental=false` in
  `~/.gradle/gradle.properties` (Kotlin cache files get locked).
- Browser tests run with `PW_CHANNEL=msedge` (Playwright's browser download is
  blocked here).
- Never run `python - <<EOF` here: the Windows Store python stub hangs.
