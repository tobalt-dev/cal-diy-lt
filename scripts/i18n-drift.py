#!/usr/bin/env python3
"""Compare the lt overlay with an upstream tree's English strings.

Usage: i18n-drift.py UPSTREAM_DIR LT_JSON
Prints a Markdown report. Exit 1 when a translated string's placeholders no longer
match English (the text would render wrong); missing translations only fall back to
English and are reported without failing.
"""
import json, re, sys
from pathlib import Path

VISITOR_PATHS = [
    "packages/emails",
    "packages/features/bookings/Booker",
    "packages/features/bookings/components",
    "packages/features/bookings/lib/book-event-form",
    "packages/features/form-builder",
    "packages/features/calendars",
    "packages/features/timezone-buttons",
    "packages/platform/atoms/booker",
    "packages/app-store/locations.ts",
    "packages/ui/components/form",
    "apps/web/modules/bookings",
    "apps/web/modules/users",
]
KEY_RE = re.compile(r"""\bt\(\s*["'`]([A-Za-z][A-Za-z0-9_]*)["'`]""")
PH_RE = re.compile(r"\{\{\s*[^}]+?\s*\}\}|</?\d+>|\$t\([^)]*\)")

upstream, lt_path = Path(sys.argv[1]), Path(sys.argv[2])
def flat(d, prefix=""):
    out = {}
    for k, v in d.items():
        out.update(flat(v, f"{prefix}{k}.") if isinstance(v, dict) else {f"{prefix}{k}": str(v)})
    return out

en = flat(json.loads((upstream / "packages/i18n/locales/en/common.json").read_text()))
lt = flat(json.loads(lt_path.read_text()))

used = set()
for rel in VISITOR_PATHS:
    p = upstream / rel
    files = [p] if p.is_file() else [f for f in p.rglob("*.ts*") if not re.search(r"\.(test|spec|stories)\.", f.name)]
    for f in files:
        used |= set(KEY_RE.findall(f.read_text(errors="ignore")))

missing = sorted(k for k in used if k in en and k not in lt)
mismatched = sorted(
    k for k in lt if k in en and sorted(PH_RE.findall(en[k])) != sorted(PH_RE.findall(lt[k]))
)
orphans = sorted(k for k in lt if k not in en)

print(f"### i18n drift\n\n- visitor keys used: {len(used)}\n- lt keys: {len(lt)}")
print(f"- **placeholder mismatches: {len(mismatched)}** (fail)")
for k in mismatched:
    print(f"  - `{k}` en: `{en[k]}` · lt: `{lt[k]}`")
print(f"- missing lt for visitor keys: {len(missing)} (shown in English until translated)")
for k in missing:
    print(f"  - `{k}`: `{en[k]}`")
print(f"- lt keys no longer in en: {len(orphans)} (harmless)")
for k in orphans:
    print(f"  - `{k}`")
sys.exit(1 if mismatched else 0)
