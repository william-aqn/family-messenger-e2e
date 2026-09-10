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
5. The Windows build gets the same treatment, preferably without touching
   the desktop's mouse and keyboard (the machine's owner works on it):
   `scripts\app-video-call-test.ps1` runs the whole scenario (video call,
   screen share, a second call, an incoming call answered with the button)
   through the integration test against a browser peer, and
   `scripts\win-drive.ps1 -Action peek -File x.png` grabs the app window in
   a loop meanwhile without stealing focus (`PrintWindow`, works when other
   windows cover it). Look at those screenshots. For a hand-driven session
   launch the release exe with `FAMILY_MESSENGER_EPHEMERAL=1` (starts signed
   out and saves nothing, so the stored session stays untouched) and use
   `win-drive.ps1` `click`/`type`/`key`/`shot`, which refuse to act when the
   app window is not in the foreground. OBS's virtual camera
   (`obs64.exe --startvirtualcam`) stands in for a webcam.
6. Linux runs inside the builder image (`deploy/builder`, no WSL distro on
   this machine): `scripts/app-video-call-test-linux.sh` in a container with
   the repo mounted at `/src` and a screenshot folder at `/out`
   (`docker run --entrypoint sh -p 18082:18082 -v E:\ai\messanger:/src:ro -v <dir>:/out family-messenger-e2e-builder /src/scripts/app-video-call-test-linux.sh`,
   plus the `builder_builder-pub`/`-go`/`-gocache` volumes for speed) gives
   Xvfb, PulseAudio null devices, the server and the integration test with
   the screen as the camera; the browser peer runs on the host with
   `TEST_BASE_URL=http://127.0.0.1:18082` and the names from `/out/peer.env`.
   Screenshots of the X screen land in `/out`.

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
