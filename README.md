# deadlock-na-lock

Force [Deadlock](https://store.steampowered.com/app/1422450/Deadlock/) onto North American
servers by blocking non-NA Steam Datagram Relay endpoints — with a Windows Firewall rule
scoped to `deadlock.exe`. No injection, no patched binaries, no DLLs loaded into the game.

## Why I made this

I play from Europe but my friends are on NA, so I want my matches on North American servers
even though that is not where I get the best ping. Deadlock has no setting for this.

The obvious candidate is the `citadel_region_override` convar, which sounds exactly like
what you would want — but it is **client-only**. I reverse engineered the retail client to
check, and it never reaches matchmaking: it changes which leaderboard you are shown and
nothing else. Launching with `+citadel_region_override 0` does not move you one metre closer
to a NA server.

Since the client cannot ask for a region, the only thing left that it *does* control is the
ping table it reports when queueing. That is what this tool shapes.

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

`-On` and `-Off` modify the Windows Firewall, so they need administrator rights. You do not
have to launch an elevated shell yourself — the script explains what it is about to change
and then requests elevation through UAC:

```
Administrator rights required
  why   : adding a Windows Firewall rule is an administrative operation
  what  : creates or removes ONE outbound Windows Firewall rule,
          'Deadlock NA Lock (block non-NA SDR relays)',
          scoped to the deadlock.exe binary only.
  scope : no other game, app, or system setting is modified.
  undo  : .\na-lock.ps1 -Off

Requesting elevation - approve the UAC prompt...
```

Arguments are forwarded to the elevated instance, which pauses before closing so the result
stays readable. Declining the UAC prompt changes nothing. Bad input (a `-GameExe` that does
not exist) is rejected *before* the prompt, so you never get asked to elevate for a run that
was going to fail anyway. `-Status` never needs elevation.

Set `-GameExe` if your Deadlock install is not on the default path baked into the script.

The rule matches on the game's exact image path, so it **fails open silently**: move or
reinstall Deadlock somewhere else and the rule still exists but matches no process, quietly
putting you back on EU servers. `-Status` guards against that — it reports `NOT ENFORCED`
in red, rather than `ACTIVE`, when the targeted binary is missing or when the active rule
points somewhere other than the `-GameExe` you expect.

Verify from the in-game console with `net_print_sdr_ping_times` ("Print current ping times
to SDR points of presence, and selected route"). Working output looks like this — every
direct measurement is North American, and European POPs are reached *via* a NA relay:

```
Obtained direct RTT measurements to relays in 6 POPs.  Closest 6 are:
  iad: 122ms
  atl: 129ms
  ord: 134ms
  dfw: 149ms
  sea: 176ms
  lax: 178ms

  iad: 122ms via direct route
  par: 199ms via iad (front=122ms, back=77ms)
  lhr: 205ms via iad (front=122ms, back=83ms)
  fra: 208ms via iad (front=122ms, back=86ms)
  ams: 209ms via iad (front=122ms, back=87ms)
```

`front=122ms` is the ping to your nearest reachable relay and `back=` is Valve's backbone
leg — the two terms of the estimate this tool exploits. European POPs reporting 199-209 ms
against `iad` at 122 ms is the intended result.

Ping estimates are only the input, though. Confirm actual placement after a match in
`game/citadel/console.log`:

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
European relay. Measured from Central Europe, that is close to a wash:

| | route | ping to `iad` |
|---|---|---|
| before | 43 ms to `par` + 76 ms backbone | 119 ms |
| after  | direct | 122 ms |

So it costs about 3 ms. Valve's backbone was already doing real work on the old path, and
going direct does not beat it — do not expect this to improve your latency.

The real cost is **failover headroom**. The usable relay pool shrinks sharply, because only
NA relays remain reachable:

```
before:  Relays: 24 valid, 0 great, 11 good+, 16 ok+, 7 ignored
after:   Relays:  6 valid, 0 great,  0 good+,  3 ok+, 0 ignored
```

The quality-tier collapse is not itself alarming — those are absolute latency bands, and
nothing rates `good+` at transatlantic distance. You only had `good+` relays before because
Paris was 28 ms away, on a route you were not actually playing on. But six relays with three
at `ok+` is thin: SDR migrates between relays routinely mid-match, and there are now fewer
places to migrate to, so expect the occasional rougher reconnect.

That redundancy cannot be bought back without unblocking a nearby European relay, which
would immediately make EU POPs cheap again and undo the entire effect.

The Game Coordinator picks a datacenter from every player's reported pings. Making yours
EU-hostile weights the decision heavily but does not unilaterally decide it, so a party full
of European players can still outvote you. Queueing with NA friends pushes the same
direction anyway — this mainly removes your own machine as the one vote dragging the lobby
back to Frankfurt.

## Scope

Client-side matchmaking preference only. This changes which Valve relays your own machine
will talk to. It does not modify the game, read or write game memory, or alter anything the
server is authoritative over.
