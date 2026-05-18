"""Add missing `resolved` and `integrity` fields to a package-lock.json.

Newer npm versions may omit these for registry packages. prefetch-npm-deps
requires them to fetch tarballs correctly.

Usage: python3 fix-lockfile.py package-lock.json
"""
import json
import sys
import re
import urllib.request
import urllib.error

lockfile = sys.argv[1]

with open(lockfile) as f:
    data = json.load(f)

packages = data.get("packages", {})
patched = 0
registry_cache = {}


def get_registry_info(name, version):
    cache_key = f"{name}@{version}"
    if cache_key in registry_cache:
        return registry_cache[cache_key]

    url = f"https://registry.npmjs.org/{name}/{version}"
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=30) as resp:
            info = json.loads(resp.read())
            dist = info.get("dist", {})
            result = (dist.get("tarball"), dist.get("integrity"))
            registry_cache[cache_key] = result
            return result
    except (urllib.error.URLError, json.JSONDecodeError) as e:
        print(f"  WARNING: could not fetch {name}@{version}: {e}", file=sys.stderr)
        registry_cache[cache_key] = (None, None)
        return (None, None)


for key, pkg in packages.items():
    if not key or pkg.get("link"):
        continue

    version = pkg.get("version")
    if not version:
        continue

    needs_resolved = "resolved" not in pkg
    needs_integrity = "integrity" not in pkg

    if not needs_resolved and not needs_integrity:
        continue

    # Extract the actual package name: last node_modules/<name> segment
    # e.g. "node_modules/foo/node_modules/@bar/baz" -> "@bar/baz"
    # e.g. "packages/coding-agent/node_modules/@anthropic-ai/sdk" -> "@anthropic-ai/sdk"
    parts = key.split("node_modules/")
    if len(parts) < 2:
        continue
    name = parts[-1]

    # Skip workspace packages (they start with packages/ not node_modules/)
    if not name or name.startswith("."):
        continue

    resolved_url, integrity = get_registry_info(name, version)

    if needs_resolved and resolved_url:
        pkg["resolved"] = resolved_url
    if needs_integrity and integrity:
        pkg["integrity"] = integrity

    if resolved_url or integrity:
        patched += 1


with open(lockfile, "w") as f:
    json.dump(data, f, indent=2)

print(f"fix-lockfile.py: patched {patched} packages")
