# Runs the Family Messenger server in development mode, serving the built web client from web/dist.
# Usage: powershell -ExecutionPolicy Bypass -File scripts/dev-server.ps1
$root = Split-Path -Parent $PSScriptRoot
$env:MSGR_ADDR = "127.0.0.1:8080"
$env:MSGR_DATA_DIR = Join-Path $root "data\dev"
$env:MSGR_REGISTRATION = "open"
$env:MSGR_WEB_DIR = Join-Path $root "web\dist"
$env:MSGR_DEBUG = "1"
Set-Location $root
go run ./cmd/server
