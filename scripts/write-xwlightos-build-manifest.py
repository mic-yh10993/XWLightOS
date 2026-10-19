#!/usr/bin/env python3
"""Write a reproducible-input manifest for a XWLightOS 1.0 build artifact."""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(os.environ.get("ROOT", Path(__file__).resolve().parents[1])).resolve()
pkg_dir = Path(os.environ.get("PKGS", root / "artifacts" / "packages")).resolve()
out = Path(os.environ.get("OUT", pkg_dir / "XWLIGHTOS-1.0-BUILD-MANIFEST.json")).resolve()

if not pkg_dir.is_dir():
    raise SystemExit(f"package directory does not exist: {pkg_dir}")
packages = []
for path in sorted(pkg_dir.glob("*.deb")):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    packages.append({"file": path.name, "sha256": digest, "bytes": path.stat().st_size})
if not packages:
    raise SystemExit("no Debian packages found")

try:
    commit = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()
except subprocess.CalledProcessError:
    commit = "unavailable"

component_lock = pkg_dir / "XWLIGHTOS-1.0-COMPONENTS.txt"
source_lock = root / "packages" / "sources.lock.tsv"
binary_lock = root / "packages" / "binaries.lock.tsv"
manifest = {
    "schema": 1,
    "product": "XWLightOS",
    "version": "1.0",
    "source_commit": commit,
    "generated_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
    "packages": packages,
    "component_lock": component_lock.read_text(encoding="utf-8").splitlines()
    if component_lock.exists()
    else [],
    "package_layer": {
        "sources_lock": source_lock.read_text(encoding="utf-8").splitlines()
        if source_lock.exists()
        else [],
        "binaries_lock": binary_lock.read_text(encoding="utf-8").splitlines()
        if binary_lock.exists()
        else [],
    },
}
out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(out)
