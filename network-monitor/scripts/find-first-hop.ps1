param(
    [string]$Target = "8.8.8.8"
)

$ErrorActionPreference = "Stop"

Write-Host "Running tracert -d $Target ..." -ForegroundColor Cyan
$lines = tracert -d $Target
$lines | ForEach-Object { $_ }

$ipv4Pattern = '\b(?:\d{1,3}\.){3}\d{1,3}\b'
$hops = @()

foreach ($line in $lines) {
    if ($line -match '^\s*(\d+)\s+') {
        $hopNumber = [int]$matches[1]
        $ipMatch = [regex]::Match($line, $ipv4Pattern)
        if ($ipMatch.Success) {
            $hops += [pscustomobject]@{
                Hop = $hopNumber
                IP  = $ipMatch.Value
            }
        }
    }
}

Write-Host ""
Write-Host "Parsed hops:" -ForegroundColor Green
$hops | Format-Table -AutoSize

Write-Host ""
Write-Host "How to read it:" -ForegroundColor Yellow
Write-Host "1. Hop 1 is usually your Xiaomi router."
Write-Host "2. The first ISP-side address at hop 2 or hop 3 is often the best first-hop candidate."
Write-Host "3. Add that IP to telegraf.conf and continue observing."
