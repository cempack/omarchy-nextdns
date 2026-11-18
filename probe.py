#!/usr/bin/env python3
"""Collect NextDNS state for the Omarchy bar and print one JSON object.

Usage: probe.py <nextdns-cli> [--net] [--stats <api-key-file>]
       probe.py --save-key <api-key-file>   (key on stdin)

Local facts come from `nextdns status` and `nextdns config`, which need no
root. (cache-stats and friends re-run themselves through sudo, which would
wake the fingerprint reader from the bar, so they are deliberately unused.) With --net, the helper
also asks https://test.nextdns.io whether this machine's DNS really resolves
through NextDNS, and which server and protocol it uses. With --stats, it reads
an API key from the given file and fetches the last 24 hours of analytics for
the configured profile from https://api.nextdns.io.

Everything printed is validated and length-bounded: the shell displays it.
"""

import json
import re
import subprocess
import sys
import os
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

TIMEOUT = 5
MAX_BYTES = 16384
TEST_URL = "https://test.nextdns.io/"
API_URL = "https://api.nextdns.io/profiles/"
API_BYTES = 262144

PROFILE_RE = re.compile(r"^[a-z0-9]{6}$")
SAFE_RE = re.compile(r"[^A-Za-z0-9 .:_\-\[\]/]")
KEY_RE = re.compile(r"^[A-Za-z0-9]{16,128}$")
DOMAIN_RE = re.compile(r"^[A-Za-z0-9_.\-]{1,253}$")


def clean(value, limit=64):
    return SAFE_RE.sub("", str(value or ""))[:limit]


def run(cli, *args):
    try:
        proc = subprocess.run(
            [cli, *args], capture_output=True, text=True, timeout=TIMEOUT
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return proc.stdout[:MAX_BYTES] if proc.returncode == 0 else None


def read_config(cli):
    out = run(cli, "config")
    if out is None:
        return {}
    config = {}
    for line in out.splitlines():
        key, _, value = line.strip().partition(" ")
        if key:
            config.setdefault(key, []).append(value.strip())
    return config


def default_profile(values):
    # A profile line may hold conditional entries ("10.0.0.0/8=abc123 def456");
    # the bare id without "=" is the default one.
    for value in values:
        for token in value.split():
            if "=" not in token and PROFILE_RE.match(token):
                return token
    return ""


def connection_test():
    # The endpoint answers JSON only to curl; other agents get an HTML page.
    request = urllib.request.Request(TEST_URL, headers={"User-Agent": "curl/8"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as resp:
            data = json.loads(resp.read(MAX_BYTES))
    except Exception:
        return {"reachable": False}
    if not isinstance(data, dict):
        return {"reachable": False}
    status = clean(data.get("status"), 16)
    return {
        "reachable": True,
        "using": status == "ok",
        "protocol": clean(data.get("protocol"), 16),
        "server": clean(data.get("server"), 48),
        "clientIp": clean(data.get("client"), 46),
        "device": clean(data.get("deviceName"), 48),
    }


def api_get(key, path):
    request = urllib.request.Request(
        API_URL + path, headers={"X-Api-Key": key, "User-Agent": "omarchy-nextdns"}
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT + 3) as resp:
        data = json.loads(resp.read(API_BYTES))
    if not isinstance(data, dict) or not isinstance(data.get("data"), list):
        raise ValueError("unexpected response")
    return data["data"]


def count(value):
    try:
        n = int(value)
    except (TypeError, ValueError):
        return 0
    return n if 0 <= n < 10**12 else 0


def read_key(path):
    try:
        with open(os.path.expanduser(path)) as handle:
            key = handle.read(256).strip()
    except OSError:
        return None
    return key if KEY_RE.match(key) else None


def analytics(key_file, profile):
    if not profile:
        return {"state": "noprofile"}
    key = read_key(key_file)
    if key is None:
        return {"state": "nokey"}
    base = profile + "/analytics/"
    calls = {
        "status": base + "status?from=-24h",
        "series": base + "status;series?from=-24h&interval=1h",
        "top": base + "domains?status=blocked&from=-24h&limit=5",
    }
    try:
        with ThreadPoolExecutor(max_workers=3) as pool:
            futures = {name: pool.submit(api_get, key, path) for name, path in calls.items()}
            raw = {name: future.result() for name, future in futures.items()}
    except urllib.error.HTTPError as err:
        return {"state": "auth" if err.code in (401, 403) else "error"}
    except Exception:
        return {"state": "error"}

    by_status = {}
    for row in raw["status"]:
        if isinstance(row, dict):
            by_status[clean(row.get("status"), 16)] = count(row.get("queries"))
    total = sum(by_status.values())

    # One [total, blocked] pair per hour, oldest first.
    hours = 0
    series_rows = [r for r in raw["series"] if isinstance(r, dict) and isinstance(r.get("queries"), list)]
    for row in series_rows:
        hours = max(hours, min(len(row["queries"]), 48))
    series = [[0, 0] for _ in range(hours)]
    for row in series_rows:
        blocked = row.get("status") == "blocked"
        for i, value in enumerate(row["queries"][:hours]):
            series[i][0] += count(value)
            if blocked:
                series[i][1] += count(value)

    top = []
    for row in raw["top"][:5]:
        domain = str(row.get("domain", "")) if isinstance(row, dict) else ""
        if DOMAIN_RE.match(domain):
            top.append({"domain": domain, "queries": count(row.get("queries"))})

    return {
        "state": "ok",
        "total": total,
        "blocked": by_status.get("blocked", 0),
        "series": series,
        "top": top,
    }


def save_key(path):
    # The key arrives on stdin so it never shows up in the process list.
    key = sys.stdin.read(512).strip()
    if not KEY_RE.match(key):
        return {"ok": False, "error": "invalid"}
    path = os.path.expanduser(path)
    try:
        os.makedirs(os.path.dirname(path) or ".", mode=0o700, exist_ok=True)
        tmp = path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(key + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError:
        return {"ok": False, "error": "write"}
    return {"ok": True}


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--save-key":
        print(json.dumps(save_key(sys.argv[2])))
        return
    if len(sys.argv) < 2:
        print(json.dumps({"ok": False}))
        return
    cli = sys.argv[1]
    status = run(cli, "status")
    result = {
        "ok": True,
        "installed": status is not None,
        "running": (status or "").strip() == "running",
    }
    if result["installed"]:
        config = read_config(cli)
        result["profile"] = default_profile(config.get("profile", []))
        result["listen"] = clean((config.get("listen") or [""])[0], 48)
    args = sys.argv[2:]
    if "--net" in args:
        result["net"] = connection_test()
    if "--stats" in args and result["installed"]:
        index = args.index("--stats")
        key_file = args[index + 1] if index + 1 < len(args) else ""
        result["stats"] = analytics(key_file, result.get("profile", ""))
    print(json.dumps(result))


if __name__ == "__main__":
    main()
