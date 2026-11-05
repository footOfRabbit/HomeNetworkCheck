param(
    [string]$TelegrafExe = "d:\githubProductPack\telegraf-1.40.1\telegraf.exe",
    [string]$ConfigPath = "d:\trae_works\20260926\network-monitor\telegraf\telegraf.conf"
)

$ErrorActionPreference = "Stop"

# ========== 自我提权 ==========
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
$isAdmin     = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Not running as Administrator. Re-launching with elevation..." -ForegroundColor Yellow

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }

    $argList = @(
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$scriptPath`"",
        "-TelegrafExe", "`"$TelegrafExe`"",
        "-ConfigPath", "`"$ConfigPath`""
    )

    Start-Process -FilePath "powershell.exe" `
                  -ArgumentList $argList `
                  -Verb RunAs `
                  -Wait
    exit
}
# ========== 提权结束 ==========


if (-not (Test-Path $TelegrafExe)) {
    throw "telegraf.exe not found: $TelegrafExe"
}

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

$service = Get-Service -Name telegraf -ErrorAction SilentlyContinue

if ($null -eq $service) {
    Write-Host "Installing Telegraf Windows service..." -ForegroundColor Cyan
    Write-Host "& '$TelegrafExe' --service install --config '$ConfigPath'"
    & $TelegrafExe --service install --config $ConfigPath
} else {
    Write-Host "Telegraf service already exists. Skip install." -ForegroundColor Yellow
}

Write-Host "Restarting and starting Telegraf service..." -ForegroundColor Cyan
Restart-Service -Name telegraf -ErrorAction SilentlyContinue
Start-Service -Name telegraf
Get-Service -Name telegraf
