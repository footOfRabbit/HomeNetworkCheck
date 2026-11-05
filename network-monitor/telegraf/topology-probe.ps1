# topology-probe.ps1
#
# Traceroute probe for the raw network monitor.
# Runs "tracert" against a fixed set of public targets and prints InfluxDB
# line protocol to stdout, so telegraf can consume it via [[inputs.exec]].
#
# Output:
#   measurement : traceroute
#   tags        : target, hop, addr
#   field       : rtt_ms (float, -1.00 means the hop did not respond)
#
#   "addr" is a tag (not a field) so a query can do
#   group(columns:["target","hop"]) |> last() and get exactly one row per hop
#   with that hop's most recent IP. It also avoids the Flux pivot type clash
#   between a string field and the float rtt_ms field.
#
# Notes:
#   - Keep this file ASCII-only. Non-ASCII text can break PowerShell parsing
#     depending on the console code page on Windows.
#   - Unresponsive hops are still emitted, with addr="*", so the hop order
#     stays visible in the dashboard.
#   - The four targets run in parallel to keep the total runtime short.

param(
    [int]$MaxHops    = 16,
    [int]$WaitMs     = 800,
    [int]$TimeoutSec = 90
)

$ErrorActionPreference = 'SilentlyContinue'
# Keep the progress stream quiet so nothing but line protocol reaches stdout.
$ProgressPreference    = 'SilentlyContinue'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

$targets = @('223.5.5.5', '119.29.29.29', '8.8.8.8', '1.1.1.1')

$worker = {
    param($Target, $MaxHops, $WaitMs)

    $inv    = [System.Globalization.CultureInfo]::InvariantCulture
    $lines  = & tracert -d -4 -h $MaxHops -w $WaitMs $Target 2>$null

    $hopLine = '^\s*(\d+)\s+(.*)$'
    $ipRe    = '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
    # tracert prints "ms" for most values but a localized unit for "<1 ms"
    # (on zh-CN Windows that is U+6BEB U+79D2). Keep this file ASCII-only, so
    # the unicode escape is written for the .NET regex engine instead of the
    # literal characters.
    $msRe    = '(\d+)\s*(?:ms|\u6BEB\u79D2)'

    foreach ($line in $lines) {
        if ($line -notmatch $hopLine) { continue }
        $hop  = [int]$Matches[1]
        $rest = $Matches[2]

        $addr = '*'
        if ($rest -match $ipRe) { $addr = $Matches[0] }

        $times = @()
        foreach ($m in [regex]::Matches($rest, $msRe)) {
            $times += [double]$m.Groups[1].Value
        }
        if ($times.Count -gt 0) {
            $rtt = [math]::Round((($times | Measure-Object -Average).Average), 2)
        } else {
            $rtt = -1
        }

        $rttStr = $rtt.ToString('F2', $inv)
        ('traceroute,target={0},hop={1},addr={2} rtt_ms={3}' -f $Target, $hop, $addr, $rttStr)
    }
}

$jobs = foreach ($t in $targets) {
    Start-Job -ScriptBlock $worker -ArgumentList $t, $MaxHops, $WaitMs
}

$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ($true) {
    $running = @($jobs | Where-Object { $_.State -eq 'Running' })
    if ($running.Count -eq 0) { break }
    if ((Get-Date) -gt $deadline) { break }
    Start-Sleep -Milliseconds 300
}

foreach ($job in $jobs) {
    Receive-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job  -Job $job -Force -ErrorAction SilentlyContinue
}
