# setup-cgnat-automation.ps1
#
# One-time setup for "Plan B": keep the CGNAT first-hop IP in telegraf.conf
# up to date automatically.
#
# It does two things:
#   1. Adds "--watch-config poll" to the telegraf Windows service command line,
#      so telegraf reloads its config automatically whenever the file changes.
#      ("poll" is required on Windows; "notify" is not supported there.)
#   2. Registers a Windows Scheduled Task that runs update-cgnat-hop.ps1 once a
#      day. That script detects the current CGNAT hop and rewrites the managed
#      "@cgnat-hop" line of telegraf.conf, which then triggers the reload.
#
# Both steps need Administrator rights, so the script re-launches itself
# elevated when needed.
#
# This file is intentionally ASCII-only.

param(
    [string]$TelegrafExe  = 'D:\githubProductPack\telegraf-1.40.1\telegraf.exe',
    [string]$ConfigPath   = 'd:\trae_works\20260926\network-monitor\telegraf\telegraf.conf',
    [string]$UpdateScript = 'd:\trae_works\20260926\network-monitor\scripts\update-cgnat-hop.ps1',
    [string]$TaskName     = 'NetworkMonitor-UpdateCgnatHop',
    [string]$DailyAt      = '04:00',
    [string]$ServiceName  = 'telegraf'
)

$ErrorActionPreference = 'Stop'

# ========== self-elevation ==========
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
$isAdmin     = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host 'Not running as Administrator. Re-launching with elevation...' -ForegroundColor Yellow

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }

    $argList = @(
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$scriptPath`"",
        '-TelegrafExe', "`"$TelegrafExe`"",
        '-ConfigPath', "`"$ConfigPath`"",
        '-UpdateScript', "`"$UpdateScript`"",
        '-TaskName', "`"$TaskName`"",
        '-DailyAt', "`"$DailyAt`"",
        '-ServiceName', "`"$ServiceName`""
    )

    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait
    exit
}
# ========== elevation done ==========

# The elevated window closes on its own, so keep a transcript for review.
$logDir = Join-Path (Split-Path -Parent $UpdateScript) 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
Start-Transcript -Path (Join-Path $logDir 'setup-plan-b.log') -Force | Out-Null

foreach ($p in @($TelegrafExe, $ConfigPath, $UpdateScript)) {
    if (-not (Test-Path $p)) { throw ("not found: {0}" -f $p) }
}

$svc = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $ServiceName)
if (-not $svc) { throw ("service not found: {0}" -f $ServiceName) }

# ---- 1. make telegraf watch its config -----------------------------------
$currentPath = $svc.PathName
Write-Host ('current binPath : ' + $currentPath) -ForegroundColor Cyan

if ($currentPath -match '--watch-config') {
    Write-Host 'watch-config already present, skipping.' -ForegroundColor Yellow
} else {
    $newPath = $currentPath.Trim() + ' --watch-config poll'
    Write-Host 'updating binPath : ' -ForegroundColor Cyan
    Write-Host ('  ' + $newPath)
    & sc.exe config $ServiceName 'binPath=' $newPath | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw 'sc.exe config binPath failed' }
}

Write-Host 'restarting telegraf service...' -ForegroundColor Cyan
if ($svc.State -eq 'Running') { Stop-Service -Name $ServiceName -Force }
Start-Service -Name $ServiceName

# ---- 2. register the daily detection task --------------------------------
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $UpdateScript)
$trigger = New-ScheduledTaskTrigger -Daily -At $DailyAt
$taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $taskPrincipal -Settings $settings -Force | Out-Null
Write-Host ('scheduled task registered: {0} (daily at {1})' -f $TaskName, $DailyAt) -ForegroundColor Green

# ---- 3. result ------------------------------------------------------------
Start-Sleep -Seconds 3
$svc2 = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $ServiceName)
Write-Host ''
Write-Host '=== result ===' -ForegroundColor Green
Write-Host ('service state : ' + $svc2.State)
Write-Host ('binPath       : ' + $svc2.PathName)

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host ('task          : {0} / state={1} / nextRun={2}' -f $task.TaskName, $task.State, $info.NextRunTime)
}

Stop-Transcript | Out-Null
