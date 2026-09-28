#!/usr/bin/env python3
"""Regenerate relays.txt from Valve's live SDR network config.

Valve adds and retires relays, so re-run this whenever a new EU server slips
through. Writes relays.txt (one IPv4 per line) next to this script; na-lock.ps1
reads that file.
"""
import json
import os
import sys
import urllib.request

APPID = 1422450
URL = f"https://api.steampowered.com/ISteamApps/GetSDRConfig/v1?appid={APPID}"

# POPs to keep reachable. Everything else gets blocked for deadlock.exe.
NA_POPS = {"atl", "dfw", "eat", "iad", "lax", "ord", "sea"}

here = os.path.dirname(os.path.abspath(__file__))

with urllib.request.urlopen(URL, timeout=60) as r:
    cfg = json.load(r)

pops = cfg["pops"]
blocked, kept, ipv6_seen = [], [], []

for code, pop in sorted(pops.items()):
    for relay in pop.get("relays") or []:
        if relay.get("ipv6"):
            ipv6_seen.append((code, relay["ipv6"]))
        ip = relay.get("ipv4")
        if not ip:
            continue
        (kept if code in NA_POPS else blocked).append((code, ip))

if ipv6_seen:
    print(f"WARNING: {len(ipv6_seen)} IPv6 relays now exist and are NOT blocked "
          f"by na-lock.ps1. SDR could reach EU over IPv6.", file=sys.stderr)
    for code, ip in ipv6_seen:
        print(f"  {code} {ip}", file=sys.stderr)

out = os.path.join(here, "relays.txt")
with open(out, "w", encoding="utf-8") as f:
    f.write(f"# SDR config revision {cfg.get('revision')}\n")
    f.write(f"# blocked={len(blocked)} kept(NA)={len(kept)}\n")
    for code, ip in blocked:
        f.write(f"{ip} # {code}\n")

print(f"revision {cfg.get('revision')}")
print(f"blocking {len(blocked)} relay IPs across "
      f"{len({c for c, _ in blocked})} non-NA POPs")
print(f"keeping  {len(kept)} relay IPs across "
      f"{len({c for c, _ in kept})} NA POPs")
print(f"wrote {out}")
