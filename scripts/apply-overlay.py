#!/usr/bin/env python3
"""Register extra locales in upstream i18n.json, copy overlay files into the upstream tree,
then apply patches/*.patch (git apply; any patch that no longer applies fails the build)."""
import json, shutil, subprocess, sys
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
patches = sorted((Path(__file__).resolve().parent.parent / "patches").glob("*.patch"))
for patch in patches:
    for args in (["--check"], []):
        r = subprocess.run(["git", "apply", *args, str(patch)], cwd=upstream, capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"patch failed ({' '.join(args) or 'apply'}): {patch.name}\n{r.stderr}")
print(f"overlay ok: locales {EXTRA_LOCALES} registered, {copied} file(s) copied, {len(patches)} patch(es) applied")
