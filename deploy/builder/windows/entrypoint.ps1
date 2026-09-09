# Runs inside the Windows builder container: builds app/ from the repository
# mounted at C:\src on a staging copy and writes the zipped release bundle to
# C:\src\dist (so the host's app/build stays untouched).
$ErrorActionPreference = 'Stop'
$src = 'C:\src'
$work = 'C:\work\app'

if (-not (Test-Path "$src\app\pubspec.yaml")) {
  throw "Mount the repository at C:\src (expected $src\app\pubspec.yaml)"
}

New-Item -ItemType Directory -Force $work | Out-Null
robocopy "$src\app" $work /MIR /XD build .dart_tool .idea /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }

$version = 'dev'
try {
  $described = & git -C $src describe --tags --always --dirty
  if ($LASTEXITCODE -eq 0 -and $described) { $version = "$described".Trim() }
} catch {}

Set-Location $work
Write-Host "==> flutter pub get"
flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
Write-Host "==> flutter build windows --release ($version)"
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }

New-Item -ItemType Directory -Force "$src\dist" | Out-Null
$zip = "$src\dist\family-messenger-windows-x64-$version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "$work\build\windows\x64\runner\Release\*" -DestinationPath $zip
Write-Host "==> done: $zip"
