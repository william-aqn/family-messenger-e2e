# Builds the Flutter Windows desktop app inside a Windows container.
#
#   powershell -ExecutionPolicy Bypass -File deploy\builder\windows\build.ps1
#
# Needs Docker Desktop with Windows containers available. The script talks to
# the Windows engine directly when Docker Desktop exposes it next to the Linux
# one (named pipe dockerDesktopWindowsEngine); otherwise switch the default
# engine first:
#   & "C:\Program Files\Docker\Docker\DockerCli.exe" -SwitchWindowsEngine
# (and -SwitchLinuxEngine to go back). The first image build downloads Visual
# Studio Build Tools and Flutter (about 10 GB, 30-60 minutes); later runs reuse
# the image. The zip lands in .\dist.
param(
  [string]$Tag = 'family-messenger-e2e-builder-windows:latest',
  [switch]$SkipImageBuild
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path.TrimEnd('\')

function Invoke-Docker {
  & docker @script:dockerArgs @args
  if ($LASTEXITCODE -ne 0) { throw "docker $($args[0]) failed with exit code $LASTEXITCODE" }
}

$script:dockerArgs = @()
$serverOs = & docker version --format '{{.Server.Os}}'
if ($serverOs -ne 'windows') {
  $pipe = 'npipe:////./pipe/dockerDesktopWindowsEngine'
  $ok = $false
  if ([System.IO.Directory]::GetFiles('\\.\pipe\') -contains '\\.\pipe\dockerDesktopWindowsEngine') {
    # The pipe exists even while the Windows engine is stopped; probe it quietly.
    $ok = & { $ErrorActionPreference = 'Continue'; (& docker -H $pipe version --format '{{.Server.Os}}' 2>$null) -eq 'windows' }
  }
  if (-not $ok) {
    $switch = "& 'C:\Program Files\Docker\Docker\DockerCli.exe' -SwitchWindowsEngine"
    $feature = Get-CimInstance Win32_OptionalFeature -Filter "Name='Containers'" -ErrorAction SilentlyContinue
    if ($feature -and $feature.InstallState -ne 1) {
      throw "No Windows container engine: the Windows feature 'Containers' is disabled. Enable it (Turn Windows features on or off; needs a reboot), then run $switch"
    }
    throw "No running Windows container engine (default engine OS: '$serverOs'). Run $switch and retry."
  }
  $script:dockerArgs = @('-H', $pipe)
  Write-Host "==> using the Windows engine at $pipe"
}

if (-not $SkipImageBuild) {
  Write-Host "==> building image $Tag"
  Invoke-Docker build -m 4GB -t $Tag $PSScriptRoot
}

Write-Host "==> building the app from $repo"
Invoke-Docker run --rm -m 6GB -v "${repo}:C:\src" $Tag
Get-ChildItem (Join-Path $repo 'dist') -Filter 'family-messenger-windows-*.zip' | Select-Object Name, Length, LastWriteTime
