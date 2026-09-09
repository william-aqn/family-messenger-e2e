# Runs a real video call between the Flutter Windows app and a browser peer
# on a throwaway local server:
#   1. starts the Go server (open registration, temporary data dir),
#   2. starts the browser peer (Playwright, fake camera) in the background,
#   3. runs app/integration_test/video_call_test.dart on Windows.
#
#   powershell -ExecutionPolicy Bypass -File scripts\app-video-call-test.ps1              # real camera (a webcam or OBS Virtual Camera)
#   powershell -ExecutionPolicy Bypass -File scripts\app-video-call-test.ps1 -Camera screen   # built-in test mode: the screen as the camera
param(
  [ValidateSet('device', 'screen')][string]$Camera = 'device',
  [int]$Port = 18082,
  [string]$Channel = 'msedge'
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$run = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString('x')
$user = "appalice$run"
$peer = "appbob$run"
$work = Join-Path $env:TEMP "fm-apptest-$run"
New-Item -ItemType Directory -Force $work | Out-Null

function Find-Flutter {
  $f = Get-Command flutter -CommandType Application -ErrorAction SilentlyContinue
  if ($f) { return $f.Source }
  foreach ($c in @("$env:FLUTTER_ROOT\bin\flutter.bat", 'C:\tools\flutter\bin\flutter.bat', 'C:\flutter\bin\flutter.bat')) {
    if ($c -and (Test-Path $c)) { return $c }
  }
  throw 'flutter not found: put it on PATH or set FLUTTER_ROOT'
}
$flutter = Find-Flutter

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

Write-Host "==> app integration test (camera: $Camera)"
$defines = @("--dart-define=TEST_SERVER=http://127.0.0.1:$Port", "--dart-define=TEST_USER=$user", "--dart-define=TEST_PEER=$peer")
if ($Camera -eq 'screen') { $defines += '--dart-define=FAKE_CAMERA=screen' }
Push-Location (Join-Path $repo 'app')
try {
  & $flutter test integration_test/video_call_test.dart -d windows @defines
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
