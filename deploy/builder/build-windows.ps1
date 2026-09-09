<#
.SYNOPSIS
Native Windows builder: fetches the toolchain it needs and builds the Flutter
Windows app, the web client and the server without Docker.

.DESCRIPTION
Targets (positional, several allowed):
  windows  Flutter desktop app -> dist\family-messenger-windows-x64-<version>.zip (default)
  web      Vite client -> web\dist, mirrored into internal\webui\dist for embedding
  server   Go server with the web client embedded -> dist\server-windows-amd64.exe,
           dist\server-linux-amd64, dist\server-linux-arm64
  all      web + server + windows
  doctor   check the toolchain (installs what is missing unless -NoInstall)

Portable tools are downloaded into -ToolsDir only when nothing usable is found:
MinGit, the Flutter SDK (pinned to -FlutterVersion), Node (latest 26.x) and Go
(latest stable). Visual Studio Build Tools 2022 with the C++ workload is the one
system-wide install: the official bootstrapper is started and asks for
administrator rights (UAC) once. Flutter also needs Developer Mode (symlinks for
plugins) or an elevated shell.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File deploy\builder\build-windows.ps1
powershell -ExecutionPolicy Bypass -File deploy\builder\build-windows.ps1 all
powershell -ExecutionPolicy Bypass -File deploy\builder\build-windows.ps1 doctor -NoInstall
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Targets = @('windows'),
  # Where portable tools live. Default: %LOCALAPPDATA%\family-messenger-e2e\tools
  # (or %SystemDrive%\family-messenger-tools when LOCALAPPDATA contains spaces,
  # which the Flutter SDK dislikes). Env FM_TOOLS_DIR overrides the default.
  [string]$ToolsDir = '',
  # Flutter version to download, and the minimum accepted for an existing SDK.
  [string]$FlutterVersion = '3.47.2',
  [string]$MinGitVersion = '2.47.1',
  # Ignore tools on PATH; use (and download) the portable ones in ToolsDir.
  [switch]$Portable,
  # Never download or install anything; fail when something is missing.
  [switch]$NoInstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'Windows PowerShell 5.1 or PowerShell 7 is required' }

$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $ToolsDir) {
  if ($env:FM_TOOLS_DIR) { $ToolsDir = $env:FM_TOOLS_DIR }
  elseif ($env:LOCALAPPDATA -notmatch '\s') { $ToolsDir = Join-Path $env:LOCALAPPDATA 'family-messenger-e2e\tools' }
  else { $ToolsDir = Join-Path $env:SystemDrive 'family-messenger-tools' }
}
$Downloads = Join-Path $ToolsDir 'downloads'
$Dist = Join-Path $Repo 'dist'
$System32 = Join-Path $env:SystemRoot 'System32'
$ProgramFilesX86 = ${env:ProgramFiles(x86)}
$script:Tools = @{}

# ---------------------------------------------------------------- helpers

function Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Note([string]$Message) { Write-Host "    $Message" -ForegroundColor DarkGray }

function Use-Tool([string]$Name, [string]$Path, [string]$Version) {
  $script:Tools[$Name] = [pscustomobject]@{ Tool = $Name; Version = $Version; Path = $Path }
  Note "$Name $Version  $Path"
}

function Show-Report {
  if ($script:Tools.Count) { $script:Tools.Values | Sort-Object Tool | Format-Table Tool, Version, Path -AutoSize -Wrap | Out-Host }
}

# Runs a native tool, streams its output and fails on a non-zero exit code.
function Exec([string]$File, [string[]]$Arguments, [string]$WorkDir) {
  if ($WorkDir) { Push-Location $WorkDir }
  try {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
  } finally {
    if ($WorkDir) { Pop-Location }
  }
}

function Find-Exe([string]$Name) {
  $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }
  return $null
}

function Add-Path([string]$Dir) {
  if (-not (($env:PATH -split ';') -contains $Dir)) { $env:PATH = "$Dir;$env:PATH" }
}

function Test-VersionAtLeast([string]$Have, [string]$Want) {
  try { return ([version]($Have -replace '^[^0-9]*', '' -replace '[^0-9.].*$', '')) -ge [version]$Want } catch { return $false }
}

function Require-Install([string]$What) {
  if ($NoInstall) { throw "$What is missing; rerun without -NoInstall to download it" }
}

function Get-File([string]$Url, [string]$Dest) {
  if (Test-Path $Dest) { Note "using cached $(Split-Path $Dest -Leaf)"; return }
  Require-Install (Split-Path $Dest -Leaf)
  New-Item -ItemType Directory -Force (Split-Path $Dest) | Out-Null
  Step "downloading $Url"
  $part = "$Dest.part"
  if (Test-Path $part) { Remove-Item $part -Force }
  $curl = Join-Path $System32 'curl.exe'
  if (Test-Path $curl) {
    # A progress bar only makes sense on a console; logs get a silent download.
    $progress = '--progress-bar'
    if ([Console]::IsErrorRedirected) { $progress = '-sS' }
    & $curl -fL $progress --retry 3 --retry-delay 2 -o $part $Url
    if ($LASTEXITCODE -ne 0) { throw "download failed with curl exit code $LASTEXITCODE : $Url" }
  } else {
    Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing
  }
  Move-Item $part $Dest -Force
}

function Expand-Zip([string]$Zip, [string]$Dest) {
  Step "extracting $(Split-Path $Zip -Leaf) to $Dest"
  New-Item -ItemType Directory -Force $Dest | Out-Null
  $tar = Join-Path $System32 'tar.exe'
  if (Test-Path $tar) {
    & $tar -xf $Zip -C $Dest
    if ($LASTEXITCODE -ne 0) { throw "extracting $Zip failed with exit code $LASTEXITCODE" }
  } else {
    Expand-Archive -Path $Zip -DestinationPath $Dest -Force
  }
}

function Get-Version {
  try {
    $v = & git -C $Repo describe --tags --always --dirty
    if ($LASTEXITCODE -eq 0 -and $v) { return "$v".Trim() }
  } catch {}
  return 'dev'
}

# ---------------------------------------------------------------- toolchain

function Ensure-Git {
  if (-not $Portable) {
    $git = Find-Exe git
    if ($git) { Use-Tool 'git' $git ((& $git --version) -replace '^git version ', ''); return }
  }
  $git = Join-Path $ToolsDir 'git\cmd\git.exe'
  if (-not (Test-Path $git)) {
    Require-Install 'Git'
    $zip = Join-Path $Downloads "MinGit-$MinGitVersion-64-bit.zip"
    Get-File "https://github.com/git-for-windows/git/releases/download/v$MinGitVersion.windows.1/MinGit-$MinGitVersion-64-bit.zip" $zip
    Expand-Zip $zip (Join-Path $ToolsDir 'git')
  }
  Add-Path (Split-Path $git)
  Use-Tool 'git' $git ((& $git --version) -replace '^git version ', '')
}

function Get-FlutterVersion([string]$Root) {
  $json = Join-Path $Root 'bin\cache\flutter.version.json'
  if (Test-Path $json) {
    try { return [string](Get-Content $json -Raw | ConvertFrom-Json).frameworkVersion } catch {}
  }
  $legacy = Join-Path $Root 'version'
  if (Test-Path $legacy) { return (Get-Content $legacy -Raw).Trim() }
  return $null
}

function Ensure-Flutter {
  $candidates = @()
  if (-not $Portable) {
    $onPath = Find-Exe flutter
    if ($onPath) { $candidates += (Split-Path (Split-Path $onPath)) }
    if ($env:FLUTTER_ROOT) { $candidates += $env:FLUTTER_ROOT }
    $candidates += @('C:\tools\flutter', 'C:\flutter', 'C:\src\flutter',
      (Join-Path $env:LOCALAPPDATA 'flutter'), (Join-Path $env:USERPROFILE 'flutter'),
      (Join-Path $env:USERPROFILE 'fvm\default'))
  }
  $candidates += (Join-Path $ToolsDir 'flutter')
  $root = $null
  foreach ($c in $candidates) {
    if (-not (Test-Path (Join-Path $c 'bin\flutter.bat'))) { continue }
    $v = Get-FlutterVersion $c
    if ($v -and (Test-VersionAtLeast $v $FlutterVersion)) { $root = $c; break }
    Note "skipping Flutter $v at $c (need $FlutterVersion or newer)"
  }
  if (-not $root) {
    Require-Install "Flutter SDK $FlutterVersion"
    $root = Join-Path $ToolsDir 'flutter'
    $zip = Join-Path $Downloads "flutter_windows_$FlutterVersion-stable.zip"
    Get-File "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_$FlutterVersion-stable.zip" $zip
    if (Test-Path $root) { Remove-Item $root -Recurse -Force }
    Expand-Zip $zip $ToolsDir   # the archive contains a top-level "flutter" folder
  }
  Add-Path (Join-Path $root 'bin')
  $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
  Use-Tool 'flutter' $root (Get-FlutterVersion $root)
}

function Ensure-Node {
  if (-not $Portable) {
    $node = Find-Exe node
    if ($node) {
      $v = & $node --version
      if (Test-VersionAtLeast $v '22.0.0') { Use-Tool 'node' $node $v; return }
      Note "node $v on PATH is too old (need 22 or newer)"
    }
  }
  $dir = Join-Path $ToolsDir 'node'
  $node = Join-Path $dir 'node.exe'
  if (-not (Test-Path $node)) {
    Require-Install 'Node.js'
    $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -UseBasicParsing
    $rel = $index | Where-Object { $_.version -like 'v26.*' } | Select-Object -First 1
    if (-not $rel) { $rel = $index | Where-Object { $_.lts } | Select-Object -First 1 }
    $name = "node-$($rel.version)-win-x64"
    $zip = Join-Path $Downloads "$name.zip"
    Get-File "https://nodejs.org/dist/$($rel.version)/$name.zip" $zip
    Expand-Zip $zip $ToolsDir
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    Move-Item (Join-Path $ToolsDir $name) $dir
  }
  Add-Path $dir
  Use-Tool 'node' $node (& $node --version)
}

function Ensure-Go {
  if (-not $Portable) {
    $go = Find-Exe go
    # Any recent Go works: GOTOOLCHAIN=auto fetches the version go.mod asks for.
    if ($go) { Use-Tool 'go' $go ((& $go version) -replace '^go version ', ''); return }
  }
  $dir = Join-Path $ToolsDir 'go'
  $go = Join-Path $dir 'bin\go.exe'
  if (-not (Test-Path $go)) {
    Require-Install 'Go'
    $releases = Invoke-RestMethod -Uri 'https://go.dev/dl/?mode=json' -UseBasicParsing
    $rel = $releases | Where-Object { $_.stable } | Select-Object -First 1
    $file = $rel.files | Where-Object { $_.os -eq 'windows' -and $_.arch -eq 'amd64' -and $_.kind -eq 'archive' } | Select-Object -First 1
    $zip = Join-Path $Downloads $file.filename
    Get-File "https://go.dev/dl/$($file.filename)" $zip
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    Expand-Zip $zip $ToolsDir   # the archive contains a top-level "go" folder
  }
  Add-Path (Join-Path $dir 'bin')
  Use-Tool 'go' $go ((& $go version) -replace '^go version ', '')
}

# Components the Flutter Windows build needs: MSVC, CMake and ATL (plugins such
# as flutter_secure_storage include atlstr.h), plus a Windows SDK.
$MsvcComponents = @(
  'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
  'Microsoft.VisualStudio.Component.VC.CMake.Project',
  'Microsoft.VisualStudio.Component.VC.ATL')
$VsWhere = Join-Path $ProgramFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'

function Get-MsvcInstall {
  if (-not (Test-Path $VsWhere)) { return $null }
  $path = & $VsWhere -products * -latest -requires $MsvcComponents -property installationPath
  if ($LASTEXITCODE -eq 0 -and $path) { return "$path".Trim() }
  return $null
}

function Test-WindowsSdk {
  return [bool](Get-ChildItem (Join-Path $ProgramFilesX86 'Windows Kits\10\Include\*\um\windows.h') -ErrorAction SilentlyContinue)
}

function Ensure-VisualStudio {
  $vs = Get-MsvcInstall
  if ($vs -and (Test-WindowsSdk)) { Use-Tool 'msvc' $vs 'C++ tools, CMake, ATL, Windows SDK'; return }
  Require-Install 'Visual Studio Build Tools 2022 with the C++ workload (MSVC, CMake, ATL, Windows SDK)'
  $exe = Join-Path $Downloads 'vs_BuildTools.exe'
  Get-File 'https://aka.ms/vs/17/release/vs_BuildTools.exe' $exe
  $addArgs = @('--add', 'Microsoft.VisualStudio.Workload.VCTools', '--includeRecommended')
  foreach ($c in $MsvcComponents) { $addArgs += @('--add', $c) }
  # An existing Visual Studio / Build Tools instance is modified in place
  # (adds the missing components) instead of installing a second copy.
  $existing = $null
  if (Test-Path $VsWhere) {
    $existing = & $VsWhere -products * -latest -property installationPath
    if ($existing) { $existing = "$existing".Trim() }
  }
  if ($existing) {
    Step "adding the C++ components (MSVC, CMake, ATL, Windows SDK) to $existing; confirm the UAC prompt"
    # Start-Process joins the arguments with spaces, so the path needs its own quotes.
    $installArgs = @('modify', '--installPath', "`"$existing`"", '--passive', '--norestart', '--wait') + $addArgs
  } else {
    Step 'installing Visual Studio Build Tools 2022 (C++ workload, about 7 GB); confirm the UAC prompt'
    $installArgs = @('--passive', '--norestart', '--wait') + $addArgs
  }
  $p = Start-Process -FilePath $exe -ArgumentList $installArgs -Wait -PassThru
  switch ($p.ExitCode) {
    0 { }
    3010 { Note 'installed; Windows wants a reboot at some point, the build can continue' }
    1602 { throw 'Visual Studio Build Tools installation was cancelled' }
    default { throw "Visual Studio Build Tools installer failed with exit code $($p.ExitCode); see $env:TEMP\dd_setup_*.log" }
  }
  $vs = Get-MsvcInstall
  if (-not ($vs -and (Test-WindowsSdk))) { throw 'Visual Studio Build Tools finished but the C++ tools, CMake, ATL or the Windows SDK are still missing' }
  Use-Tool 'msvc' $vs 'C++ tools, CMake, ATL, Windows SDK'
}

function Ensure-Symlinks {
  # The Flutter tool creates symlinks for plugins; without Developer Mode that
  # needs an elevated shell.
  $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $devMode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
  if ($elevated) { Use-Tool 'symlinks' 'elevated shell' 'ok'; return }
  if ($devMode -eq 1) { Use-Tool 'symlinks' 'Developer Mode' 'ok'; return }
  throw 'Flutter needs symlinks for plugins: enable Developer Mode (Settings > System > For developers, or run "start ms-settings:developers") or run this script from an elevated PowerShell'
}

# ---------------------------------------------------------------- targets

function Build-Web {
  Ensure-Node
  $web = Join-Path $Repo 'web'
  Step 'web client: npm ci'
  Exec 'npm' @('ci', '--no-audit', '--no-fund') $web
  Step 'web client: vite build'
  Exec 'npm' @('run', 'build') $web
  $dst = Join-Path $Repo 'internal\webui\dist'
  & (Join-Path $System32 'robocopy.exe') (Join-Path $web 'dist') $dst /MIR /XF .keep /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
  if (-not (Test-Path (Join-Path $dst '.keep'))) { New-Item -ItemType File (Join-Path $dst '.keep') | Out-Null }
  Note 'web\dist mirrored into internal\webui\dist'
}

function Build-Server {
  Ensure-Go
  if (-not (Test-Path (Join-Path $Repo 'internal\webui\dist\index.html'))) { Build-Web }
  $version = Get-Version
  New-Item -ItemType Directory -Force $Dist | Out-Null
  foreach ($target in @('windows/amd64', 'linux/amd64', 'linux/arm64')) {
    $os, $arch = $target -split '/'
    $ext = ''
    if ($os -eq 'windows') { $ext = '.exe' }
    $out = Join-Path $Dist "server-$os-$arch$ext"
    Step "server $target ($version)"
    $env:GOOS = $os; $env:GOARCH = $arch; $env:CGO_ENABLED = '0'
    try {
      Exec 'go' @('build', '-trimpath', '-ldflags', "-s -w -X github.com/william-aqn/family-messenger-e2e/internal/api.Version=$version", '-o', $out, './cmd/server') $Repo
    } finally {
      $env:GOOS = $null; $env:GOARCH = $null; $env:CGO_ENABLED = $null
    }
    Note "$out ($([math]::Round((Get-Item $out).Length / 1MB, 1)) MB)"
  }
}

function Build-Windows {
  Ensure-Git
  Ensure-Flutter
  Ensure-VisualStudio
  Ensure-Symlinks
  $version = Get-Version
  $app = Join-Path $Repo 'app'
  Step 'flutter pub get'
  Exec 'flutter' @('pub', 'get') $app
  Step "flutter build windows --release ($version)"
  Exec 'flutter' @('build', 'windows', '--release') $app
  $bundle = Join-Path $app 'build\windows\x64\runner\Release'
  if (-not (Test-Path (Join-Path $bundle 'family_messenger_e2e.exe'))) { throw "no build output in $bundle" }
  New-Item -ItemType Directory -Force $Dist | Out-Null
  $zip = Join-Path $Dist "family-messenger-windows-x64-$version.zip"
  if (Test-Path $zip) { Remove-Item $zip -Force }
  Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $zip
  Step "done: $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB); unzip anywhere and run family_messenger_e2e.exe"
}

function Invoke-Doctor {
  $problems = @()
  foreach ($check in @('Ensure-Git', 'Ensure-Node', 'Ensure-Go', 'Ensure-Flutter', 'Ensure-VisualStudio', 'Ensure-Symlinks')) {
    try { & $check } catch {
      $problems += $_.Exception.Message
      Write-Host "!!  $($_.Exception.Message)" -ForegroundColor Yellow
    }
  }
  if ($problems.Count) { throw "doctor: $($problems.Count) problem(s), see above" }
  Step 'doctor: toolchain complete'
}

# ---------------------------------------------------------------- main

$plan = @()
foreach ($t in $Targets) {
  switch ($t.ToLower()) {
    'all' { $plan += 'web', 'server', 'windows' }
    'doctor' { $plan += 'doctor' }
    'web' { $plan += 'web' }
    'server' { $plan += 'server' }
    'windows' { $plan += 'windows' }
    default { throw "unknown target '$t' (use: doctor, web, server, windows, all)" }
  }
}
$plan = @($plan | Select-Object -Unique)

Step "family-messenger-e2e native build: $($plan -join ', ')"
Note "repository $Repo"
Note "tools      $ToolsDir"
Set-Location $Repo
try {
  foreach ($t in $plan) {
    switch ($t) {
      'doctor' { Invoke-Doctor }
      'web' { Build-Web }
      'server' { Build-Server }
      'windows' { Build-Windows }
    }
  }
} finally {
  Show-Report
}
