param(
    [string]$TelegrafExe = "d:\githubProductPack\telegraf-1.40.1\telegraf.exe",
    [string]$ConfigPath = "d:\trae_works\20260926\network-monitor\telegraf\telegraf.conf"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $TelegrafExe)) {
    throw "telegraf.exe not found: $TelegrafExe"
}

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

Write-Host "Testing Telegraf config..." -ForegroundColor Cyan
Write-Host "& '$TelegrafExe' --config '$ConfigPath' --test"
& $TelegrafExe --config $ConfigPath --test
