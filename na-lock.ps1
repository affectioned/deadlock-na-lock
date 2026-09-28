<#
.SYNOPSIS
  Force Deadlock onto North American servers by blocking non-NA Steam Datagram
  Relay (SDR) endpoints for deadlock.exe only.

.DESCRIPTION
  Deadlock's Game Coordinator picks a match datacenter from the ping times the
  client reports in CMsgClientToGCStartMatchmaking.ping_times. SDR estimates the
  ping to every POP as (ping to your nearest relay + Valve's backbone latency
  from that relay's POP to the target POP). Blocking every non-NA relay leaves
  only NA relays reachable, so EU POPs get estimated through a NA relay and
  report roughly double their true latency. The GC then never places you in EU.

  Rules are scoped to the deadlock.exe binary, so Steam itself and every other
  Source/SDR game (CS2, Dota 2, ...) are untouched.

.NOTES
  Requires an elevated PowerShell session. Run refresh-relays.py first, and
  again whenever Valve rotates relay IPs.

.EXAMPLE
  .\na-lock.ps1 -On
  .\na-lock.ps1 -Status
  .\na-lock.ps1 -Off
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'On')]    [switch]$On,
    [Parameter(ParameterSetName = 'Off')]   [switch]$Off,
    [Parameter(ParameterSetName = 'Status')][switch]$Status,

    [string]$GameExe   = 'F:\SteamLibrary\steamapps\common\Deadlock\game\bin\win64\deadlock.exe',
    [string]$RelayFile,

    # Set automatically when the script re-launches itself elevated. Keeps the
    # new window open at the end so you can actually read the result.
    [switch]$Relaunched
)

$ErrorActionPreference = 'Stop'

$ScriptPath = $MyInvocation.MyCommand.Path
if (-not $RelayFile) {
    $RelayFile = Join-Path (Split-Path -Parent $ScriptPath) 'relays.txt'
}
$RuleName = 'Deadlock NA Lock (block non-NA SDR relays)'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Explains why elevation is needed, then re-launches this script through UAC with
# the same arguments. Returns $true if it elevated (caller should stop).
function Request-Elevation {
    param([Parameter(Mandatory)][string]$Reason)

    if (Test-Admin) { return $false }

    Write-Host ''
    Write-Host 'Administrator rights required' -ForegroundColor Yellow
    Write-Host "  why   : $Reason"
    Write-Host "  what  : creates or removes ONE outbound Windows Firewall rule,"
    Write-Host "          '$RuleName',"
    Write-Host '          scoped to the deadlock.exe binary only.'
    Write-Host '  scope : no other game, app, or system setting is modified.'
    Write-Host '  undo  : .\na-lock.ps1 -Off'
    Write-Host ''

    if ($Relaunched) {
        throw 'Already re-launched but still not elevated. Start PowerShell as Administrator and re-run.'
    }

    Write-Host 'Requesting elevation - approve the UAC prompt...' -ForegroundColor Cyan

    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$ScriptPath`"",
        $(if ($On) { '-On' } else { '-Off' }),
        '-GameExe',   "`"$GameExe`"",
        '-RelayFile', "`"$RelayFile`"",
        '-Relaunched'
    )

    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path `
                      -Verb RunAs -ArgumentList $argList -Wait
    } catch {
        throw "Elevation was declined or failed. Nothing has been changed.`n$($_.Exception.Message)"
    }
    return $true
}

function Get-RelayIps {
    if (-not (Test-Path $RelayFile)) {
        throw "Relay list not found: $RelayFile`nRun: python refresh-relays.py"
    }
    $ips = Get-Content $RelayFile |
        ForEach-Object { ($_ -split '#')[0].Trim() } |
        Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }
    if (-not $ips) { throw "No relay IPs parsed from $RelayFile" }
    return $ips
}

switch ($PSCmdlet.ParameterSetName) {

    'On' {
        # Validate before prompting for UAC, so a bad path fails without a pointless prompt.
        if (-not (Test-Path $GameExe)) { throw "deadlock.exe not found: $GameExe" }
        if (Request-Elevation -Reason 'adding a Windows Firewall rule is an administrative operation') { break }

        $ips = Get-RelayIps
        Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule

        # UDP only: SDR relay traffic is UDP. Leaves any TCP use of these hosts alone.
        New-NetFirewallRule -DisplayName $RuleName `
            -Direction Outbound -Action Block -Protocol UDP `
            -Program $GameExe -RemoteAddress $ips `
            -Description 'Blocks non-North-American Valve SDR relays so Deadlock matchmaking reports NA as the only low-ping region.' |
            Out-Null

        Write-Host "NA lock ENABLED - blocked $($ips.Count) non-NA relay IPs for deadlock.exe." -ForegroundColor Green
        Write-Host "Verify in game with: net_print_sdr_ping_times"
    }

    'Off' {
        if (Request-Elevation -Reason 'removing a Windows Firewall rule is an administrative operation') { break }
        $existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
        if ($existing) {
            $existing | Remove-NetFirewallRule
            Write-Host 'NA lock DISABLED - firewall rule removed.' -ForegroundColor Yellow
        } else {
            Write-Host 'NA lock was not active; nothing to remove.'
        }
    }

    'Status' {
        $rule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
        if (-not $rule) {
            Write-Host 'NA lock: INACTIVE' -ForegroundColor Yellow
            return
        }
        $addrs = ($rule | Get-NetFirewallAddressFilter).RemoteAddress
        $app   = ($rule | Get-NetFirewallApplicationFilter).Program

        # The rule matches on the exact image path. If that binary moved or was
        # reinstalled elsewhere, the rule still exists but matches no process --
        # a silent fail-open back to EU servers. Surface that loudly.
        $pathOk = Test-Path -LiteralPath $app
        $drift  = ($app -and $GameExe -and ($app -ne $GameExe))

        if ($pathOk -and -not $drift) {
            Write-Host 'NA lock: ACTIVE' -ForegroundColor Green
        } else {
            Write-Host 'NA lock: NOT ENFORCED' -ForegroundColor Red
        }
        Write-Host "  enabled       : $($rule.Enabled)"
        Write-Host "  blocked IPs   : $($addrs.Count)"
        Write-Host "  scoped to     : $app"

        if (-not $pathOk) {
            Write-Warning @"
The rule targets a binary that does not exist:
  $app
The rule matches nothing, so Deadlock traffic is NOT being filtered and you can
land on EU servers again. Re-run with -On (pass -GameExe if the install moved).
"@
        }
        elseif ($drift) {
            Write-Warning @"
The active rule targets a different binary than this script's -GameExe default:
  rule    : $app
  expected: $GameExe
Whichever is wrong, only the path in the rule is actually enforced. Re-run -On
with the correct -GameExe to realign them.
"@
        }
    }
}

# This window was spawned by UAC and would vanish on exit, taking the result with
# it. Hold it open so the outcome is actually readable.
if ($Relaunched) {
    Write-Host ''
    Read-Host 'Done - press Enter to close this elevated window'
}
