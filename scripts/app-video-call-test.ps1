# Runs a real video call between the Flutter app and a browser peer on a
# throwaway local server:
#   1. starts the Go server (open registration, temporary data dir),
#   2. starts the browser peer (Playwright, fake camera) in the background,
#   3. runs app/integration_test/video_call_test.dart on the chosen device.
#
#   powershell -ExecutionPolicy Bypass -File scripts\app-video-call-test.ps1                    # Windows app, real camera (a webcam or OBS Virtual Camera)
#   powershell -ExecutionPolicy Bypass -File scripts\app-video-call-test.ps1 -Camera screen     # Windows app, built-in test mode: the screen as the camera
#   powershell -ExecutionPolicy Bypass -File scripts\app-video-call-test.ps1 -Device emulator-5554   # Android emulator (its virtual-scene camera) or a USB phone
param(
  [ValidateSet('device', 'screen')][string]$Camera = 'device',
  [int]$Port = 18082,
  [string]$Channel = 'msedge',
  # A Flutter device id from `flutter devices`: windows, or an Android emulator / phone.
  [string]$Device = 'windows'
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$run = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString('x')
$user = "appalice$run"
$peer = "appbob$run"
$work = Join-Path $env:TEMP "fm-apptest-$run"
$package = 'dev.familymessenger.family_messenger_e2e'
New-Item -ItemType Directory -Force $work | Out-Null

function Find-Flutter {
  # The Flutter SDK ships both `flutter.bat` and the POSIX `flutter`, so with
  # its bin on PATH Get-Command returns two entries; take the first.
  $f = @(Get-Command flutter -CommandType Application -ErrorAction SilentlyContinue)
  if ($f.Count) { return $f[0].Source }
  foreach ($c in @("$env:FLUTTER_ROOT\bin\flutter.bat", 'C:\tools\flutter\bin\flutter.bat', 'C:\flutter\bin\flutter.bat')) {
    if ($c -and (Test-Path $c)) { return $c }
  }
  throw 'flutter not found: put it on PATH or set FLUTTER_ROOT'
}
function Find-Adb {
  $a = @(Get-Command adb -CommandType Application -ErrorAction SilentlyContinue)
  if ($a.Count) { return $a[0].Source }
  foreach ($root in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, 'C:\tools\android-sdk', "$env:LOCALAPPDATA\Android\Sdk")) {
    if ($root -and (Test-Path "$root\platform-tools\adb.exe")) { return "$root\platform-tools\adb.exe" }
  }
  throw 'adb not found: put it on PATH or set ANDROID_HOME'
}
$flutter = Find-Flutter
$android = $Device -ne 'windows'

if (-not (Test-Path (Join-Path $repo 'web\dist\index.html'))) {
  Push-Location (Join-Path $repo 'web')
  try { npm run build; if ($LASTEXITCODE -ne 0) { throw 'web build failed' } } finally { Pop-Location }
}

Write-Host "==> server on 127.0.0.1:$Port (data in $work)"
$env:MSGR_ADDR = "127.0.0.1:$Port"
$env:MSGR_DATA_DIR = Join-Path $work 'data'
$env:MSGR_REGISTRATION = 'open'
$env:MSGR_WEB_DIR = Join-Path $repo 'web\dist'
$server = Start-Process -FilePath 'go' -ArgumentList 'run', './cmd/server' -WorkingDirectory $repo -PassThru -NoNewWindow -RedirectStandardError (Join-Path $work 'server.log')
$null = $server.Handle # keeps the handle so ExitCode is readable later
$ready = $false
foreach ($i in 1..120) {
  try { if ((Invoke-WebRequest -Uri "http://127.0.0.1:$Port/healthz" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) { $ready = $true; break } } catch {}
  Start-Sleep -Milliseconds 500
}
if (-not $ready) { taskkill /T /F /PID $server.Id | Out-Null; throw "the server did not start; see $work\server.log" }

Write-Host "==> browser peer $peer ($Channel)"
$env:TEST_USER = $user
$env:TEST_PEER = $peer
$env:TEST_BASE_URL = "http://127.0.0.1:$Port"
$env:PW_CHANNEL = $Channel
$peerProc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'npx playwright test --config playwright.peer.config.ts' -WorkingDirectory (Join-Path $repo 'web') -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $work 'peer.log') -RedirectStandardError (Join-Path $work 'peer.err')
$null = $peerProc.Handle

Push-Location (Join-Path $repo 'app')
try {
  if ($android) {
    $adb = Find-Adb
    # The device reaches the host's 127.0.0.1:$Port through adb, so the server keeps listening on localhost.
    & $adb -s $Device reverse "tcp:$Port" "tcp:$Port"
    if ($LASTEXITCODE -ne 0) { throw "adb reverse failed for $Device" }
    # Runtime permission dialogs would pop up in the middle of the test: install the debug app
    # once and grant them up front (the test's own reinstall keeps the grants).
    Write-Host "==> installing the debug app on $Device and granting camera and microphone"
    & $flutter build apk --debug
    if ($LASTEXITCODE -ne 0) { throw 'debug apk build failed' }
    & $adb -s $Device install -r -t build\app\outputs\flutter-apk\app-debug.apk
    if ($LASTEXITCODE -ne 0) { throw 'adb install failed' }
    foreach ($p in 'android.permission.CAMERA', 'android.permission.RECORD_AUDIO') {
      & $adb -s $Device shell pm grant $package $p
    }
  }
  Write-Host "==> app integration test on $Device (camera: $Camera)"
  $defines = @("--dart-define=TEST_SERVER=http://127.0.0.1:$Port", "--dart-define=TEST_USER=$user", "--dart-define=TEST_PEER=$peer")
  if ($Camera -eq 'screen') { $defines += '--dart-define=FAKE_CAMERA=screen' }
  & $flutter test integration_test/video_call_test.dart -d $Device @defines
  $appExit = $LASTEXITCODE
} finally {
  Pop-Location
}

$peerProc.WaitForExit(180000) | Out-Null
$peerExit = $peerProc.ExitCode
Write-Host "==> peer log"
Get-Content (Join-Path $work 'peer.log') -ErrorAction SilentlyContinue | Where-Object { $_ -match '\S' } | Select-Object -Last 15
taskkill /T /F /PID $server.Id 2>$null | Out-Null
if ($appExit -ne 0) { throw "the app test failed (exit $appExit); logs in $work" }
if ($null -eq $peerExit -or $peerExit -ne 0) { throw "the browser peer failed (exit $peerExit); logs in $work" }
Write-Host "==> video call between the app and the browser: OK"
