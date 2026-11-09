#!/usr/bin/env python3
"""Register extra locales in upstream i18n.json and copy overlay files into the upstream tree."""
import json, shutil, sys
from pathlib import Path

EXTRA_LOCALES = ["lt"]
overlay, upstream = Path(sys.argv[1]), Path(sys.argv[2])

cfg_path = upstream / "i18n.json"
cfg = json.loads(cfg_path.read_text())
targets = cfg["locale"]["targets"]
for loc in EXTRA_LOCALES:
    if loc not in targets:
        targets.append(loc)
cfg["locale"]["targets"] = sorted(targets)
cfg_path.write_text(json.dumps(cfg, indent=2) + "\n")

copied = 0
for src in overlay.rglob("*"):
    if src.is_file():
        dst = upstream / src.relative_to(overlay)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        copied += 1

registered = json.loads(cfg_path.read_text())["locale"]["targets"]
missing = [l for l in EXTRA_LOCALES if l not in registered or not (upstream / f"packages/i18n/locales/{l}/common.json").is_file()]
if missing or copied == 0:
    sys.exit(f"overlay failed: missing={missing} copied={copied}")
print(f"overlay ok: locales {EXTRA_LOCALES} registered, {copied} file(s) copied")
