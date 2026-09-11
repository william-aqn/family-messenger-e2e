# Runs one group voice channel with three participants at once — the Android
# app, the Windows app and a browser — every one of them streaming a camera and
# a shared screen to the other two:
#   1. starts the Go server (open registration, temporary data dir),
#   2. starts the browser peer (Playwright, fake camera) in the background,
#   3. runs app/integration_test/voice_channel_test.dart on the Android device
#      (the host: it creates the group) and on Windows (a guest) together,
#   4. taps away Android's screen-capture consent dialog while they run.
#
#   powershell -ExecutionPolicy Bypass -File scripts\app-voice-channel-test.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\app-voice-channel-test.ps1 -Device emulator-5554 -Port 18083
#   powershell -ExecutionPolicy Bypass -File scripts\app-voice-channel-test.ps1 -Sides web,windows   # without Android
param(
  [int]$Port = 18083,
  [string]$Channel = 'msedge',
  # The Android device id from `adb devices` (an emulator or a USB phone).
  [string]$Device = 'emulator-5554',
  # Which sides take part; the first app side is the host that creates the group.
  [string[]]$Sides = @('web', 'android', 'windows'),
  # The Windows app has no webcam here, so its camera is the screen by default.
  [ValidateSet('device', 'screen')][string]$WindowsCamera = 'screen',
  # Diagnostics: extra --dart-define flags for both app sides.
  [string[]]$Define = @(),
  [int]$TimeoutMinutes = 40
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$run = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString('x')
$work = Join-Path $env:TEMP "fm-voicetest-$run"
$package = 'dev.familymessenger.family_messenger_e2e'
New-Item -ItemType Directory -Force $work | Out-Null

$web = "vweb$run"
$droid = "vdroid$run"
$win = "vwin$run"
$group = "Channel$run"
# `-File` hands an array parameter over as one string, so "web,windows" has to
# be split back apart here.
$Sides = @($Sides | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$useWeb = $Sides -contains 'web'
$useAndroid = $Sides -contains 'android'
$useWindows = $Sides -contains 'windows'
$sideCount = 0
foreach ($on in @($useWeb, $useAndroid, $useWindows)) { if ($on) { $sideCount++ } }
if ($sideCount -lt 2) { throw 'at least two sides are needed' }
# Everybody waits for this many other participants.
$peers = $sideCount - 1

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
$adb = if ($useAndroid) { Find-Adb } else { $null }

# Always rebuilt: the browser peer runs whatever the server serves, and a
# stale bundle would test yesterday's client.
Write-Host '==> building the web client'
Push-Location (Join-Path $repo 'web')
try { npm run build; if ($LASTEXITCODE -ne 0) { throw 'web build failed' } } finally { Pop-Location }

# Both app builds up front and one at a time: two `flutter test` runs start
# together later, and an incremental build is short enough not to collide.
Push-Location (Join-Path $repo 'app')
try {
  if ($useAndroid) {
    Write-Host '==> building the debug apk'
    & $flutter build apk --debug
    if ($LASTEXITCODE -ne 0) { throw 'debug apk build failed' }
  }
  if ($useWindows) {
    Write-Host '==> building the debug windows app'
    & $flutter build windows --debug
    if ($LASTEXITCODE -ne 0) { throw 'debug windows build failed' }
  }
} finally { Pop-Location }

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

# The emulator reaches the host's server through adb, and its runtime
# permission dialogs would pop up in the middle of the test: install the app
# once and grant them up front (the test's own reinstall keeps the grants).
if ($useAndroid) {
  & $adb -s $Device reverse "tcp:$Port" "tcp:$Port"
  if ($LASTEXITCODE -ne 0) { taskkill /T /F /PID $server.Id | Out-Null; throw "adb reverse failed for $Device" }
  Write-Host "==> installing the debug app on $Device and granting camera and microphone"
  & $adb -s $Device install -r -t (Join-Path $repo 'app\build\app\outputs\flutter-apk\app-debug.apk')
  if ($LASTEXITCODE -ne 0) { taskkill /T /F /PID $server.Id | Out-Null; throw 'adb install failed' }
  foreach ($p in 'android.permission.CAMERA', 'android.permission.RECORD_AUDIO') {
    & $adb -s $Device shell pm grant $package $p
  }
}

$procs = @{}
if ($useWeb) {
  Write-Host "==> browser peer $web ($Channel)"
  $env:TEST_PEER = $web
  $env:TEST_GROUP = $group
  $env:TEST_PEERS = "$peers"
  $env:TEST_SHOT = Join-Path $work 'web-tiles.png'
  $env:TEST_BASE_URL = "http://127.0.0.1:$Port"
  $env:PW_CHANNEL = $Channel
  $procs['web'] = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'npx playwright test tests/peer/app-voice-peer.spec.ts --config playwright.peer.config.ts' `
    -WorkingDirectory (Join-Path $repo 'web') -PassThru -NoNewWindow `
    -RedirectStandardOutput (Join-Path $work 'web.log') -RedirectStandardError (Join-Path $work 'web.err')
  $null = $procs['web'].Handle
}

# The first app side creates the group, the other waits for it to arrive.
$hostSide = if ($useAndroid) { 'android' } else { 'windows' }
function Start-AppSide([string]$side, [string]$device, [string]$user, [string[]]$extra) {
  $role = if ($side -eq $hostSide) { 'host' } else { 'guest' }
  # The app on the other platform, empty when the rig left that side out.
  $mate = ''
  if ($side -eq 'android' -and $useWindows) { $mate = $win }
  if ($side -eq 'windows' -and $useAndroid) { $mate = $droid }
  $peerName = if ($useWeb) { $web } else { '' }
  Write-Host "==> $side app ($user, $role) on $device"
  $defines = @(
    "--dart-define=TEST_SERVER=http://127.0.0.1:$Port",
    "--dart-define=TEST_USER=$user",
    "--dart-define=TEST_PEER=$peerName",
    "--dart-define=TEST_OTHER=$mate",
    "--dart-define=TEST_GROUP=$group",
    "--dart-define=TEST_ROLE=$role",
    "--dart-define=TEST_PEERS=$peers"
  ) + $extra + @($Define | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { "--dart-define=$_" })
  # cmd.exe runs the flutter batch file; Start-Process cannot redirect one.
  # Each side gets a temporary directory of its own: two `flutter test` runs
  # at once put their listener files in %TEMP%\flutter_tools.* and one wipes
  # the other's, which kills that app in the middle of the channel.
  $tmp = Join-Path $work "tmp-$side"
  New-Item -ItemType Directory -Force $tmp | Out-Null
  $line = "set TMP=$tmp&& set TEMP=$tmp&& $flutter test integration_test/voice_channel_test.dart -d $device " + ($defines -join ' ')
  $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $line -WorkingDirectory (Join-Path $repo 'app') -PassThru -NoNewWindow `
    -RedirectStandardOutput (Join-Path $work "$side.log") -RedirectStandardError (Join-Path $work "$side.err")
  $null = $p.Handle
  return $p
}

if ($useAndroid) { $procs['android'] = Start-AppSide 'android' $Device $droid @() }
if ($useWindows) {
  # Two flutter builds in the same project at once trip over each other; both
  # apps are built already, so a short stagger is enough.
  if ($useAndroid) { Start-Sleep -Seconds 20 }
  $extra = @()
  if ($WindowsCamera -eq 'screen') { $extra += '--dart-define=FAKE_CAMERA=screen' }
  $procs['windows'] = Start-AppSide 'windows' 'windows' $win $extra
}

# Android's screen-capture consent cannot be pre-granted, so the dialog has to
# be tapped away from outside. The dump is expensive and wedges adb when it is
# run in a loop, so it only starts once the app says it is about to share.
$dialogJob = $null
if ($useAndroid) {
  $dialogJob = Start-Job -ScriptBlock {
    param($adb, $device, $log)
    foreach ($i in 1..600) {
      Start-Sleep -Seconds 1
      if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'SHARING THE SCREEN' -SimpleMatch -Quiet)) { break }
    }
    foreach ($i in 1..30) {
      Start-Sleep -Seconds 2
      $dump = & $adb -s $device shell "uiautomator dump /sdcard/win.xml >/dev/null 2>&1; cat /sdcard/win.xml" 2>$null
      $text = [string]$dump
      if (-not $text) { continue }
      # The dump carries the dialog's own view ids, not the activity name.
      if ($text -notmatch 'screen_share_dialog_title|MediaProjectionPermission|Start now|record or cast') { continue }
      if ($text -match '<node[^>]*resource-id="android:id/button1"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"') {
        $x = [int](([int]$Matches[1] + [int]$Matches[3]) / 2)
        $y = [int](([int]$Matches[2] + [int]$Matches[4]) / 2)
        & $adb -s $device shell input tap $x $y | Out-Null
        Write-Output "tapped the capture dialog at $x,$y"
        return
      }
    }
    Write-Output 'the capture dialog never showed up'
  } -ArgumentList $adb, $Device, (Join-Path $work 'android.log')
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
while (@($procs.Values | Where-Object { -not $_.HasExited }).Count -gt 0) {
  if ((Get-Date) -gt $deadline) { Write-Host '==> timed out, killing what is left'; break }
  Start-Sleep -Seconds 5
}
foreach ($p in $procs.Values) { if (-not $p.HasExited) { taskkill /T /F /PID $p.Id 2>$null | Out-Null } }
if ($dialogJob) {
  Stop-Job $dialogJob -ErrorAction SilentlyContinue
  Receive-Job $dialogJob -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
  Remove-Job $dialogJob -Force -ErrorAction SilentlyContinue
}
taskkill /T /F /PID $server.Id 2>$null | Out-Null

$failed = @()
foreach ($name in $procs.Keys) {
  $exit = $procs[$name].ExitCode
  Write-Host "==> $name (exit $exit)"
  foreach ($f in @("$name.log", "$name.err")) {
    Get-Content (Join-Path $work $f) -ErrorAction SilentlyContinue |
      Where-Object { $_ -match 'CHANNEL|TILES|PEER |signed in|group|connected|camera|screen|rror|xception|failed|passed|All tests' } |
      Select-Object -Last 25 | ForEach-Object { Write-Host "    $_" }
  }
  if ($exit -ne 0) { $failed += $name }
}
Write-Host "==> logs and screenshots in $work"
if ($failed.Count) { throw "these sides failed: $($failed -join ', ')" }
Write-Host '==> one channel, three participants, camera and screen from everybody: OK'
