# deadlock-na-lock

Force [Deadlock](https://store.steampowered.com/app/1422450/Deadlock/) onto North American
servers by blocking non-NA Steam Datagram Relay endpoints — with a Windows Firewall rule
scoped to `deadlock.exe`. No injection, no patched binaries, no DLLs loaded into the game.

## Why this works

Deadlock's Game Coordinator does not take a region preference from the client. There is a
`citadel_region_override` convar, and it is **cosmetic** — reverse engineering the retail
client shows its only three consumers are a debug panel label, the leaderboard region
selector, and a playtest survey field. It never reaches matchmaking.

What actually decides placement is the ping table the client reports when you queue:

```protobuf
CMsgClientToGCStartMatchmaking {
  match_info : CMsgStartFindingMatchInfo { region_mode, match_mode, mm_preference, ... }
  ping_times : CMsgRegionPingTimesClient { data_center_codes, ping_times }
}
```

`region_mode` is owned by the GC — it arrives in `CMsgClientWelcomeCitadel` and lives in the
`CSOCitadelParty` shared-object cache, so the client never authors it. `ping_times` is the
only part the client originates.

Steam Datagram Relay estimates your ping to every point of presence as:

```
ping(POP) = ping(nearest reachable relay) + backbone latency from that relay's POP to POP
```

That second term comes from the `typical_pings` matrix Valve ships in the SDR network config.
So if every European relay is unreachable, EU POPs get estimated *through a North American
relay* and report roughly double their true latency, while NA POPs report their real direct
ping. The GC sees NA as your only low-ping region.

The protocol already treats unreachable regions as normal — `CMsgClientPingData` carries a
`region_ping_failed_bitmask` field.

## Usage

```powershell
python refresh-relays.py        # pull current relay IPs from Valve
.\na-lock.ps1 -On               # elevated
.\na-lock.ps1 -Status           # works unelevated
.\na-lock.ps1 -Off              # full rollback
```

`na-lock.ps1 -On` needs an elevated PowerShell session. Set `-GameExe` if your Deadlock
install is not on the default path baked into the script.

The rule matches on the game's exact image path, so it **fails open silently**: move or
reinstall Deadlock somewhere else and the rule still exists but matches no process, quietly
putting you back on EU servers. `-Status` guards against that — it reports `NOT ENFORCED`
in red, rather than `ACTIVE`, when the targeted binary is missing or when the active rule
points somewhere other than the `-GameExe` you expect.

Verify from the in-game console with `net_print_sdr_ping_times` ("Print current ping times
to SDR points of presence, and selected route") — EU POPs should show roughly double their
real latency. Confirm actual placement in `game/citadel/console.log`:

```
[Networking]         Remote host is in data center 'iad'
```

## What gets blocked

One outbound UDP rule, scoped to the `deadlock.exe` image path, covering every relay IP in
a non-NA point of presence. POPs kept reachable: `iad`, `atl`, `ord`, `dfw`, `lax`, `sea`.

Because the rule is program-scoped, Steam itself and every other SDR game (CS2, Dota 2, TF2)
are unaffected.

Re-run `refresh-relays.py` periodically. Valve rotates relay IPs, and a new European relay
that is not in `relays.txt` is an unblocked path back to an EU server. The script also warns
on stderr if Valve ever publishes IPv6 relays, which the firewall rule does not cover.

## Trade-offs

Your traffic now reaches NA relays directly instead of entering Valve's backbone at a nearby
European relay. From Central Europe that tends to *lower* the total — a measured 119 ms
(43 ms to Paris + 76 ms backbone to Virginia) becomes a ~90-100 ms direct path — but you
give up backbone route optimization and relay failover, so expect less resilience to jitter
and loss.

The Game Coordinator picks a datacenter from every player's reported pings. Making yours
EU-hostile weights the decision heavily but does not unilaterally decide it, so a party full
of European players can still outvote you.

## Scope

Client-side matchmaking preference only. This changes which Valve relays your own machine
will talk to. It does not modify the game, read or write game memory, or alter anything the
server is authoritative over.
