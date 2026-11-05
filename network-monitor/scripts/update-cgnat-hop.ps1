# update-cgnat-hop.ps1
#
# Keeps the CGNAT first-hop IP inside telegraf.conf up to date.
#
# Why: the ISP-side CGNAT gateway (an address inside 100.64.0.0/10) is not
# stable over time. When it changes, telegraf would keep pinging a stale IP.
# This script detects the current CGNAT hop with "tracert" and rewrites the
# managed line of telegraf.conf in place. Telegraf runs with
# "--watch-config poll", so the config change triggers an automatic reload.
#
# The managed line is identified by the marker comment "@cgnat-hop":
#
#     "100.69.56.1",     # @cgnat-hop ...
#
# Rules:
#   - Only the IP inside the quotes on the marker line is replaced.
#   - Everything after the IP on that line (its comment) is preserved.
#   - The previous value is kept as a single rolling comment tagged
#     "@cgnat-hop-old", so the file stays readable.
#   - A timestamped history is appended to scripts\logs\cgnat-hop.log.
#   - If no CGNAT hop is detected, or the value did not change, the config
#     is left untouched.
#
# This file is intentionally ASCII-only. Non-ASCII text in a .ps1 can break
# parsing depending on the console code page on Windows. The Chinese comment
# that already lives on the marker line is preserved because the script never
# rewrites it from a literal; it only swaps the quoted IP and reuses the rest.

param(
    [string]$ConfigPath = 'd:\trae_works\20260926\network-monitor\telegraf\telegraf.conf',
    [string]$LogPath    = 'd:\trae_works\20260926\network-monitor\scripts\logs\cgnat-hop.log',
    [string]$Target     = '223.5.5.5',
    [int]$MaxHops       = 12,
    [int]$WaitMs        = 800
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)
    $line = '[' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '] ' + $Message
    $dir = Split-Path -Parent $LogPath
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

# ---- 1. detect the current CGNAT hop -------------------------------------
$hopLineRe = '^\s*(\d+)\s+(.*)$'
$ipRe      = '\b\d{1,3}(?:\.\d{1,3}){3}\b'
# 100.64.0.0/10  ->  second octet in 64..127
$cgnatRe   = '^100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'

$lines = & tracert -d -4 -h $MaxHops -w $WaitMs $Target 2>$null
$detected = $null
foreach ($line in $lines) {
    if ($line -notmatch $hopLineRe) { continue }
    $rest = $Matches[2]
    if ($rest -match $ipRe) {
        $ip = $Matches[0]
        if ($ip -match $cgnatRe) { $detected = $ip; break }
    }
}

if (-not $detected) {
    Write-Log ("WARN no CGNAT hop (100.64.0.0/10) found on the path to {0}; config unchanged" -f $Target)
    exit 0
}

# ---- 2. read telegraf.conf, preserving BOM / encoding ---------------------
if (-not (Test-Path $ConfigPath)) { throw ("config not found: {0}" -f $ConfigPath) }

$bytes  = [System.IO.File]::ReadAllBytes($ConfigPath)
$hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$enc    = New-Object System.Text.UTF8Encoding($hadBom)
$text   = [System.IO.File]::ReadAllText($ConfigPath, $enc)

if ($text -match "`r`n") { $nl = "`r`n" } elseif ($text -match "`n") { $nl = "`n" } else { $nl = "`r`n" }
$lines = $text -split "`r`n|`n|`r"

# ---- 3. locate the managed line and read its current value ---------------
$ipPattern = '^\s*"(?<ip>\d{1,3}(?:\.\d{1,3}){3})"\s*,?\s*(?<cmt>#.*)?$'
$markerIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l -match '@cgnat-hop' -and -not $l.TrimStart().StartsWith('#')) { $markerIdx = $i; break }
}

if ($markerIdx -lt 0) {
    Write-Log ("ERROR marker '@cgnat-hop' not found in {0}; config unchanged" -f $ConfigPath)
    exit 1
}
if ($lines[$markerIdx] -notmatch $ipPattern) {
    Write-Log "ERROR marker line is not in the expected format; config unchanged"
    exit 1
}

$oldIp = $Matches['ip']
$cmt   = $Matches['cmt']
if (-not $cmt) { $cmt = '# @cgnat-hop' }

if ($oldIp -eq $detected) {
    Write-Log ("OK no change (current CGNAT hop {0})" -f $detected)
    exit 0
}

# ---- 4. rebuild the managed block ----------------------------------------
$ipQuoted = '"' + $detected + '",'
$pad      = 23 - (4 + $ipQuoted.Length)
if ($pad -lt 1) { $pad = 1 }
$newActive  = ('    ' + $ipQuoted + (' ' * $pad) + $cmt)
$oldComment = ('    # "' + $oldIp + '",   # @cgnat-hop-old previous CGNAT hop, replaced on ' +
               (Get-Date).ToString('yyyy-MM-dd') + ' (kept for reference)')

$newLines = New-Object System.Collections.Generic.List[string]
foreach ($l in $lines) {
    if ($l -match '@cgnat-hop-old') { continue }   # rolling history: keep only one
    if ($l -match '@cgnat-hop' -and -not $l.TrimStart().StartsWith('#')) {
        $newLines.Add($oldComment)
        $newLines.Add($newActive)
        continue
    }
    $newLines.Add($l)
}

[System.IO.File]::WriteAllText($ConfigPath, [string]::Join($nl, $newLines), $enc)
Write-Log ("CHANGED CGNAT hop {0} -> {1}" -f $oldIp, $detected)
