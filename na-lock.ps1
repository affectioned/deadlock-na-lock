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
    [string]$RelayFile
)

$ErrorActionPreference = 'Stop'

if (-not $RelayFile) {
    $root = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RelayFile = Join-Path $root 'relays.txt'
}
$RuleName = 'Deadlock NA Lock (block non-NA SDR relays)'

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This needs an elevated PowerShell session (Run as Administrator).'
    }
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
        Assert-Admin
        if (-not (Test-Path $GameExe)) { throw "deadlock.exe not found: $GameExe" }

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
        Assert-Admin
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
        Write-Host 'NA lock: ACTIVE' -ForegroundColor Green
        Write-Host "  enabled       : $($rule.Enabled)"
        Write-Host "  blocked IPs   : $($addrs.Count)"
        Write-Host "  scoped to     : $app"
    }
}
